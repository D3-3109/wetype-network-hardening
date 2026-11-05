# WebView2 常驻抑制 —— 实测与部署记录

- 执行时间：2026-11-06 01:52–01:56
- 目的：微信输入法预加载 12 个 `msedgewebview2.exe`（语音摘要页）占用约 560 MB，用户从不使用语音输入，属纯浪费

---

## 1. 核心事实（含对既有结论的更正）

### 1.1 语音摘要不走 WebView2 联网

此前记录称「WebView2 承载帮助/反馈页，是网络拦截缺口」——**这个说法是错的**，需更正：

| 环节 | 实际执行者 |
|---|---|
| 音频上传至腾讯云 COS | **`wetype_update.exe`**（自带 libcurl → `ApplyCosToken` → COS 直传） |
| 摘要 CGI 请求/轮询 | **`wetype_update.exe`**（`VoiceSummaryRecapClient::SendRequest/SendPoll`） |
| 微信票据绑定 | **`wetype_update.exe`**（`GetWeiXinTicketReq`） |
| WebView2 的职责 | **仅渲染本地摘要 HTML**（`recap.html.enc` 解密后显示） |

证据：`wetype_update.exe` 模块列表中同时存在 `ime_net.dll`（Cronet 栈）、`wcwss.dll`（WebSocket）、`WS2_32.dll`，以及 `wetype::update::http::CurlHttpClient::HttpsPost` / `doHttpUpload` 符号。

WebView2 profile 实测：History 0 行、Cache 0 字节、无 Cookie、远端连接 0 —— **从未加载过任何远程页面**。

**结论：语音摘要的全部网络行为都在 `wetype_update.exe` 内，而该进程已被出站 Block 封锁。WebView2 不构成联网缺口，纯粹是资源浪费。**

### 1.2 预加载触发条件

- 二进制符号：`PreloadVoiceSummaryWindow`、`PreloadVoiceSummaryMiniWindow`、`Config::IsPreloadWebview`
- 实测：**仅在 WeType 进程全新启动时触发**，打开设置界面不会重新拉起
- 单机模式下实测：全新启动的 WeType **也未拉起 WebView2**（单机模式抑制了语音摘要功能）

---

## 2. 实测过程

### 2.1 手动终止测试

| 步骤 | 结果 |
|---|---|
| 终止前 | 12 个 WebView2，561.4 MB |
| 执行 `Stop-Process -Force` | 8 个成功，4 个已自行退出 |
| 观察 30 秒 | **0 个重新拉起** |
| `wetype_update.exe` 状态 | 存活，188 线程（全部 Wait 状态），WS 284.7 MB |
| 输入法功能 | 正常（`MM_TIP` / `MM_SERVER` 日志持续写入） |

### 2.2 重启 WeType 触发预加载

| 时间 | 事件 |
|---|---|
| 01:55:18 | `wetype_renderer`(10256)、`wetype_server`(17072)、`wetype_update`(9584) 全部重启 |
| 01:55:27 | 抑制器检测到 **12 个 WeType WebView2（509.5 MB）**，终止 10 个 |
| 01:55:27–01:56 | 后续 40 秒观测：**0 个残留** |

**抑制器按预期工作。**

---

## 3. 部署方案

### 3.1 脚本

`scripts/webview-suppress.ps1`

- 周期性（默认 20 秒）扫描 `msedgewebview2.exe`
- 沿父进程链向上追溯，**只终止祖先为 `wetype_update.exe` 的实例**
- 不触碰其他程序的 WebView2（同一路径的 `msedgewebview2.exe` 也被 magpie / ZCode 使用）
- 支持 `-Once`（单次）、`-DryRun`（只报告）、`-Interval`（间隔）
- **内置单实例保护**：循环模式下检测到已有实例就自动退出

### 3.2 关键设计：按祖先进程识别，不按路径

