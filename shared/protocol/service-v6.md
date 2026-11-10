# macOS 网络服务协议 v6

当前客户端与服务使用协议版本 6，系统配置策略版本 2；Go worker 的 JSON-RPC v1 独立维护。版本不匹配时停止业务调用并重新登记兼容的服务，不能回退到旧协议解释成功。这里集中保存当前资源交接、配置检查、运行会话和控制契约，旧版本说明由 Git 历史保留。

## 传输与身份

生产 Mach service 固定为 `dev.freev6.network-service`。服务依据安装登记的 UID/CDHash 校验调用方，客户端也验证服务 CDHash。Release 服务仅接受 root 启动且不接受路径参数；Debug 的隔离探针只允许普通用户及独立 service 名称。

握手与资源方法的请求、回复均为有界 JSON `Data`，最多 4096 字节。所有请求带 `protocolVersion: 6` 与 UUID `requestID`；回复原样关联请求。资源内容单独通过 `FileHandle` 传递，不放进 JSON 或字符串。资源方法严格检查键集合；不能提交 UID、URL、目标路径、期望摘要或执行参数。

| XPC 方法 | 请求 | 回复 |
| --- | --- | --- |
| `handshake(_:reply:)` | `protocolVersion`、`requestID` | 相同关联字段、`serviceVersion`、`privileged` |
| `resourceStatus(_:reply:)` | `protocolVersion`、`requestID` | `resources: [{id, available}]`，每次重新验证已存内容 |
| `installApprovedResource(_:source:reply:)` | `protocolVersion`、`requestID`、`resourceID`，另加文件描述符 | 单项 `resources: [{id, available: true}]` |

资源回复同时包含 `protocolVersion` 和 `requestID`。错误仅返回固定操作原因；不回传系统路径、文件内容或账户数据。客户端 35 秒超时；服务在复制、摘要和解压循环检查总计 30 秒期限。文件系统读取本身若阻塞，不能把循环期限描述为硬实时终止保证。超时后可查询状态并重试相同 ID，不据客户端超时推断安装必定未发生。

## 可信资源与存储

服务只信任编译进签名二进制的 `ApprovedResources.generated.swift`。它由仓库的核心/规则数据固定清单生成，`swift.sh` 在构建前检查同步；清单更新后运行 `python3 scripts/macos/generate-resource-catalog.py`。运行期不读取客户端传入或用户目录中的摘要清单。

- 核心 ID 与 worker 一致：`mihomo-darwin-<arch>-<version>`；只接受当前服务构建架构的官方 gzip。
- 规则数据单文件 ID：`geodata-<revision>/GeoSite.dat`、`geodata-<revision>/geoip.dat`、`geodata-<revision>/country.mmdb`。它们的共同前缀对应 worker 的资源组 ID；ID 通过清单精确查找，不作为路径拼接输入。
- 来源必须为调用 UID 拥有的普通文件，不能有多个硬链接或组/其他用户写权限。恢复工具的 UID 0 不使用资源安装方法。服务复制描述符并设置 close-on-exec；`pread` 不依赖或修改共享文件偏移。
- 固定存储目录为 `/Library/Application Support/dev.freev6.desktop/resources`，生产环境 root 所有、0700。所有路径分量检查所有权、写权限与符号链接；额外拒绝可授予写权限的 macOS ACL（包括继承规则），不能只依据 POSIX mode 判断可信。文件操作使用目录描述符和固定文件名。
- 先复制到私有 0600 暂存文件并检查摘要，再复读私有副本。核心只解码一个 gzip 成员，检查 CRC、尾部、压缩与解压 150 MiB 上限、二进制摘要及 Mach-O 架构；数据按固定大小及摘要复验。
- 内容验证完成并 fsync 后原子发布；核心权限 0500、数据 0400。摘要错误不会替换已有文件；目标符号链接、硬链接、非预期所有者或可被其他用户写入的文件直接拒绝。
- 一个服务实例持有文件锁，操作另用互斥锁串行化；忙碌立即返回。重启取得文件锁后，仅清理符合暂存命名、所有权和普通文件条件的中断副本，再按需复验已发布内容。

资源就绪仅表示固定文件通过验证，不能作为配置检查或网络运行成功的证据。

## 配置请求

`checkConfiguration` 接受最多 `512 * 1024 + 4096` 字节。配置由严格 DTO 解码，拒绝未知字段、任意系统参数和路径；调用身份来自 XPC，不接受客户端提交 UID。

