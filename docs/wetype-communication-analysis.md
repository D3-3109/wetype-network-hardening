# 微信输入法通信架构分析（静态逆向）

- 分析对象：微信输入法 **3.0.0.38**
- 分析日期：2026-11-06
- 方法：二进制字符串提取、PE 导入表解析、protobuf 描述符恢复、进程模块枚举
- 说明：所有结论来自静态分析 + 运行时观测，未进行任何主动外联探测

---

## 1. 进程与职责

```
wetype_service.exe (SYSTEM, 服务)
  └─ 拉起 ↓
     wetype_server.exe   ← 引擎（mozc 内核），所有云端请求的实际执行者
     wetype_renderer.exe ← Flutter UI 渲染
     wetype_update.exe   ← 更新 + 语音摘要 + 自带网络栈
     wetype_tip_core.dll ← 注入到宿主进程（TSF 输入法框架）
```

### 注入面

`wetype_tip_core.dll` 注入以下进程：

```
explorer.exe      QQ.exe             SearchHost.exe
FlClash.exe       magpie.exe         msedgewebview2.exe
```

**该 DLL 无独立联网能力**（见 §4），只能通过命名管道把数据交给 `wetype_server.exe`。

---

## 2. 引擎架构：mozc 改造

源码路径出现在二进制中：

```
E:\workspace\WeChatPinYin\wxkb\01_mozc\server\enginev2\wxime_engine_impl.cpp
E:\workspace\WeChatPinYin\wxkb\01_mozc\server\handler\input_handler.cpp
E:\workspace\WeChatPinYin\wxkb\01_mozc\server\network\network_manager.cpp
E:\workspace\WeChatPinYin\wxkb\01_mozc\server\http_client\CurlHttpClient.cpp
```

即基于 Google 开源的 mozc（日语输入法引擎）深度改造。

### 第三方组件

| 组件 | 用途 |
|---|---|
| abseil / absl | 基础库 |
| protobuf | 序列化（261 处引用） |
| mars | 腾讯开源网络库 |
| CryptoPP | 加密 |
| OpenSSL 1.1.1k | TLS |
| TensorFlow Lite | 端侧模型推理 |
| Flutter | UI |
| LevelDB | 用户词库存储 |
| libcurl | HTTP 客户端 |

---

## 3. 数据流：单次按键

```
① 宿主进程收到 WM_KEYDOWN
   └─ wetype_tip_core.dll（TSF 回调）捕获

② TSF 上下文读取  ← 隐私敏感点
   └─ 调用 tsf_surrounding_text，读取光标前后文本
   └─ 写入本地 context_capture\refetch_sync_legacy.log

③ Named Pipe IPC
   └─ SendIPCMessage → wetype_server.exe

④ 引擎处理（全本地）
   拼音切分    bwcnmac.bin (30 MB)
   简拼展开    bwcjpmac_jianpin.bin (12 MB)
   查词库      slwd_pc_second_level.bin (51.7 MB) + ckvdmac.bin (39.7 MB)
   词性组合    noun_tag_dict.bin + cell_dict.*.zh
   n-gram 打分 lmcnmac.bin (16.8 MB)
   神经打分    nlrgpt2_nnlm.bin (16.2 MB, TFLite)
   消歧        wsd.bin / editpinyin.bin

⑤ 单机模式闸门
   GetStandaloneModeStatusFromConfig()
   ├─ 单机模式 → 跳过云端
   └─ 在线模式 → cloud_search_candidate → network_manager.cpp

⑥ 候选输出
   └─ 写入 MM_SERVER.mmap3（150 KB 共享内存）

⑦ 候选窗渲染
   └─ tip_core 在宿主进程内读 mmap，零拷贝
```

### 共享内存（IPC 之外的快速通道）

```
MM_SERVER.mmap3    153,600 字节   引擎状态
MM_RENDER.mmap3    153,600 字节   UI 读取
MM_TIP.mmap3       153,600 字节   注入端读取
MM_WETYPE.mmap3    153,600 字节
```

候选不经过 IPC 逐个序列化，而是写入共享内存，注入端直接读——这是打字响应快的主因。

---

## 4. 两套网络栈

### A. libcurl（`wetype_server.exe` / `wetype_update.exe`）

```
wetype::server::http::CurlHttpClient::HttpsPost
wetype::update::http::CurlHttpClient::HttpsPost / HttpPut / doHttpUpload
```

- TLS：**OpenSSL 1.1.1k**（2021-03-25，2023-09 已停止维护）
- 自带 CA：`C:\Program Files\Common Files\SSL/cert.pem`
- **支持代理**：`ALL_PROXY` / `all_proxy` / `http_proxy` / `NO_PROXY` / `no_proxy`
- **无证书固定**（`CURLOPT_PINNEDPUBLICKEY` 0 处，无硬编码 pin）
- 存在 `SSL certificate verify result: %s (%ld), continuing anyway.` —— **校验失败仍继续**

