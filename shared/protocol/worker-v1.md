# Mac 业务 worker 协议 v1

实现：`cmd/freev6-worker`、`internal/worker` 与 `macos/Sources/FreeV6Business`。

worker 是当前用户的子进程，输入输出使用 App 创建的匿名管道。它不监听 HTTP 端口，不接收 shell 命令，也不提供 root 网络控制。退出 App 或关闭 stdin 会取消未完成工作并退出 worker。正常用户数据目录持有独占文件锁，同一目录不允许两个 worker 同时写入；锁随进程退出释放。

## 帧与连接

每帧为 4 字节无符号大端长度，随后为对应字节数的 UTF-8 JSON。长度范围为 1～1,048,576 字节，不含长度头；禁止批处理数组。截断帧、零长度或超限长度关闭连接。stdout 仅输出协议；stderr 为诊断，Swift 客户端持续排空但不直接展示或持久化原文。

请求使用 JSON-RPC 2.0，`id` 必须是非空且不超过 64 字节的字符串；客户端为每次请求生成独立 UUID。方法名最多 128 字节，参数使用对象。无 `id` 的通知不产生回复，未知通知忽略。回复保留原 `id`，恰好包含 `result` 或 `error`。

首个业务调用之前完成握手：

```json
{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{"protocolVersion":1}}
```

握手结果包含 `protocolVersion`、`workerVersion`、`platform`、`architecture`、`capabilities`、`maxFrameBytes`、`maxInFlight`。双方核对版本及架构，拒绝重复握手。当前能力包括 `settings.get`、`settings.patch`、`runtime.status`、`runtime.download`、`warp.register`、`geodata.status`、`geodata.prepare`、`configuration.prepare`、`traffic.get`、`traffic.observe` 以及下述四个链式配置方法。

最多同时处理 8 个请求，输出队列最多 16 条消息。Swift 客户端的消息与写入队列也有上限。worker 普通请求期限为 30 秒，`runtime.download` 和 `geodata.prepare` 为 180 秒，`warp.register` 为 45 秒；Swift 握手/设置调用期限为 10 秒，核心及规则数据检查为 35 秒，准备为 190 秒，注册为 50 秒。客户端超时会断开连接并回收 worker，重新载入时启动新进程。进度不延长操作的总期限。

取消使用通知：

```json
{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":"request-1"}}
```

取消是尽力而为。设置在原子替换前检查取消；替换完成后不能把已写入的数据描述为撤销成功。客户端取消、超时或断线后，未确认的保存结果标为未知，重新载入确认；不能显示“已保存”。迟到回复不得覆盖新的界面状态。

## 设置

`settings.get` 接受空参数对象，返回：

```json
{"schemaVersion":1,"revision":0,"settings":{"mode":"rule","campusCidrs":["edu.cn"],"blacklist":[],"devMode":false}}
```

缺少设置文件时返回上述默认值；损坏文件或未知 schema 拒绝读取和覆盖。持久化文件位于显式 DataDir 下的 `proxy-preferences.json`，普通用户所有、权限 0600；以同目录临时文件、fsync、原子 rename 和目录 fsync 保存。首次保存后 revision 从 0 增为 1，每次成功保存递增。

`settings.patch` 接受：

```json
{"expectedRevision":0,"changes":{"mode":"global","devMode":true}}
```

未发送的设置保持原值，显式空数组清空列表，null、未知字段和错误类型拒绝。可编辑字段仅为 `mode`、`campusCidrs`、`blacklist`、`devMode`；列表最多各 2,048 项，每项最多 1,024 字节，持久化 JSON 总大小最多 256 KiB。域名、CIDR 和模式沿用共享 Go 校验；规范化后的完整快照作为保存结果返回。`expectedRevision` 与当前值不一致时返回冲突，客户端必须载入新值后重新编辑。

Mac 的 patch 契约与 Windows 历史 PUT 契约分开。Windows 继续保持原有基本字段替换、部分字段省略即保留的行为；平台登录项、热点开关和敏感配置来源不通过 Mac 的代理规则方法写入。

## 核心安装包与进度

`runtime.status` 和 `runtime.download` 仅接受空参数对象。worker 从编译时嵌入的 `internal/mihomo/runtime-assets.json` 选择自身操作系统与架构对应的固定资产，不接受调用方指定 URL、目标平台、文件路径或摘要。Windows amd64 保留 v3 核心，Darwin Intel 使用 v1 基线。