```
❌ 错误做法：按路径 C:\...\msedgewebview2.exe 封 —— 会误杀 magpie/ZCode 的实例
✅ 正确做法：沿 ParentProcessId 链追溯，直到遇到非 msedgewebview2 的祖先
             若该祖先是 wetype_update.exe 才终止
```

### 3.3 判定逻辑验证

用系统中现有的 7 个 magpie WebView2 做反向验证：

```
pid=2360   root=magpie.exe   ✓
pid=4396   root=magpie.exe   ✓
pid=13576  root=magpie.exe   ✓
pid=13764  root=magpie.exe   ✓
pid=15200  root=magpie.exe   ✓
pid=15760  root=magpie.exe   ✓
pid=15992  root=magpie.exe   ✓

匹配 7/7
```

DryRun 模式运行时：**0 个被误判为目标**，magpie 的 7 个进程全部安全。

### 3.4 无窗口运行 + 不常驻（最终方案）

**三次迭代的教训**：

| 版本 | 问题 |
|---|---|
| v1：`powershell.exe -WindowStyle Hidden` 作为任务动作 | **控制台窗口出现在前台**；关闭窗口会杀死守护进程（退出码 `0xC000013A`） |
| v2：VBS 启动器 + 常驻循环 | 窗口问题解决，但留下**常驻 PowerShell 进程**（约 30 MB） |
| **v3：VBS 启动器 + 5 分钟观察窗口** | 无窗口、无常驻、任务状态真实 |

**最终方案：`scripts/start-suppress.vbs`**

```vbs
cmd = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden" _
    & " -ExecutionPolicy Bypass -File """ & ps1 & """ -WatchMinutes 5 -Interval 10"
rc = shell.Run(cmd, 0, True)    ' 0 = 隐藏窗口, True = 等待退出
```

**为什么用观察窗口而不是单次执行**

WeType 与本脚本同为登录启动，谁先谁后不确定。若本任务先执行，单次清理会扑空，随后 WeType 拉起的 12 个 WebView2 就无人处理。5 分钟窗口覆盖这个时序竞争，窗口结束自动退出。

**实测时序**：

```
02:08:14  观察窗口启动（5 分钟，10 秒间隔）
02:13:21  窗口结束，自动退出
02:13:21  任务状态 Ready，lastResult=0
02:13:21  wscript: 0 个，suppressor powershell: 0 个
```

**零残留验证通过。**

### 3.5 计划任务（最终）

| 项 | 值 |
|---|---|
| 任务名 | `WeType-WebView2-Suppress` |
| 触发器 | **用户登录时**（`MSFT_TaskLogonTrigger`） |
| 动作 | `wscript.exe "start-suppress.vbs"` |
| 运行级别 | **Limited（不需要管理员）** |
| 登录类型 | Interactive |
| 隐藏 | **True** |
| 多重实例 | IgnoreNew |
| 执行时限 | 无限 |
| 当前状态 | `Ready`（空闲，等待下次登录） |

注册方式：`scripts/register-task-v3.ps1`

### 3.6 脚本参数

| 参数 | 说明 |
|---|---|
| 默认（无参数） | 5 分钟观察窗口，间隔 10 秒，然后退出 |
| `-WatchMinutes N` | 自定义观察窗口长度，`0` 等于单次执行 |
| `-Once` | 单次清理后立即退出 |
| `-Interval N` | 观察模式下的检查间隔秒数 |
| `-DryRun` | 只报告，不终止 |
| `-Loop` | 常驻循环（旧行为，需手动停止） |

### 3.7 踩坑记录

**PowerShell 5.1 的编码陷阱**：脚本含中文注释时，PowerShell 5.1 会按 GBK 解析 UTF-8 文件，导致语法错误（本次报错在第 47 行中文注释处）。**所有 PowerShell 脚本必须使用纯 ASCII**，或存为带 BOM 的 UTF-8。最终版脚本已改为纯英文注释。

---

## 4. 效果