### B. Cronet 自研栈（`ime_net.dll`）

```
net_initialize / net_start_task / net_start_custom_host_task
net_add_host_map / net_switch_server / net_handshake_if_needed
net_generate_device_code / net_set_device_token / net_initialize_get_uin
```

- 源码：`ime-business\3rd\ime-net\net\cronet_net_api.cpp`
- **无标准代理入口**
- 需要设备码 + 设备令牌 + 握手

### C. WebSocket（`wcwss.dll`）

```
net_start_receive_notify_ws
[EO-WS] send_socket_message / net_start_receive_notify_ws called
```

---

## 5. 通信端点

| 域名 / 端点 | 用途 |
|---|---|
| `wetype.weixin.qq.com` | 主 API |
| `wetype995.weixin.qq.com` | 备用 |
| `.../sentry/api/14/envelope/` | Sentry 崩溃上报 |
| `wetype.wxqcloud.qq.com` | 帮助/文章页 |
| `z.weixin.qq.com` | 反馈页 |
| `r.qq.com/wetype/voicerecorder[ -share]?share_token=` | 语音分享 |
| 腾讯云 COS | 音频/日志直传（`ApplyCosToken`） |

---

## 6. 身份标识

```
business_generate_device_code
net_generate_device_code / net_generate_device_code_v2
_device_code_engine / _device_code_render / _device_code_server / _device_code_update
_uin
```

初始化日志模板：

```
Init business no uin
Init business uin = {} {} {} {}
Init wxime network end device_code: {}
```

`DeviceInfo` 消息字段：`vid, ipv4, ipv6, os_type, client_versions, abtest_infos, experiment_info`

**注意 `ipv4` / `ipv6`**：主动上报自身 IP。

---

## 7. 云端候选的数据内容

### 请求侧（`CloudSearchCandidate` / `ReportInfo` 字段表）

```
data, text                    输入的串 / 上屏文本
pending_length                未上屏拼音长度
text_before_cursor            光标前文本
context_prev_text             上下文（前）      ← 最大披露
context_after_text            上下文（后）
context_change_reason
candidate_id, candidate_data, session_id
kb_type, double_pin_type, wubi_type, wubi_config
enable_fuzzy_py, enable_nl, enable_rl, enable_hf, enable_gk
enable_ang, enable_iang, enable_uang, enable_c_ch, enable_s_sh
enable_z_zh, enable_hui_fei, enable_eng, enable_ing, enable_ong
enable_huang_wang, enable_un_ong, enable_un_iong, enable_an_ai, enable_eng_ong
target_process_id, process_name          ← 你在哪个程序里打字
```

### 响应侧（`CloudSearchResult`）

```
cloud_search_candidate, candidate_data, candidate_id,
candidate_index, candidate_count, candidate_has_more, sequence,
cloud_service_version,
ai_search_result, translate_result, voice_generation, fixed_user_info
```

翻译结果 `translate_result` 走同一通道，非独立接口。

### 配置开关

```
enable_cloud_search_by_input
cloud_search_by_input_predict_next_n
cloud_search_by_input_return_cnt
cloud_search_min_interval        ← 有节流，非每次按键都请求
enable_cloud_correction
enable_cloud_most_likely
enable_ai_search
```

---

## 8. 遥测

按 `com.tencent.wrbus.pb.*` 定义的 protobuf 消息，批量上报（`DoReportNetWorkRequest data_count`）：

```
WtStatKeyboardActiveReport              键盘活跃
WtStatCandidateClickReport              候选点击
WtStatCandidateUserClickReport          用户点击
WtStatCloudCandidateActionReport        云端候选行为
WtStatRefetchContextReport              上下文重抓取
WtStatCommonTermsUserActionReport       常用语
WtStatClipboardActionReport             剪贴板
WtStatGroupClipboardUserActionReport    群剪贴板
WtStatAiQuestionActionReport            AI 提问
WtStatVoiceInputActionReport            语音输入
WtStatRecordingSummaryActionReport      录音摘要
WtStatKeyboardNetworkReport             网络状态
```

---

## 9. 语音摘要：原生上传，不经 WebView2

### 上传链路（全部在 `wetype_update.exe`）

```
VoiceBridge::prepareAudioUploadRecording     准备录音片段
VoiceBridge::scheduleSendCycleAudioUpload    定时切片
VoiceBridge::maybeScheduleSegmentPcAudioUpload
VoiceBridge::RunVoiceAudioUploadPipeline     上传流水线
    ↓
VoiceAudioUpload: GetAudioUploadUrl          先申请上传地址
VoiceAudioUpload: zip failed                 打包
VoiceAudioUpload: encrypt failed             AES-GCM 加密
VoiceAudioUpload: upload failed              直传
```

