# macOS 网络服务协议 v3

v3 保留 [v2 的资源与身份边界](service-v2.md)，增加 `checkConfiguration(_:reply:)`。所有方法均使用 `protocolVersion: 3`，旧客户端必须停止调用并通过既有重新登记/更新流程处理版本不兼容。Go worker 仍使用独立的 JSON-RPC v1。

## App 交接

App 的“检查连接配置”先从 worker 获取经过设置/凭据 revision 绑定的 WARP 业务配置。网络服务未就绪时只进行本机检查，界面明确标为“本机配置已检查”；已就绪时执行以下流程：

1. 重新验证已安装服务的代码身份，完成双向身份和版本握手。
2. 调用资源状态；缺失或损坏的项按 App 编译时清单从固定缓存位置打开，再通过 FD 交接。路径、摘要、架构和文件名均不从业务配置取值。
3. 服务独立复验并发布资源，App 再查询一次完整状态。已安装且通过复验的资源可复用，单项失败保留已成功项。
4. 发送业务配置检查请求；服务再次检查资源与配置。App 核对回复的请求、策略、设置/凭据版本和统计摘要。
5. worker 设置 revision 与 Keychain revision 再次确认后，才显示“配置已通过服务复验”。整个异步过程保持凭据操作互斥，阻止保存、服务变更及重复检查；界面不保留包含私钥的文档。

App 在此流程中不自动安装 daemon，不弹出管理员授权。系统服务安装仍为独立的显式操作。所有“检查通过”均为当前快照；未来启动必须重新校验，不能把旧摘要当作会话授权。

## 配置检查契约

请求 Data 上限为 `512 * 1024 + 4096` 字节，精确包含以下字段：

| 字段 | 约束 |
| --- | --- |
| `protocolVersion` | 3 |
| `requestID` | UUID |
| `runtimeID` | 服务当前架构的固定核心资源 ID |
| `geodataID` | 服务固定的完整规则数据组 ID |
| `settingsRevision` | UInt64；用于交接关联，服务不把其视为对用户配置文件的独立证明 |
| `credentialRevision` | UUID；由 App 再次核对 Keychain，服务不访问用户钥匙串 |
| `configuration` | 五类业务字段：`mode`、`proxies`、`proxy-groups`、`rule-providers`、`rules` |

服务调用 `FreeV6Configuration` 的严格解码器，检查节点协议/密钥/IP、分组引用与循环、规则语法、提供者来源和受控相对路径。当前仅支持 WARP MASQUE 业务，链式和备用配置另行扩展。未知字段、账户 token、系统配置和任意路径均拒绝；解码错误统一转换为不含凭据的固定说明。调用身份来自 XPC 登记，UID 0 的安装恢复工具不使用此业务方法。

服务在资源互斥区内复验固定核心和全部数据，然后在内存中组装系统字段。回复最多 4096 字节，仅含 `protocolVersion`、`requestID`、`policyVersion`、`settingsRevision`、`credentialRevision`、`mode`、`proxyCount`、`ruleCount`。不返回私钥、controller secret、socket 路径、完整配置或可复用的启动令牌。检查不写会话目录，不启动核心，也不更改网络。

## 系统策略 v1

系统字段由 Swift 服务提供，业务 DTO 无法覆盖。当前保留本机 mixed-port 7890、loopback 绑定、MASQUE 业务、IPv6、fake-IP DNS 和动态 utun 配置；关闭 LAN 访问、Geo 自动更新、TCP/TLS controller 和外部 Web UI。规则数据 URL 固定同一可信提交。

Unix controller 使用服务生成的 UUID，路径为 `/Library/Application Support/dev.freev6.desktop/sessions/<UUID>/c.sock`，共 100 个 UTF-8 字节，低于 Darwin `sun_path` 的 104 字节容量。系统字段还生成 32 字节随机 secret，但锁定核心的 Unix listener **不使用该 secret 做认证**。

v1.19.31 的 Unix listener 会将 socket chmod 为 0666，并将空 secret 传给 router。启动前必须由服务创建并验证 root 所有、0700、无写入型 ACL 的会话目录；不能让核心自行按 0755 创建父目录。App 只能通过受限 XPC 访问 controller，后续服务适配器必须列举允许的节点/流量操作，不能转发任意 controller 路由。依据：[固定版本 Unix listener](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/route/server.go#L237)、[固定版本 controller 配置](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/config/config.go#L766)。

DNS 监听暂沿用 `127.0.0.1:1053`。系统 DNS 通常使用端口 53，后续必须完成已规划的专用 DNS 地址劫持或 loopback 53 转发验证；不能直接设置系统 DNS 为 127.0.0.1 并假定解析可用。配置策略会随实际 DNS 事务验证更新。

## 验证范围

`probe-service.py --runtime-fixtures … --geodata-fixtures …` 在普通用户域运行真实独立服务，调用与 App 相同的资源交接和配置客户端，检查缺资源拒绝、系统字段注入拒绝、摘要回复、资源复用和无配置落盘。探针使用公开合成业务样本，经同一服务组装器生成完整配置后执行真实核心 `-t`；服务方法本身尚未执行核心 `-t`。

`probe-controller.py --core …` 使用已校验的固定核心，以普通用户运行无 WARP、无 provider、关闭 TUN/DNS/代理的最小配置，验证私有父目录、100 字节 Unix 路径、`GET /version`、无 IP socket 和退出回收。

以上不代表 root 会话目录、跨用户隔离、真实 TUN、系统 DNS、故障恢复、macOS 13 或 Intel 已完成验收。下一步仍需实现会话持久化、受控核心进程、启动检查、DNS 事务及完整退出/恢复流程。