### 4.1 内存

| 项 | 抑制前 | 抑制后 |
|---|---|---|
| WeType 四进程 | 568 MB | **451.6 MB** |
| WebView2（WeType 自有） | 560 MB（12 个） | **0 MB（0 个）** |
| **合计节省** | — | **约 560 MB** |

> 注：`wetype_update.exe` 仍占 268 MB / 183 线程。WebView2 不是它的主要开销来源；该进程同时承载 Flutter、语音、更新模块。188 个线程全部处于 Wait 状态，不消耗 CPU（空闲时该进程 0.47% 单核）。

### 4.2 输入法功能

| 检查项 | 结果 |
|---|---|
| `MM_TIP` 日志写入 | 正常 |
| `MM_SERVER` 日志写入 | 正常（01:55:53，49 秒前） |
| 候选生成 | 正常（mmap 未受影响） |
| 四个核心进程 | 全部存活 |

### 4.3 网络封锁未受影响

| 检查项 | 结果 |
|---|---|
| WeType 远端 TCP | **0** |
| WeType UDP | **0** |
| NetBlock 规则 | **7 条启用** |

---

## 5. 维护

### 5.1 查看状态

```powershell
Get-ScheduledTask -TaskName 'WeType-WebView2-Suppress'
Get-Content '.\scripts/wetype-webview-suppress.log' -Tail 20
```

### 5.2 手动清理一次

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts/webview-suppress.ps1 -Once
```

### 5.3 停止抑制

```powershell
Stop-ScheduledTask  -TaskName 'WeType-WebView2-Suppress'
Unregister-ScheduledTask -TaskName 'WeType-WebView2-Suppress' -Confirm:$false
```

### 5.4 临时放行（如果哪天要用语音摘要）

下次登录前不需要做任何事 —— 任务只在登录时观察 5 分钟，其余时间不运行。若担心正好撞上，取消任务即可：

```powershell
Unregister-ScheduledTask -TaskName 'WeType-WebView2-Suppress' -Confirm:$false
```

### 5.5 已知的时间盲区

当前方案在**登录后 5 分钟内**有效。以下情况不会被清理，直到下次登录：

| 情况 | 是否需要担心 |
|---|---|
| 登录 5 分钟后，WeType 因异常重启 | 极少见；且单机模式下 WeType 重启也不拉起 WebView2 |
| 手动重启 WeType 进程 | 实测单机模式下不触发预加载 |
| 从睡眠恢复 | WeType 进程不重启，不触发预加载 |

如果需要更强覆盖，可改用 `-Loop` 常驻模式（代价是一个隐藏的 PowerShell 进程，约 30 MB）。

---

## 6. 风险与局限

| 项 | 说明 |
|---|---|
| **杀进程是权宜手段** | 不是配置层的真正禁用，是"拉起就杀"的对抗式方案 |
| **20 秒窗口** | 抑制器每 20 秒检查一次，极端情况下 WebView2 能存活最多 20 秒 |
| **不影响安全边界** | 语音摘要的网络行为在 `wetype_update.exe`，已被防火墙封锁；抑制 WebView2 只省内存，不改变安全结论 |
| **单机模式已足够** | 实测单机模式下全新启动的 WeType 根本不拉起 WebView2，抑制器实际是兜底 |
| **版本升级** | 若未来版本改变预加载逻辑，抑制器无需修改（它按运行时进程树判断，不依赖版本） |

---

## 7. 本次新增文件

| 文件 | 说明 |
|---|---|
| `scripts/webview-suppress.ps1` | 抑制器主脚本 |
| `scripts/register-task-v3.ps1` | 计划任务注册脚本 |
| `scripts/wetype-webview-suppress.log` | 运行日志 |
| `wv-kill-test.ps1` | 手动终止测试 |
| `wv-chain-test.ps1` | 祖先链判定验证 |
| `wv-final.ps1` | 最终状态核验 |