| 字段 | 当前约束 |
| --- | --- |
| `protocolVersion` | 6 |
| `requestID` | UUID |
| `runtimeID` | 当前架构的固定核心资源 ID |
| `geodataID` | 固定完整规则数据组 ID |
| `settingsRevision` | UInt64，与 worker 设置快照关联 |
| `credentialRevision` | UUID，与凭据或备用配置快照关联 |
| `configuration` | 业务字段 `mode`、`proxies`、`proxy-groups`、`rule-providers`、`rules` |
| `profileSource` | 仅纯校园备用配置携带 `cloud`，WARP 配置不携带 |

App 从 worker 准备配置，完成服务身份握手、缺失资源 FD 交接和状态复验后发送检查请求。结果必须关联请求、设置和凭据修订，随后再核对 worker 与 Keychain 修订。界面不保留含私钥文档；配置检查不隐式安装系统服务。

## 检查流程

1. 从 XPC 登记取得非零客户端 UID，严格解码请求；路径、session ID、job 标签、PID、摘要或启动参数不由客户端传入。
2. 持有资源互斥和安装共用的网络锁，先恢复已有准备或检查记录。未知记录、活跃旧宿主或无法确认的任务状态阻止新检查。
3. 复验固定资源，生成 session UUID，复制可信核心/Geo 数据并再次检查独立副本。配置以 0600 写入 0700 私有目录，配置摘要与设置/凭据 revision 绑定。
4. 采用[检查记录 v2](session-check-v2.md)，在注册和启动副作用之前持久化意图。独立 launchd job 只运行固定核心 `-t -d <私有目录> -f <配置>`，无自动重启或自动运行。
5. 核心正常退出或超时后先完成停止与回收，再持久化退出结果。移除 job、清理已知临时文件及日志记录后，才回复成功或已处理的核心检查失败。

核心输出不进入 RPC、服务日志或 UI。服务启动时也会尝试恢复遗留检查；恢复失败保留资料，仍提供身份握手和明确的检查错误，不以重启循环掩盖问题。当前服务自身留下的未确认启动记录不被自动当作旧记录删除，需要新的服务实例确认旧命令进程组已经退出。

## 回复

请求采用下表字段，协议版本为 6。回复上限 4096 字节，包含原有的版本、请求、策略、设置/凭据 revision、模式和节点/规则统计，另增加 `coreValidated: true`。

该字段只在实际核心返回 0 且 job、私有会话文件和恢复记录均已清理后产生。App 同时校验版本、请求关联、revision、统计与 `coreValidated`，随后再核对 worker 和 Keychain revision。界面显示“配置已通过核心检查”；没有服务时仍只显示“本机配置已检查”。两者均不表示已连接，也不是后续启动令牌。

核心非零退出和检查超时返回固定错误，不回传原始输出或凭据。无法确认任务退出、移除或文件清理时返回恢复错误，保留记录；下一次检查不能覆盖它。客户端等待配置检查最多 180 秒，其他资源操作仍为 35 秒。客户端超时只结束等待，不证明服务端操作已停止；服务的网络锁、受控命令、核心等待和恢复日志继续约束后续操作。文件系统阻塞不能被描述为硬实时取消。

## 系统配置策略

服务组装系统字段，业务 DTO 无法覆盖。当前策略版本 2，使用本机 7890 mixed 入站、loopback 绑定、IPv6、fake-IP DNS、受控 TUN 和私有 Unix controller，关闭 LAN、外部 Web UI、TCP/TLS controller 与 Geo 自动更新。具体 DNS、路由和监听参数以 `ServiceConfigurationAssembler` 为准；网络启动与恢复按运行事务验证，不以配置生成推断系统 DNS 可用。

Unix controller 位于服务拥有的私有会话目录，路径长度必须小于 104 UTF-8 字节。固定核心的 Unix listener 不以配置中的 secret 作为认证边界；私有父目录的所有权、0700 权限、ACL 检查和受限 XPC 方法共同约束访问，客户端不能转发任意 controller 路由。

## 运行会话

| 方法 | 输入 | 成功结果 |
| --- | --- | --- |
| `sessionStatus` | `protocolVersion`、`requestID`，可附上本人已确认的 `sessionID` | 返回当前状态。仅匹配正在运行的本人会话时续期 |
| `startSession` | 最近一次空闲回复的 `idleToken`，以及 `request` 中的完整配置检查请求 | 校验资源、启动固定核心并确认隧道、DNS 和出口后返回 `running`。回复关联内层请求 ID 和使用的设置、凭据修订号 |
| `stopSession` | `protocolVersion`、`requestID`、`sessionID`、正整数 `revision` | 核对调用人和修订号，服务恢复 DNS、停止核心并清理后返回 `stopped`。已空闲时重复停止返回当前空闲状态 |

