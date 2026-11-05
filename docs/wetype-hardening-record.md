# 微信输入法断网加固 —— 本机执行记录

- 执行时间：2026-11-06 01:02–01:06
- 主机：`win32 10.0.26300 x64`，当前用户为普通账户（非管理员会话，加固脚本提权执行）
- 依据：`wetype-network-audit-report.md`（原始审计版本 3.0.1.28）
- 本机实际版本：**微信输入法 3.0.0.38**（`C:\Program Files\Tencent\WeType`）

---

## 1. 执行前实测状态

| 检查项 | 报告记录 | 本机实测 |
|---|---|---|
| 安装版本 | 3.0.1.28 | **3.0.0.38** |
| `WeType-NetBlock` 规则 | 7 条启用 | **0 条** |
| 防火墙 Domain/Private/Public | 全 Enabled | 全 Enabled（未变） |
| WeType 入站 Allow 规则 | 0 条 | **1 条启用**：`WeChat`，Inbound/Allow → `3.0.0.38\wetype_update.exe` |

结论：报告里的按进程出站封锁**在本机已全部丢失**（版本目录由 3.0.1.28 变为 3.0.0.38 后规则失效/被移除），同时那条放行的入站规则重新出现。

遗留核对：
- 报告 6.4 节删除的旧规则 GUID `{49523A0A-6A26-4B20-B59F-98BE15A02415}` 未复活。
- 当前 `WeChat` 规则 GUID 为 `{39320FD8-A087-4E78-8277-2E6A413D8503}`，指向现存 `3.0.0.38` 目录，是**新生成**的规则，不是旧版残留。

## 2. 执行的加固

脚本：`scripts/hardening.ps1`（提权执行，日志 `scripts/wetype-hardening.log`）

1. `Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True`（幂等兜底）
2. 清除既有 `WeType-NetBlock*` 规则（本次为 0 条）
3. 递归枚举 `C:\Program Files\Tencent\WeType` 下全部 `.exe`，逐个建 **Outbound / Block / Profile Any / Enabled** 规则
4. 删除所有指向 `*\Tencent\WeType\*` 程序的 **Allow** 规则（入站、出站一并删除）
5. 校验并输出结果

规则命名改为 `WeType-NetBlock: <相对路径>`，**不再绑定版本号**，脚本每次 Apply 都重新发现 exe。

### 2.1 创建的 7 条出站 Block 规则

| 程序 | 版本 |
|---|---|
| `3.0.0.38\wetype_server.exe` | 3.0.0.38 |
| `3.0.0.38\wetype_renderer.exe` | 3.0.0.38 |
| `3.0.0.38\wetype_update.exe` | 3.0.0.38 |
| `3.0.0.38\wetype_service.exe` | 3.0.0.38 |
| `3.0.0.38\wetype_installer.exe` | 2.0.0.0 |
| `3.0.0.38\CrashSender1500.exe` | 1.5.0.0 |
| `3.0.0.38\Uninstall.exe` | 1.1.0.0 |

### 2.2 删除的 Allow 规则

| 显示名 | 方向 | 动作 | 原程序 | 处理 |
|---|---|---|---|---|
| `WeChat` | Inbound | Allow | `3.0.0.38\wetype_update.exe` | **已删除** |

## 3. 功能实证（关键）

规则的"存在"不等于"生效"，因此做了一次可逆实证，脚本 `scripts/block-proof.ps1`，日志 `scripts/wetype-block-proof.log`：

| 阶段 | 结果 |
|---|---|
| 复制 `curl.exe` 到临时目录，无规则 | HTTP **200**（exit 0） |
| 为同一程序添加同样的 Outbound/Block 规则 | 连接失败（curl **exit 7**，无法建立连接） |
| 删除该临时规则 | HTTP **200**（exit 0）恢复 |
| 清理临时规则与文件 | 残留规则数 **0** |

结论：本机的**进程级出站封锁确实生效**，且在 mihomo TUN 环境下依然有效（WFP 在进程 socket 层拦截，早于路由）。

## 4. 执行后状态

| 检查项 | 结果 |
|---|---|
| 防火墙 Domain / Private / Public | 全部 `Enabled=True` |
| `WeType-NetBlock` 规则 | 7 条，全部 Outbound/Block/Enabled |
| WeType 相关 Allow 规则 | **0** |
| WeType TCP 连接 / UDP 端点 | **0 / 0** |
| WeType 监听端口 | 0 |
| WeType 子进程 WebView2 远端连接 | 0 |
| FlClashCore 连接 | 38（正常，未受影响） |
| hosts 文件 | 未修改（3279 字节，LastWrite 2026-10-22） |
| 其他 WeType 副本 / 计划任务 / 额外服务 | 无（仅 `WeType Management Service` → 现有目录） |