### 上传目标：腾讯云 COS

```
ApplyCosTokenReq / ApplyCosTokenRsp
wetype.update.ApplyCosTokenRsp token tmpSecretId tmpSecretKey
                               bucketName key region downloadUrl
BizAudioUpload / BizLogUpload / CosUploadBiz
aws-sigv4（COS 兼容 S3 签名）
```

### 摘要 CGI

```
VoiceSummaryRecapClient::SendRequest
VoiceSummaryRecapClient::SendPoll        轮询等结果
VoiceSummaryRecapClient::Complete
VoiceSummaryListClient::FetchFirstPage
VoiceSummaryWechatTicketClient::Request  拉微信票据
```

### WebView2 的真实职责

**仅渲染本地摘要 HTML**（`recap.html.enc` 解密后显示），profile 位于：

```
%LOCALAPPDATA%Low\Tencent\WeType\webview\voice_summary\{mini,full}\EBWebView
```

实测该 profile：History 0 行、Cache 0 字节、无 Cookie、远端连接 0 —— 从未加载过远程页面。

**结论：WebView2 不构成联网缺口。**

---

## 10. 无防火墙绕过能力

| 能力 | 结果 |
|---|---|
| 添加/修改防火墙规则（`netsh`、`INetFwPolicy`、`NetFwRule`） | **无** |
| `wt_pc_patch_error_firewall` | 补丁失败错误码枚举，非防火墙操作 |
| `firewall_duration_ms` | 补丁上报耗时字段，非行动逻辑 |

### 注入型 DLL 无独立联网能力

`wetype_tip_core.dll` 的 WS2_32 导入仅两个序号：

```
ordinal 115 -> WSACleanup
ordinal 116 -> WSASetServiceA
```

`socket` / `connect` / `send` / `getaddrinfo` / `WSAStartup` 全部 0 处；
`WinHttp*` / `InternetOpen` / `HttpSendRequest` / `URLDownloadToFile` 全部 0 处。

其 `BizLogUpload` / `BizUserDictUpload` / `CosUploadBiz` 等均为 **protobuf 消息名**，走命名管道 IPC，最终由 `wetype_server.exe` 发出。

---

## 11. 本地引擎数据

| 文件 | 大小 | 作用 |
|---|---|---|
| `BuildIn\slwd_pc_second_level.bin` | 51.7 MB | 核心二级词库 |
| `BuildIn\ckvdmac.bin` | 39.7 MB | 词条索引 |
| `BuildIn\bwcnmacv8.bin` | 31.7 MB | 音节表 v8 |
| `BuildIn\bwcnmac.bin` | 30.4 MB | 拼音音节表 |
| `BuildIn\lmcnmac.bin` | 16.8 MB | n-gram 语言模型 |
| `BuildIn\nlrgpt2_nnlm.bin` | 16.2 MB | **TFLite Transformer**（3 层，`lm_head`） |
| `BuildIn\bwcjpmac_jianpin.bin` | 12.6 MB | 简拼映射 |
| `BuildIn\bwcnenmac.bin` | 6.0 MB | 英文候选 |
| `BuildIn\noun_tag_dict.bin` | 4.3 MB | 名词词性 |
| `voice_engine\vad\model_16k_*.bin` | 85 KB | 语音活动检测（非 ASR） |

`nlrgpt2_nnlm.bin` 内部结构：`transformer/h_._0..2/attn/{MatMul,Softmax}` + `lm_head`，为真实的端侧语言模型。

---

## 12. 性能实测

| 进程 | 工作集 | 私有 | 线程 |
|---|---|---|---|
| `wetype_server.exe` | 167 MB | 81 MB | 54 |
| `wetype_renderer.exe` | 99 MB | 62 MB | 32 |
| `wetype_update.exe` | 291 MB | 336 MB | 188 |
| `wetype_service.exe` | 11 MB | 2 MB | 4 |
| WebView2 ×12（已抑制） | 560 MB | 261 MB | — |

| 项 | 值 |
|---|---|
| 安装体积 | 415 MB |
| 空闲 CPU | 约 2.6% 单核 |
| 188 线程状态 | 全部 Wait（不消耗 CPU） |

---

## 13. 关键结论

1. **单一汇聚点**：所有携带输入内容的云端通道（候选、AI、翻译、埋点、崩溃）都经过 `wetype_server.exe`。
2. **语音摘要独立**：音频上传与摘要 CGI 在 `wetype_update.exe`，使用其自带 libcurl + COS。
3. **注入端无害**：`wetype_tip_core.dll` 无独立联网能力，只能走 IPC 交给 server。
4. **本地能力强**：157 MB 引擎数据含真实 Transformer，离线候选质量有保障。
5. **无绕过能力**：程序不具备修改防火墙规则的能力，进程级出站封锁是可靠闸门。