# WeType Network Hardening

针对**微信输入法（WeType）**的联网行为审计与出站封锁工具集。

目标：在不卸载、不换输入法的前提下，切断其所有主动外联通道，并回收其预加载 WebView2 进程占用的内存。

> 本文档内容基于 Windows 11 + 微信输入法 3.0.0.38 实测。所有脚本均为本地系统配置，不采集、不上传任何数据。

---

## 目录

```
scripts/
  run.ps1                     UAC 提权启动器（调用 hardening.ps1）
  hardening.ps1               主加固脚本：出站 Block 规则 + 清理 Allow 规则
  block-proof.ps1             封锁有效性实证（可逆，自动清理）
  run-proof.ps1               block-proof 的提权启动器
  webview-suppress.ps1        终止 WeType 预加载的 WebView2（按祖先进程识别）
  start-suppress.vbs          无窗口启动器
  register-task-v3.ps1        注册登录观察任务

docs/
  wetype-network-audit-report.md       原始联网行为审计报告
  wetype-hardening-record.md           本次加固执行记录与验证
  wetype-communication-analysis.md     通信架构静态逆向分析
  wetype-webview-suppress-record.md    WebView2 抑制实测与部署记录
```

---

## 快速开始

### 1. 出站封锁（需管理员）

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run.ps1
```

会弹出 UAC。脚本将：

1. 启用 Domain / Private / Public 三个防火墙 profile
2. 递归发现 `C:\Program Files\Tencent\WeType` 下所有 `.exe`，逐个创建 **Outbound / Block** 规则
3. 删除所有指向 WeType 程序的 **Allow** 规则（入站、出站一并删除）
4. 输出校验结果

规则命名 `WeType-NetBlock: <相对路径>`，**不绑定版本号**。

### 2. 验证封锁确实生效（可选）

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-proof.ps1
```

流程：复制 `curl.exe` 到临时目录 → 无规则时请求（应 200）→ 加同样的 Block 规则 → 再请求（应失败）→ 删规则 → 再请求（应 200）→ 清理。

**全过程可逆，结束后系统状态与测试前一致。**

### 3. 抑制 WebView2 预加载（可选，仅省内存）

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\register-task-v3.ps1
```

注册登录任务：登录后隐藏运行 5 分钟观察窗口，清理 WeType 拉起的 `msedgewebview2.exe`，然后自动退出。**不留常驻进程、不出现窗口。**

---

## 设计要点

### 为什么按进程封锁，而不是按域名

- 按域名：只能覆盖已知域名，自研 DNS / DoH 可绕过
- 按进程：WFP 在 socket 层拦截，**不受 TUN / 系统代理影响**，且不依赖域名清单

### 为什么规则不绑定版本号

加固脚本每次运行时递归发现安装目录下的所有 exe。版本升级后目录变化，重跑一次即可覆盖新版本；旧规则指向已不存在的路径，无害。

### 为什么只封出站，不封入站

WeType 核心功能不需要入站监听（实测监听端口为 0）。封出站即可切断所有主动外联；同时保留入站默认策略不变，避免影响其他局域网功能。

### 为什么 WebView2 抑制要按祖先进程识别

同一路径的 `msedgewebview2.exe` 也被其他程序（如编辑器内嵌浏览器）使用。按路径封会误伤，必须沿 `ParentProcessId` 链追溯到 `wetype_update.exe` 才终止。

```powershell
# 判定逻辑
msedgewebview2 → ... → wetype_update.exe   ✅ 终止
msedgewebview2 → ... → magpie.exe          ❌ 保留
```

---

## 实测结论

### 封锁效果

| 检查项 | 结果 |
|---|---|
| 防火墙 Domain / Private / Public | 全部 Enabled |
| WeType-NetBlock 规则 | 7 条，全部 Outbound / Block / Enabled |
| WeType 相关 Allow 规则 | 0 |
| WeType 远端 TCP / UDP | 0 / 0 |
| 其他程序（代理、QQ） | 未受影响 |

### 封锁实证

| 阶段 | 结果 |
|---|---|
| 无规则 | HTTP 200 |
| 加 Block 规则 | 连接失败（curl exit 7） |
| 删规则 | HTTP 200 恢复 |

### 内存回收

| 项 | 抑制前 | 抑制后 |
|---|---|---|
| WeType 自有 WebView2 | 12 个 / 560 MB | 0 个 / 0 MB |
| WeType 四进程 | 568 MB | 451 MB |

---

## 通信架构速览

所有携带输入内容的云端通道都汇聚在 **`wetype_server.exe`** 一个进程：

```
输入的拼音 + 光标前后文本  →  云端候选
每次按键 / 候选点击        →  埋点上报
AI 搜索 / 翻译             →  云端
崩溃 minidump              →  Sentry
语音音频                   →  wetype_update.exe → 腾讯云 COS
自动更新                   →  wetype_update.exe
```

其中 `wetype_update.exe` 同样在 Block 规则覆盖内。**注入到其他进程的 `wetype_tip_core.dll` 无独立联网能力**（WS2_32 仅导入两个无害序号），只能通过命名管道交给 `wetype_server.exe`。

详细分析见 [docs/wetype-communication-analysis.md](docs/wetype-communication-analysis.md)。

---

## 注意事项

| 项 | 说明 |
|---|---|
| **在线更新不可用** | `wetype_update.exe` / `wetype_installer.exe` 出站被封，升级前需先移除规则 |
| **入站默认阻止** | 防火墙启用后，局域网功能（远程桌面、adb、文件共享）如异常需单独放行 |
| **版本升级后需重跑** | 新版本目录的 exe 需重新 Apply 才能被纳入规则 |
| **WebView2 抑制有时间盲区** | 仅在登录后 5 分钟内有效；单机模式下 WeType 重启不触发预加载，实际影响很小 |

---

## 回滚

```powershell
# 移除全部 Block 规则（不会关闭防火墙）
Get-NetFirewallRule -DisplayName 'WeType-NetBlock*' | Remove-NetFirewallRule

# 移除 WebView2 抑制任务
Unregister-ScheduledTask -TaskName 'WeType-WebView2-Suppress' -Confirm:$false

# 关闭防火墙（如确需）
Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False
```

---

## 环境要求

- Windows 10 / 11
- PowerShell 5.1 或更高
- 加固脚本需要管理员权限（UAC）
- WebView2 抑制任务**不需要**管理员权限

---

## 免责声明

本工具用于在自有设备上限制特定软件的网络行为。使用前请自行确认符合当地法律法规及软件许可协议。所有脚本均可通过上述「回滚」章节完整撤销。