`runtime.status` 校验已有缓存；`runtime.download` 先检查缓存，缺失或摘要损坏时依次尝试固定镜像。两者返回 `resourceId`、`version`、`platform`、`architecture`、`archive`、`sha256`、`binarySha256`、`available`。`available` 仅表示安装包已准备并校验，不表示 root 核心已安装或网络已连接。绝对缓存路径不通过协议返回。

缓存位置为显式 CacheDir 下的 `runtime/<archive-sha256>/<archive-name>`。压缩包和解压内容分别限制为 150 MiB，分别校验固定摘要，并检查 Mach-O/PE 的架构与可执行类型。ZIP 仅允许预期的单个普通文件；gzip 文件名不参与输出路径。校验用的临时二进制会删除，只保留完整安装包。失败和取消清理本次临时文件，完成验证后原子替换缓存。后续网络服务必须独立复验固定摘要和架构，再安装到 root 所有的目录。

下载每条镜像的无进展期限为 10 秒，硬期限为 60 秒，总期限仍为请求的 180 秒。切换镜像时已接收字节数可以回到零；未知总长度为 -1。

进度使用无 `id` 的通知：

```json
{"jsonrpc":"2.0","method":"$/progress","params":{"requestId":"download-1","sequence":2,"phase":"downloading","received":4096,"total":10000,"attempt":1,"attempts":6}}
```

阶段为 `checking`、`downloading`、`verifying`。同一请求的序号严格递增但可以跳号；同一阶段和线路的通知合并至最多每 200 ms 一次。输出拥堵时允许丢弃进度，不阻塞下载、取消或最终结果；成功只能依据最终回复确认，不能依据百分比推断。Swift 仅分发当前请求的新序号，忽略已经取消或完成的请求进度。

同一 worker 只允许一个核心检查/准备任务。取消后清理尚未结束时，新调用可能收到 -32003；稍后重新检查即可确认缓存结果。取消晚于原子替换时，已完成安装包可以保留，不能承诺所有取消都撤回磁盘提交。

## 规则数据

`geodata.status` 和 `geodata.prepare` 只接受空对象，拒绝外部路径、URL 和摘要。固定清单位于 `internal/mihomo/geodata-assets.json`，包含上游完整提交、三个文件名、大小及 SHA256。当前锁定 `fb6bd25ca61dd918d36b0f61b4bad67dfc278bcf`；更新清单需要重新获取官方校验文件并通过真实核心检查，不跟随可变的 latest 标签。

返回 `resourceId`、`revision`、`available`、`files`；每个文件包含 `name`、`size`、`sha256`、`available`。三个文件为 `GeoSite.dat`、`geoip.dat`、`country.mmdb`，全部通过摘要校验才返回整体可用。缓存目录为 `CacheDir/geodata/<revision>`，绝对路径不出现在返回值中。状态查询只读；准备先检查缓存，再尝试显式 `ResourceDir/Geodata/<revision>` 中的只读种子，最后下载固定提交的镜像数据。当前 Mac 构建不内置数据二进制，首次使用通过准备入口下载。

文件在同目录临时写入、校验、fsync 后原子替换。每份文件以清单大小为下载上限，拒绝超限、截断及摘要错误；失败或取消清理未提交文件，已验证并提交的文件保留供重试使用。资源状态查询和准备共用单独的互斥锁，核心准备与规则数据准备可独立进行。进度增加可选 `asset` 字段及 `copying` 阶段；文件或阶段变化立即通知，同一文件、阶段、线路内合并通知。

Darwin 生成配置固定相同版本的 geox-url 并关闭核心自动更新。后续 root 服务必须依据自身可信清单重新验证私有副本；worker 的 `available` 不构成 root 信任或连接成功依据。

## WARP 注册与凭据交接

`warp.register` 接受 `{ "name": "freev6-macos" }`，空名称使用 `freev6-macos`。规范化后最多 128 个 UTF-8 字节，拒绝控制字符和未知参数；不能指定 API 地址、输出路径或令牌。单个 worker 同时只允许一次注册，不自动重试创建账户的请求。

成功返回 `{ "schemaVersion": 1, "device": { ... } }`。`device` 包含 `deviceId`、`token`、`privateKey`、`peerPublicKey`、`ipv4`、`ipv6`、`registeredAt`，字段与共享 `warp.Device` 对应。Go 检查账户标识、令牌长度、P-256 SEC1/SPKI 密钥、地址和日期；Swift 在存储前再次检查契约。该结果包含敏感信息，只通过私有管道交给 App；不得进入日志、普通配置文件、下载缓存或诊断导出。

进度复用 `$/progress`，阶段为 `registering`、`enrolling`；字节计数为 0，总数为 -1，线路字段为 0。上游响应最大 1 MiB，重定向拒绝，错误正文不返回给 UI。注册成功只表示获得凭据，App 必须在 Keychain 写入确认后才能显示“凭据已保存”。

