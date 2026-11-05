# 微信输入法联网行为审计与防火墙加固报告

- 日期：2026-11-05
- 主机：Windows 11（win32 10.0.26200 x64）
- 微信输入法版本：3.0.1.28
- 代理环境：FlClash（mihomo 内核）TUN 模式，`Meta Tunnel` 网卡，DNS `198.18.0.2`，fake-ip
- 结论摘要：**离线模式下实测无任何联网行为；已开启 Windows 防火墙并按进程实施出站封锁，同时禁用/删除全部 WeType 放行规则。**

---

## 1. 结论

1. 在开启“离线模式”的前提下，对微信输入法四个进程连续监测约 6 分钟（覆盖用户实际中文输入时段），**TCP 连接 0、UDP 端点 0、WeType 相关 DNS 解析 0**。
2. 输入法本地引擎配置中 `enable_cloud_search_by_input: true`，说明云候选能力处于开启状态；但输入期间仍未发出请求，离线模式在请求层生效。
3. 程序本身具备完整联网能力，后台更新、崩溃上报、语音/翻译/AI 等功能属于条件触发，**不能凭短时观察断言“永远不联网”**。
4. 已完成系统级加固：Windows 防火墙开启，7 条按进程的出站 Block 规则生效，WeType 相关 Enabled Allow 规则数量为 0。
5. 剩余缺口：WebView2 承载的帮助/反馈页由 `msedgewebview2.exe` 发起请求，不在本次拦截范围（按要求暂不处理）。

---

## 2. 环境与进程

| 项目 | 内容 |
|---|---|
| 安装路径 | `C:\Program Files\Tencent\WeType\3.0.1.28` |
| `wetype_server.exe` | PID 9800 |
| `wetype_renderer.exe` | PID 14636 |
| `wetype_update.exe` | PID 9808 |
| `wetype_service.exe` | PID 2844，SYSTEM，服务名 `WeType Management Service` |
| 日志目录 | `%USERPROFILE%\AppData\LocalLow\Tencent\WeType` |
| 配置目录 | `%APPDATA%\Tencent\WeType`、`%LOCALAPPDATA%\Tencent\WeType` |

---

## 3. 检测方法

1. **进程与模块分析**：确认四个常驻进程及其加载的网络/遥测模块（`XNet.dll`、`ime_net.dll`、`wcwss.dll`、`CrashRpt1500.dll`、`sentry_flutter_plugin.dll`、`WebView2Loader.dll` 等）。
2. **二进制字符串分析**：提取域名、API 路径、更新/崩溃上报逻辑。
3. **网络监测**：
   - 每 500 ms 采样 `netstat -ano`，按 PID 过滤 TCP/UDP；
   - 每秒读取 `Get-DnsClientCache`，监控腾讯系域名；
   - 记录连接状态变化与 DNS 新增记录。
4. **行为验证**：用户在记事本中实际输入中文；同时检查输入法日志写入时间与上下文捕获记录，确认输入法确实在工作。
5. **组件与配置检查**：Windows 防火墙规则、网络配置、LevelDB 引擎配置、MMKV 设置文件。

> 局限性：轮询方式可能漏掉持续时间短于采样间隔的连接；DNS 缓存与输入法日志用于交叉验证。观察窗口约 6 分钟，不代表长期行为。

---

## 4. 实测结果（加固前）

监测时间：20:33–20:39，覆盖用户输入时段 20:36–20:38。

| 指标 | 结果 |
|---|---|
| WeType TCP 连接（含监听） | 0 |
| WeType UDP 端点 | 0 |
| WeType 相关 DNS 解析 | 0 |
| 输入法是否在工作 | 是：`MM_*_20261105.xlog` 于 20:38:03–07 写入；`context_capture` 记录 `host_exe=notepad.exe` |

### 关于 `otheve.beacon.qq.com`

监测期间 DNS 缓存出现 `otheve.beacon.qq.com`（腾讯埋点域名），但：

- 该字符串仅存在于 QQ 的 `major.node`，WeType 所有二进制中均不存在；
- 当时 QQ 本身有活跃连接；
- 因此判定为 **QQ 的埋点请求，与微信输入法无关**。

