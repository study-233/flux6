# macOS 网络服务协议 v2

此文保留 v2 资源交接设计；当前服务使用 [v3](service-v3.md)，包含配置检查接口。v3 沿用下文的资源校验与存储约束，协议版本字段改为 3。

此协议属于 `NSXPCConnection`，与 Go worker 的 JSON-RPC v1 相互独立。v2 新增固定资源交接；没有启动核心、设置 DNS 或执行任意命令的接口。App 与安装工具需先确认握手版本一致，再调用对应方法；旧版客户端不能据握手失败继续安装资源。

## 传输与身份

生产 Mach service 固定为 `dev.freev6.network-service`。服务依据安装登记的 UID/CDHash 校验调用方，客户端也验证服务 CDHash。Release 服务仅接受 root 启动且不接受路径参数；Debug 的隔离探针只允许普通用户及独立 service 名称。

方法的请求、回复均为有界 JSON `Data`，最多 4096 字节。所有请求带 `protocolVersion: 2` 与 UUID `requestID`；回复原样关联请求。资源内容单独通过 `FileHandle` 传递，不放进 JSON 或字符串。资源方法严格检查键集合；不能提交 UID、URL、目标路径、期望摘要或执行参数。

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

资源不含用户凭据，多个登记用户可复用。四项全部通过仍只表示资源就绪；后续会话启动必须再次验证使用的受控文件，不能使用旧状态响应作为执行授权。业务文档复验、系统配置组装、核心启动与恢复事务尚未接入 v2。

普通用户域的 Debug XPC 探针可证明跨进程 FD 传递与校验机制；不能证明 root 安装、TUN、网络恢复、macOS 13 或 Intel 真机已经通过。App 的缓存到服务交接及完整卸载数据清理仍需后续接入。

实现依据：[Apple XPC 服务说明](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)、本机 SDK 的 `NSFileHandle<NSSecureCoding>`、[zlib gzip 解码与终止语义](https://zlib.net/manual.html)。