App 在用户操作后访问钥匙串；先确认已有凭据的版本和替换意图，再发起注册。Keychain 条目以随机 revision 执行条件替换或删除，版本冲突不覆盖。保存失败时保留原记录及内存中的新结果，“重试保存”不再调用注册接口。待保存结果需要保存或明确放弃后才能正常退出；强制结束进程仍会丢失该内存结果。

取消是尽力而为，可能发生在服务端已创建设备之后，不能承诺撤销远端注册。删除本机凭据或放弃待保存结果同样不会删除 Cloudflare 设备。没有确认的远端结果不写入本地，不自动反复注册。

## 链式文件与订阅

| 方法 | 输入及结果 |
| --- | --- |
| `chain.preview` | 提供 `expectedRevision`、32 字节 Base64 编码的 `key`，以及 `file`（系统面板选定的绝对路径）、`url`（HTTP/S）或 `refresh: true` 三者之一。成功返回随机 `token` 和规范化的 `nodes` 供 Swift 校验。 |
| `chain.commit` | 提供相同的 `expectedRevision` 和预览的 `token`。每个 worker 只保留一个候选，令牌有效期两分钟。成功后启用该配置，并返回新的设置快照。 |
| `chain.enable` | 提供 `expectedRevision` 和布尔值 `enabled`，影响下次连接。 |
| `chain.clear` | 提供 `expectedRevision`，删除该配置并返回新设置快照。 |

文件和订阅只提取 Clash/mihomo YAML 的 `proxies`。限制为 2 MiB、1 至 64 个节点，加上原订阅地址后的规范化内容上限为 320 KiB。节点名称须唯一。接入点固定为 WARP 选择组；来源文件中的控制器、监听、规则和分组全部忽略。Swift 在提交前逐项校验 HTTP、SOCKS5、Shadowsocks、Trojan、VLESS、VMess 的限定字段。下载、预览、字段校验或版本冲突失败均保留上次的配置。具体加密套件与服务器可达性仍应分别通过核心配置检查与连接验证。

App 以当前用户身份访问独立的钥匙串条目并通过私有管道传递密钥。worker 用 AES-256-GCM 加密节点和原订阅地址，持久化密文与公开摘要。设置响应只含 `chain: {source,enabled,names}`，普通规则保存共用 revision，并保留链式配置。刷新只由用户发起。URL、节点字段和密钥均不得写入诊断。清除配置后可继续使用普通 WARP，清除操作无需解密密文。

## 连接配置交接

`configuration.prepare` 当前只接受 `source: "warp"`、`settingsRevision`（必填无符号整数）、`credentialRevision`（Keychain 条目的 UUID）、`tunnel`（仅 `privateKey`、`peerPublicKey`、`ipv4`、`ipv6`），以及启用链式配置时的 `chainKey`。参数最多 32 KiB，未知字段、注册令牌、设备 ID、URL、文件路径及其他 source 拒绝。worker 不读取 Keychain，也不注册账户或自动下载缺失资源。

worker 先读取并核对已保存设置，再重新检查固定核心和整套规则数据；生成后再次确认设置 revision。没有前置资源返回 -32006，设置已变化返回 -32004，非法输入返回 -32602。单个 worker 仅允许一个准备任务，普通请求期限为 30 秒，Swift 调用为 35 秒。进度为 `checking`、`rendering`，不包含凭据或配置片段。

结果包含 `schemaVersion: 1`、`settingsRevision`、`credentialRevision`、`runtimeId`、`geodataId` 和 `configuration`。后者最大 512 KiB，仅包含 `mode`、`proxies`、`proxy-groups`、`rule-providers`、`rules` 五类业务字段，复用 Go 渲染器及默认黑名单/开发者模式语义；不交接 controller、secret、TUN、DNS、端口、全局路径等系统字段。结果内仍有 MASQUE 私钥，只允许私有进程通信及后续受控 XPC 使用，不写普通配置文件、日志或 UI 状态。

Swift `FreeV6Configuration` 校验模块对未知字段、节点字段及协议、密钥/IP、分组引用和循环、规则语法、固定提供者 URL/相对路径实施限制。客户端核对设置与凭据 revision、资源 ID、模式、28 个 MASQUE 节点的凭据，以及链式节点的名称及顺序。独立网络服务也执行结构校验，再按服务策略组装配置并交给固定核心检查。链式模式限定接入组与出口组的成员，GLOBAL 指向链式出口，末尾按顺序要求 MATCH 链式和 UDP 拒绝规则。