### 本地引擎配置

LevelDB 中的引擎配置包含：

```json
"cloud_engine_opt": {
  "enable_cloud_search_by_input": true,
  "enable_cloud_correction": false,
  "enable_cloud_most_likely": false
}
```

云候选能力开启，但输入期间未产生网络请求。

---

## 5. 联网能力面（代码层证据）

### 5.1 域名与端点

| 域名/端点 | 用途 |
|---|---|
| `wetype.weixin.qq.com` | 主 API；`/sentry/api/14/minidump_v2/` 崩溃上报 |
| `wetype995.weixin.qq.com` | 备用端点 |
| `wetype.wxqcloud.qq.com` | 帮助/文章页 |
| `z.weixin.qq.com` | 反馈页 |
| `r.qq.com` | 语音分享链接 |

### 5.2 组件

| 组件 | 能力 |
|---|---|
| `wetype_update.exe` | 自动更新，含 `enable_auto_update`、`auto_update_disabled`、`patch_downloader` |
| `wetype_service.exe` | SYSTEM 服务，补丁/管理 |
| `XNet.dll` / `ime_net.dll` / `wcwss.dll` | HTTP / 自研网络栈 / WebSocket |
| `sentry_flutter_plugin.dll` + `CrashRpt1500.dll` | 崩溃上报，minidump 可能包含内存中的输入内容 |
| WebView2 | 帮助、反馈、活动页 |
| `WXP2PTransfer.dll` | 局域网 P2P 传输 / UPnP 打洞（当时未加载、未监听） |
| 语音 / 翻译 / AI / 微信上下文 | 功能本身需要联网；存在 `wt_pc_app_action_exit_offline_mode` 埋点，触发时可能引导退出离线模式 |

---

## 6. 已实施的加固

### 6.1 开启 Windows 防火墙

| Profile | 加固前 | 加固后 |
|---|---|---|
| Domain | Disabled | **Enabled** |
| Private | Disabled | **Enabled** |
| Public | Disabled | **Enabled** |

### 6.2 出站 Block 规则（7 条，Enabled=True）

```
WeType-NetBlock: 3.0.1.28\wetype_server.exe
WeType-NetBlock: 3.0.1.28\wetype_renderer.exe
WeType-NetBlock: 3.0.1.28\wetype_update.exe
WeType-NetBlock: 3.0.1.28\wetype_service.exe
WeType-NetBlock: 3.0.1.28\wetype_installer.exe
WeType-NetBlock: 3.0.1.28\CrashSender1500.exe
WeType-NetBlock: 3.0.1.28\Uninstall.exe
```

- 方向：Outbound
- 动作：Block
- Profile：Any
- 按进程路径拦截，**不受 FlClash TUN / 系统代理影响**（WFP 在进程 socket 层生效）。

### 6.3 禁用的 Allow 规则

| 显示名 | 方向 | 动作 | 原程序 | 现状态 |
|---|---|---|---|---|
| WeType Update | Inbound | Allow | `3.0.1.28\wetype_update.exe` | Disabled |
| WeChat | Inbound | Allow | `2.1.4.6\wetype_update.exe`（旧版遗留） | 已删除 |

### 6.4 删除旧版遗留规则

- GUID：`{49523A0A-6A26-4B20-B59F-98BE15A02415}`
- 显示名：`WeChat`
- 程序：`C:\Program Files\Tencent\WeType\2.1.4.6\wetype_update.exe`（该目录已不存在）
- 删除前已校验程序路径；删除后确认 `legacy_rule_exists=False`，且系统内无其他名为 `WeChat` 的防火墙规则。

---

## 7. 加固后状态

| 检查项 | 结果 |
|---|---|
| 防火墙 Domain/Private/Public | 全部 `Enabled=True` |
| WeType 出站 Block 规则 | 7 条，全部启用 |
| WeType 相关 Enabled Allow 规则 | **0** |
| WeType 进程 TCP / UDP | 0 / 0 |
| FlClash / EasyTier / QQ 现有连接 | 正常，未受影响 |
| hosts 文件 | 未修改 |

---

## 8. 注意事项与残余风险