### 4.1 关于执行期间出现的一条连接

加固后首轮检查发现 `wetype_update.exe`(PID 10608) 有一条 `120.233.18.62:443` 的连接：

- `CreationTime = 00:48:35`，**早于规则生效的 01:02:04**；
- 状态为 `FinWait1`（正在关闭），初始快照中已无 Established；
- 同一时刻 QQ 有一条相邻 IP（`120.233.18.186:443`）的连接也在同状态，属同一腾讯服务端段；
- 数秒后归零。

判定：**规则生效前建立的旧会话正在收尾，非新增外联**。防火墙 Block 规则只作用于新建连接，不切断已建立会话。

## 5. 残余风险与缺口

> **更正（2026-11-06 后续分析）**：本节原先记录"WebView2 是绕过封锁的缺口"，该结论**经复核后不成立**。
>
> 语音摘要的全部网络行为都在 `wetype_update.exe` 内部完成（自带 libcurl → `ApplyCosToken` → 腾讯云 COS 直传，以及 `VoiceSummaryRecapClient` 的 CGI 请求/轮询）。WebView2 只负责渲染服务端返回摘要 HTML（`recap.html.enc` 解密后显示）。
>
> 实测证据：WebView2 profile 的 History 0 行、Cache 0 字节、无 Cookie、远端连接 0 —— 从未加载过任何远程页面。
>
> 而 `wetype_update.exe` 已在 7 条 Block 规则内，故语音摘要链路**实际已被切断**。详见 `wetype-webview-suppress-record.md` 第 1.1 节。

1. **WebView2 资源占用（非安全问题，已处置）**
   - `wetype_update.exe` 启动时会预加载 12 个 `msedgewebview2.exe`（语音摘要页），约占 560 MB 内存。
   - 这些进程不承载业务网络，属纯资源浪费。
   - 已通过 `scripts/webview-suppress.ps1` 在登录时清理，详见 `wetype-webview-suppress-record.md`。
2. **更新通道已封**：`wetype_update.exe` / `wetype_installer.exe` 出站被 Block，在线更新不可用。升级前需先移除规则。
3. **版本绑定已解除**：新脚本按目录递归发现 exe，升级到新版本目录后**仍需重新 Apply**（旧目录的规则不会自动迁移，但新版本 exe 会自动纳入）。
4. **入站策略**：防火墙已启用，默认入站阻止。EasyTier、Steam 远程、adb 局域网等如异常，需单独放行。
5. **短时连接**：轮询采样无法保证捕获亚秒级连接；本次以"进程无 socket + 出站拦截实证"双重依据判定。
6. **本地明文日志（不外泄，但存在磁盘）**：`context_capture\refetch_sync_legacy.log` 记录光标前后文本，属输入法正常工作方式，不在本次处置范围。

## 6. 维护命令

```powershell
# 重新应用（需管理员，会自动发现新版本目录下的 exe）
powershell -ExecutionPolicy Bypass -File .\scripts\run.ps1

# 仅查看状态（无需管理员）
.\scripts\wetype-netblock.ps1 -Action Status
```

撤销方式（需管理员）：

```powershell
Get-NetFirewallRule -DisplayName 'WeType-NetBlock*' | Remove-NetFirewallRule
```

## 7. 本次产生的文件

| 文件 | 说明 |
|---|---|
| `scripts/hardening.ps1` | 加固主脚本（提权执行） |
| `scripts/run.ps1` | UAC 提权启动器 |
| `scripts/wetype-hardening.log` | 加固日志 |
| `scripts/block-proof.ps1` | 出站封锁功能实证脚本 |
| `scripts/run-proof.ps1` | 实证的提权启动器 |
| `scripts/wetype-block-proof.log` | 实证日志 |
| `wetype-audit-now.ps1` | 现状审计 |
| `wetype-final-check.ps1` | 加固后综合校验 |
| `residual2/3/4/5.ps1` | 残余风险专项排查 |

> 注：脚本内容为 UTF-8，PowerShell 5.1 直接执行含中文的脚本会解析失败，故核查脚本均使用纯 ASCII 输出。