配置检查和连接操作按需触发 Keychain 读取。`WarpRegistration.withSavedTunnel` 与注册、保存、删除共用互斥状态，读取后只交出隧道材料；异步准备结束后再次检查存储 revision。发现外部替换、拒绝授权或取消即拒绝结果。检查页面只保存版本、模式和数量摘要，含私钥的文档在本次操作结束后不留在 ViewModel。结果是一次配置生成记录；真正启动仍必须复验资源、设置绑定和服务身份。

## 流量统计

`traffic.get` 接受空对象，返回 `month`（用户本地年月）、`monthly` 和 `total`。后二者分别包含 `upload`、`download` 两个无符号 64 位字节数。`traffic.observe` 接受 `sessionID`、`upload` 和 `download`，其中字节数来自服务已确认的本次会话累计计数，返回同结构的汇总。

每个会话按方向分别记录累计数的最大值。新观测只把高出的部分计入本地观测月份，同一请求重试、旧样本迟到或进程重启均可复用。worker 在用户数据目录下以原子替换保存每个会话的分月增量。异常中止前尚未采集的字节可能遗漏。存储失败时返回 `StorageError`，界面应提示重新读取。

## 错误

| code | 含义 |
| --- | --- |
| -32700 | JSON 无法解析 |
| -32600 | 请求结构错误或重复握手 |
| -32601 | 未实现的方法 |
| -32602 | 参数或配置无效 |
| -32603 | 内部错误；不泄露底层诊断 |
| -32001 | 尚未握手 |
| -32002 | 协议版本不兼容 |
| -32003 | 请求 ID 正在执行或达到并发上限 |
| -32004 | 设置版本冲突 |
| -32005 | 配置读写失败，需要重新载入确认状态 |
| -32006 | 核心或规则数据下载、校验或缓存操作失败 |
| -32007 | WARP 注册或返回凭据校验失败；不回传上游错误正文 |
| -32008 | 连接业务配置生成或大小检查失败 |
| -32800 | 请求被取消或超时 |

## 验证

Go 测试覆盖 Windows 字段保留、原生 patch、原子保存和版本冲突、损坏配置保留、握手/方法/参数拒绝、并发、取消、父进程断开和帧限制。Swift 测试覆盖分片帧、截断及同一共享样本。设置样本位于 `shared/fixtures/worker-settings.json`，两端直接读取同一文件。

真实 Swift→Go 测试需要先构建 worker，再给 Swift 测试传入 `FREEV6_WORKER_TEST_BINARY`。它验证并发握手、保存/规范化、冲突拒绝、非法配置拒绝、worker 退出及重启后读取；另外传入 `FREEV6_RUNTIME_FIXTURES_DIR` 可验证真实官方核心安装包与进度分发。`probe-worker.py --download-runtime` 验证正式镜像下载链路。测试不注册 WARP，不安装系统服务，不修改 DNS。

WARP 的 Go 测试使用本机 HTTP 服务器验证两阶段请求与错误处理；Swift 使用共享的 `shared/fixtures/warp-credential.json` 验证编码、密钥格式与存储流程。该样本使用公开可重复的合成密钥和假令牌，禁止用于真实连接。设置 `FREEV6_TEST_PRIVATE_KEYCHAIN=1` 可创建临时独立钥匙串，验证实际读取、条件替换及删除后清理；测试不访问登录钥匙串，未开启时该项明确跳过。此实验不代表 ad-hoc 应用升级授权或真实 Cloudflare 注册已通过。

设置 `FREEV6_GEODATA_FIXTURES_DIR` 为官方三份数据所在目录，可运行 Go 固定摘要校验和 Swift→Go 只读种子复制、缓存修复、重启读取验证。`probe-worker.py --prepare-geodata` 验证生产下载流程，并独立计算缓存摘要。完整配置检查使用 `probe-runtime.py --check-config <full-config.json> --geodata-dir <fixtures>`；它只执行核心 `-v/-t`，不能替代网络连接或远端规则更新验收。

`shared/fixtures/warp-business-configuration.json` 使用公开合成凭据和共享设置样本生成，Go 验证业务语义，Swift 验证解析与拒绝场景。真实 Swift→Go 配置测试同时需要三项环境变量 `FREEV6_WORKER_TEST_BINARY`、`FREEV6_RUNTIME_FIXTURES_DIR`、`FREEV6_GEODATA_FIXTURES_DIR`；覆盖缺少资源、版本冲突、资源绑定、结构往返及用户目录无凭据落盘。此测试不读取个人 Keychain、不发起真实注册或连接。