1. **WebView2 缺口**：帮助/反馈页由 `msedgewebview2.exe` 发起请求，不在按进程拦截列表内；目前无该子进程常驻。按要求暂不处理。
2. **更新被阻断**：`wetype_update.exe`、`wetype_installer.exe` 的出站被拦截，自动/手动在线更新均不可用。升级前需先撤销 Block 规则。
3. **路径与版本绑定**：规则指向 `3.0.1.28` 目录。若手动升级到新版本目录，必须重新执行 Apply。
4. **入站策略变严**：防火墙开启后默认入站阻止。EasyTier、Steam 远程、adb 局域网等功能如异常，需在弹窗或规则中放行。
5. **短时连接漏检风险**：轮询无法保证捕获所有亚秒级连接；本次结论基于网络采样、DNS 缓存、输入法日志的多重交叉验证。
6. **崩溃上报条件触发**：仅在崩溃时发生；minidump 可能包含输入内容。如需更严格，可在崩溃后先断网并清理 `LocalLow\Tencent\WeType\crash`。
7. **离线模式是应用层开关**：本次加固后，即使应用层开关失效，进程级出站封锁仍然生效。

---

## 9. 维护与回滚

### 9.1 重新应用 / 撤销 Block 规则

```powershell
# 查看状态（无需管理员）
powershell -ExecutionPolicy Bypass -File .\tools\wetype-netblock.ps1 -Action Status

# 重新应用（需管理员）
powershell -ExecutionPolicy Bypass -File .\tools\wetype-netblock.ps1 -Action Apply

# 撤销全部 Block 规则（需管理员；不会关闭防火墙）
powershell -ExecutionPolicy Bypass -File .\tools\wetype-netblock.ps1 -Action Remove
```

### 9.2 恢复被禁用的入站规则

```powershell
Set-NetFirewallRule -DisplayName "WeType Update" -Enabled True
```

### 9.3 关闭防火墙（如确需）

```powershell
Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False
```

### 9.4 hosts 方案（未启用）

```powershell
# 默认仅封 3 个 wetype 专属域名
powershell -ExecutionPolicy Bypass -File .\tools\wetype-hosts.ps1 -Action Apply
powershell -ExecutionPolicy Bypass -File .\tools\wetype-hosts.ps1 -Action Remove
```

> hosts 在 mihomo TUN + fake-ip 下仅对使用系统解析器的程序有效；自研 DNS / DoH 可绕过，且只能覆盖已知域名，不建议作为主闸门。

---

## 10. 附录

### 10.1 工具与日志

| 文件 | 说明 |
|---|---|
| `tools\wetype-netblock.ps1` | 防火墙出站 Block 规则管理（Status/Apply/Remove） |
| `tools\wetype-hosts.ps1` | hosts 标记块管理（可选，未启用） |
| `tools\apply-netblock.log` | 防火墙开启与规则创建日志 |
| `tools\disable-wetype-allow.log` | 禁用 Allow 规则日志 |
| `tools\delete-legacy-rule.log` | 删除旧版遗留规则日志 |
| `audit\wetype_net*.log` | 网络监测原始日志 |

### 10.2 时间线

| 时间 | 事件 |
|---|---|
| 20:33–20:39 | 网络监测，覆盖用户输入时段 |
| 20:45 | 开启防火墙，创建 7 条出站 Block 规则 |
| 20:49 | 禁用 `WeType Update`；禁用旧版 `WeChat` 遗留规则 |
| 20:50 | 删除旧版 `WeChat` 遗留规则，完成验证 |

### 10.3 隐私发现（不在本次处置范围）

`%USERPROFILE%\AppData\LocalLow\Tencent\WeType\context_capture\refetch_sync_legacy.log`（约 3.5 MB）以明文保存了输入法从窗口读取的上下文文本，其中包含代理配置、API Key、服务器口令等敏感内容；本地 LevelDB 中亦存在同类文本。

- 未发现这些内容被上传（离线模式下无连接）。
- 建议定期清理该日志，或在设置中关闭“上下文感知 / 跨应用读取上下文”。

> 本报告不复述任何具体密钥或口令。

---

**报告结束**