所有回复带 `protocolVersion`、`requestID` 和 `phase`。空闲回复仅附 `idleToken`。服务在接收启动、完成清理及重新启动时更换该令牌。本人运行回复附会话标识、会话修订号、设置修订号和凭据修订号。恢复中的状态为 `recoveryRequired`，记录可定位时附同一组字段。其他已登记用户只能读取 `occupied`。双方拒绝超大请求，客户端校验回复大小、请求对应关系及各状态允许的字段。

服务保留安装级网络锁，并按[运行记录 v3](network-run-v3.md)恢复。桌面 App 在窗口隐藏时也继续查询，正常每 5 秒发送本人会话标识。服务在 30 秒内未收到匹配续期、发现核心退出或服务重启时执行恢复。遇到恢复冲突会保留记录供重试。客户端查询、启动、停止的等待上限分别为 6、180、60 秒。客户端超时后重新查询真实状态。

主窗口、菜单和状态菜单共用会话状态。退出前确认并恢复本人的会话，恢复失败保留重试入口。普通用户隔离探针不替代管理员安装、实际系统 DNS、生产隧道、跨用户及目标系统实机验收。

## 运行控制

`controlSession` 接受最多 1 KiB 的 JSON 请求。每次调用携带请求 UUID、动作和目标会话的 UUID 与修订号。服务核对调用人的 UID、有效租期、活动的核心任务和隧道，再连接会话的私有 controller。回复最多 64 KiB，客户端核对请求 ID、会话和动作。

| 动作 | 附加字段 | 结果 |
| --- | --- | --- |
| `inspect` | 无 | 当前模式、控制令牌及当前配置中允许操作的分组。分组分别返回实际成员、首选成员和可选列表 |
| `setMode` | 最近的控制令牌、模式 | 确认核心实际采用的规则、全局或直连模式 |
| `select` | 控制令牌、分组、成员 | 只接受接入点组或链式代理组的现有成员，回读实际使用的节点。接入点选择未生效时尝试恢复原先的首选策略 |
| `unpin` | 控制令牌 | 清除接入点首选并回读自动选择状态 |
| `delay` | 分组、成员 | 用服务端的固定目标测速，返回毫秒数、超时或不可用 |
| `traffic` | 无 | 本次采样的上传、下载速率及本会话累计字节 |
| `download` | 分组、成员 | 固定 HTTPS 目标的下载字节数、有效传输秒数和测量时间 |
| `cancelDownload` | `token` 为该次 download 的请求 UUID | 取消同一 UID、同一会话中的对应测试 |

写操作会轮换控制令牌，旧菜单无法重放上次写入。未获确认时客户端重新读取实际状态。测速和流量采样在慢速 I/O 期间释放启停锁，返回前再次校验会话。取样请求不续租，窗口隐藏时仍由桌面会话发送心跳。

用户域探针使用回环 HTTP 代理挂起固定目标的测速请求，再从另一条认证连接执行断开。验收要求在 5 秒测速期限之前确认停止并恢复测试 DNS，新会话拒绝旧会话标识。桌面控制模型另行验证迟到结果不会覆盖新会话延迟。[隔离复现入口](../../scripts/macos/probe-service.py)

配置检查和启动的配置体仅在备用出口时携带 `profileSource: "cloud"`，`credentialRevision` 对应此备用快照的 UUID。接收方校验标记与纯校园节点结构匹配，拒绝混入 WARP、额外 dialer、直连全局组或删掉 UDP 兜底。旧 WARP 请求沿用原有字段。维护者公告许可由普通用户 worker 在准备时检查，App 在实际发出启动请求前再次核对。

0.5.6 的下载测试只允许一个并发任务。服务生成独立的回环 HTTP 入站、随机认证密码及隐藏测试分组；默认出口为 REJECT，测试时仅切换测试分组，不修改正常接入或链式代理选择。读取私有会话配置后校验监听进程归属，再通过指定节点请求固定的 Cloudflare 下载接口，限制 10 秒和 32 MiB，不接受客户端 URL、路径、凭据或大小参数。完成、失败或取消后关闭下载进程并将测试分组复位为 REJECT。会话停止会取消测试，返回前再次核对租期和会话；下载结果不跨会话显示。取消可先于下载工作注册到达，服务会暂存最多 64 条、60 秒的取消标记，避免取消后又开始下载。
