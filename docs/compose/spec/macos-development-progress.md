# macOS 开发进度

目标：按照 macOS 支持计划完成原生客户端、共用业务、网络服务、DMG、应用更新及验收。开发分支为 `mac`，起点 c528f26。当前整体目标尚未完成。

## 阶段状态

| 阶段 | 状态 | 当前证据与剩余工作 |
| --- | --- | --- |
| P0 技术验证 | 进行中 | 原生构建、早期基础 UI、独立用户级 XPC 服务、只读 DNS、Keychain 单次读写、Darwin 完整配置与 GeoSite 解析、隔离更新助手的真实升级/拒签已通过；root 安装/恢复、实际联网、quarantine 分发、凭据升级和最低系统尚未通过 |
| P1 共用业务与协议 | 进行中 | 已接入共享设置、核心/规则资源、WARP 注册与 Keychain、WARP 业务配置准备及 Swift 校验；真实注册、订阅/链式/备用配置及 root 启动交接待完成 |
| P2 原生应用骨架 | 进行中 | 已有导航、共用顶部栏命令、窗口焦点、服务与核心准备入口、真实配置客户端；正式 Xcode targets、完整菜单能力与页面交互验收待完成 |
| P3 原生网络服务 | 进行中 | 已有双向身份握手、App 资源 FD 交接/独立复验/受控存储、XPC v4 实际核心检查和清理确认、签名 payload 校验、安装/卸载事务与回退；正常网络会话协议及 root 实测待完成 |
| P4 TUN 与恢复 | 进行中 | 私有会话、独立核心 job 和检查日志 v2 已串联，检查意图/退出持久化、13 个强退/故障场景与新宿主恢复通过；正常代理会话、DNS 事务、真实网络故障恢复与 TUN 尚未接入，未修改系统 DNS/路由 |
| P5 功能完整与原生体验 | 进行中 | 已接入代理规则、核心/规则数据准备、WARP 凭据、连接配置检查和共用顶部栏，界面实测待解锁；订阅、节点与真实网络状态未接入，连接按钮禁用 |
| P6 DMG 与升级 | 进行中 | 已验证隔离应用的更新与错误签名拒绝；产品更新助手、DMG、正式 appcast 和服务升级事务待完成 |
| P7 回归与交付 | 进行中 | 当前 Mac Go 回归已通过；Windows 运行测试、macOS 13、Intel 及实际校园网络待验收 |

## 2026-11-04：首批 P0 验证

- 已创建并切换到 `mac` 分支，原计划随分支保留。
- 当前环境：Apple Silicon、macOS 27.0.1、Xcode 27.2（27B52）、Swift 6.4.2；原生部署目标设置为 macOS 13。这只证明当前系统的构建运行，不证明 macOS 13 实测通过。
- 从 Go 官方版本清单取得并校验 Go 1.25.14，解压至 `/private/tmp/freev6-toolchains/go`，未安装到全局目录。SHA256：`5b26c0b6f308240fca2614fb02f622cfcc8c0cc3b69c78bba4845489a4590259`；依赖与构建缓存位于 `/private/tmp/freev6-go-cache`。
- `bash scripts/macos/swift.sh build` 与 `test` 通过；5 项 XCTest 覆盖握手身份关联、版本拒绝、消息大小/字段校验、DNS 快照缺省与显式配置的区别。
- `bash scripts/macos/build-app.sh` 生成并校验 `dist/macos/FreeV6.app` 的 ad-hoc 签名。
- 实际打开原生 App，检查原生窗口/工具栏与侧栏；⌘2 切换节点页、⌘, 打开设置、⌘W 关闭设置及隐藏主窗口、⌘1 恢复主窗口并回到概览均通过。完整文件菜单、状态栏所有操作、退出后的网络清理尚未验收。
- 系统探针成功读取当前签名身份；DNS 探针只读捕获 5 个网络服务，不在日志输出具体解析器地址。
- 正常用户环境中，允许的 CDHash 完成匿名 XPC 握手，错误 CDHash 被拒绝。沙箱中可信连接也会失败，不能把该环境下的拒绝当作身份校验成功证据。
- Keychain 探针在独立随机测试项上完成创建、读取和删除。尚未验证 ad-hoc 版本变化后的重新授权。
- 上游 v1.19.31 的 Darwin arm64 压缩包通过固定 SHA256 校验；`file` 确认为 arm64 Mach-O，`-v` 输出 v1.19.31 / darwin arm64 / go1.26.8。Intel 资产摘要也已从上游 release 记录，但未做 Intel 真机验证。
- 共用配置增加显式 Darwin 目标：动态 utun、loopback DNS，保留 Windows 默认输出；新增 JSON 序列化和业务等价性测试。
- `cmd/macos-probe` 生成合成凭据的完整/离线配置；真实核心 `-t` 对离线 JSON/MASQUE 配置检查成功。该样本移除了远端规则/GeoSite 依赖，尚不能证明完整业务、DNS 劫持、TUN 或真实 WARP 连接可用。
- Go 基线曾有 3 项非 Windows 假设失败：2 项发现测试写死 Windows 文件名，1 项测试错误假定所有系统能恢复 Windows 快照。现已加入按目标平台命名和对应测试；非 Windows 保留无法恢复的原快照，没有伪造恢复成功。修改后 `go test ./...` 全部通过。

- Windows amd64 的全部 Go 测试程序交叉编译成功，产物确认为 PE32+ x86-64；这些程序尚未在 Windows 上执行，不能据此声明 Windows 运行回归完成。
- 使用 `otool -l` 检查原生 App 的实际 Mach-O，最低系统标记为 13.0；新的可重复核心探针脚本也完成了摘要校验和离线配置检查。

## 2026-11-05：独立服务与真实更新验证

- 新增独立 Swift 网络服务目标，目前只开放有版本和请求关联的 XPC 握手。生产路径固定；Release 不接受探针参数，普通用户不能直接启动生产服务。
- 安装登记按 UID 绑定客户端 CDHash。登记文件读取采用逐级目录句柄、`openat`、`O_NOFOLLOW`、同一文件句柄的权限/大小检查与有界读取，拒绝可被其他用户写入的目录、符号链接、硬链接和 FIFO，避免路径替换与无界读取。
- Debug 构建和 12 项 XCTest 通过。Release 构建曾在受限环境被 `dsymutil` 权限阻止，在正常用户环境构建通过；Release 的探针参数拒绝与非 root 启动拒绝已实际执行验证。
- `probe-service.py` 使用启用 Hardened Runtime 的独立进程和临时用户级 launchd job。合法握手、错误客户端摘要拒绝、错误服务摘要拒绝、UID 绑定、服务重启、同 identifier 新摘要重新登记与旧摘要撤销全部通过，job 已移除。这里的登记更换只证明身份机制，不等同于管理员重新授权或 root 安装验收。
- Sparkle 2.9.6 官方 tar.xz 摘要为 `52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192`。直接在严格 Hardened Runtime 的 ad-hoc App 内加载框架被 dyld 拒绝，原因是 Team ID 不匹配；普通 ad-hoc 对照应用可以真实升级。
- 据此验证独立更新助手：主程序仅链接系统框架、启用 Hardened Runtime、无放宽权限；仅普通用户助手携带 `disable-library-validation` 并加载 Sparkle。真实更新完成下载、签名验证、安装、N→N+1 和不同 PID 的新版重启，外层 bundle 签名检查通过。
- 错误 Ed25519 签名被 Sparkle 拒绝，原安装版本保持为 1。测试解析结构化底层错误链，不能将任意安装/网络错误当作签名验证成功。
- 更新测试使用随机 bundle ID、临时签名密钥和回环 appcast。测试私钥、服务器、偏好和更新缓存已清理。Objective-C 宿主与自动应答 driver 仅是 P0 夹具；产品的 Swift 更新界面、授权交互和服务事务仍待接入。
- 计划已纳入独立更新助手，同时细化用户要求的原生顶部菜单、窗口工具栏、状态菜单及任务验收；不安排人数或人力工期。

本轮保留的直接证据：

| 验证 | 结果文件 |
| --- | --- |
| 用户级服务和身份轮换 | [service result](/Users/andy/Study/free-v6/build/service-probes/57acdab8-e5b5-45a0-b4af-e1f63c3e79db/result.json) |
| 严格签名主程序 + 独立助手升级 | [update result](/Users/andy/Study/free-v6/build/update-probes/67760da474da44af84f09cdde3148cb6/result.json) |
| 错误签名拒绝，旧版保留 | [rejection result](/Users/andy/Study/free-v6/build/update-probes/89197ae31a63421fbbf9a9d27dc2035f/result.json) |

这些文件是本地忽略的构建产物，可用 README 中的脚本重新生成。当前没有安装 root 服务、修改 DNS/路由或建立真实 TUN；没有通过 macOS 13、Intel、quarantine DMG 或生产网络服务升级验收。

## 2026-11-05：安装工具与应用接入

- 新增 Swift 安装工具，打包时将固定服务 SHA256 放入安装工具的签名覆盖范围。服务、安装工具和主 App 均启用 Hardened Runtime；特权客户端要求无 entitlement，更新助手不能进入登记名单。
- root 安装前复制到私有目录后验证。客户端 Info.plist 和执行代码的签名/CDHash 对应授权请求；服务另以嵌入摘要验证，避免把客户端资源或外部“期望哈希”当作 root 执行依据。恢复工具副本也验证签名身份。
- 安装事务实现固定路径、独占锁、原子文件替换、fsync、持久化备份与摘要、安装后双向 XPC 健康检查、失败回退和中断恢复。提交标记写入失败不再启动可能与磁盘状态冲突的第二轮修改；坏备份拒绝恢复且保留记录。
- 升级/重新登记替换当前用户及安装工具的旧摘要，保留其他用户登记。检测到网络会话恢复记录时拒绝覆盖；真正网络恢复接口留待 P4 接入。
- App 已接入真实服务检查、安装/重新登记、安装恢复和卸载入口，安装操作期间防止重复提交。当前仅开放身份握手，连接按钮保持禁用。
- UI 实测：当前缺少服务时显示“网络服务尚未安装”；从构建目录点击安装会提示先移动到“应用程序”，未发起系统安装；原生设置可打开，缺少服务时卸载按钮禁用。
- Release App 已完成内部到外层的签名与严格校验；真实签名 payload 的正常校验、错误摘要拒绝、放宽库校验的客户端拒绝和非 root 变更拒绝通过。安装器和 App 共用的 XPC 客户端也通过临时用户级服务的双向身份、重启与摘要轮换实验。
- 当前 27 项 XCTest 全部通过。最终签名产物验证记录为 [installer result](/Users/andy/Study/free-v6/build/installer-probes/6d721437-6353-425f-8273-f22ef9150644/result.json)；共用客户端的独立服务验证记录为 [service client result](/Users/andy/Study/free-v6/build/service-probes/6600b924-45d6-458f-9fa9-5bc0940ecde4/result.json)。
- 系统级 root 安装、管理员授权接受/取消、实际系统 launchd 的重启与卸载尚未验证。已请求用户确认这一新增后台权限，当前没有向 `/Applications` 或系统服务目录安装程序。

尚未完成：真实网络服务生命周期、完整卸载清理、跨版本服务协议协调、macOS 13/Intel 验收。安装事务模拟控制器通过不能替代实际系统授权与 launchd 验收。

## 2026-11-05：共享设置、Mac worker 与原生配置接入

- 将设置模型、默认值、规则校验和 Windows PUT 的字段保留语义提取到 `internal/app`。Windows HTTP 入口继续使用原有接口，登录启动等平台副作用留在 Windows 适配器；原有 Go 回归通过。
- 新增 `cmd/freev6-worker`、显式目录契约和版本化的私有 stdio 协议。握手、方法能力、请求关联、消息上限、并发上限、取消、超时及父进程断开均已实现。当前只声明 `settings.get` 和 `settings.patch`，没有 HTTP 监听或特权操作入口。
- Mac 配置使用独立 schema/revision、受限字段、0600 文件、同目录原子替换与 fsync。同一数据目录持有进程锁；版本冲突、损坏配置、未知字段、无效规则拒绝保存，避免覆盖旧数据。
- 新增 Swift `FreeV6Business` 客户端和原生代理规则表单，主窗口配置页与设置窗口共用编辑状态。模式、开发者模式、校园白名单与黑名单已接入实际 worker；保存确认来自 worker 回复，错误时保留草稿。尚未接入 WARP、订阅、下载、配置渲染或 TUN。
- 真实 Swift→Go 测试曾暴露高层管道读取等待过多字节的问题，改用有界的底层分块读取后，握手、保存、规范化、冲突/非法值拒绝和重启后读取全部通过。异常退出与无响应子进程的客户端回收也通过。
- 独立进程测试还发现继承的阻塞 stdin 会妨碍 Go 在 SIGTERM 后退出；现为私有管道注册可取消的 runtime poller。实际验证父进程 EOF、SIGTERM、输出管道堵塞、第二个 worker 拒绝以及超大/截断帧后均能回收进程。
- Go 全量回归通过；`internal/app`、`internal/paths`、`internal/worker` 的竞态检测通过。31 项 XCTest 全部通过，其中包含真实 Go 集成项，未跳过。Windows amd64 的测试程序交叉编译通过，尚未在 Windows 执行。
- Release bundle 已包含按当前主机架构构建并签名的 Go worker；完整签名和真实安装 payload 验证通过。实际 UI 验证被 macOS 锁屏阻止，已请求用户解锁，不能将编译和客户端测试当作界面操作验收。

本轮证据与复现入口：

| 验证 | 证据或命令 |
| --- | --- |
| 打包 worker 的真实进程验证 | [worker result](/Users/andy/Study/free-v6/build/worker-probes/4498bfbf-fab7-4cde-99b3-c6cf86484c45/result.json)；`python3 scripts/macos/probe-worker.py` |
| 普通用户签名 payload 验证 | [installer result](/Users/andy/Study/free-v6/build/installer-probes/327d3a19-e113-4fef-b9e6-92ef87c1ad42/result.json) |
| Go/Swift 与真实 worker 集成 | [test log](/Users/andy/Study/free-v6/build/macos-worker/test-worker.log)；`bash scripts/macos/test-worker.sh` |
| 协议与共享样本 | [worker v1](/Users/andy/Study/free-v6/shared/protocol/worker-v1.md)、[settings fixture](/Users/andy/Study/free-v6/shared/fixtures/worker-settings.json) |

当前仍未安装 root 服务、修改 DNS/路由或建立真实 TUN。P1、P2、P5 均未完成；代理配置页接入不等于全部业务迁移完成。原生顶部栏的完整命令与状态联动仍按 UI-01～UI-06 推进。

## 2026-11-05：平台核心准备与原生下载进度

- 核心资产改为编译时嵌入的固定清单，按 Windows amd64、Darwin arm64、Darwin amd64 选择。Windows 保留 v3，Intel Mac 使用 v1。三种官方压缩包均通过锁定摘要，再计算并记录二进制 SHA256；生产下载器校验两层摘要和 Mach-O/PE 架构。
- 修复按临时文件扩展名解压及固定 Windows 输出名的问题。下载和解压分别限制体积；ZIP 拒绝多余文件、符号链接与路径穿越；失败不覆盖旧核心，取消后清理临时文件。镜像保留停滞和总时限，生产重定向只允许 HTTPS。
- Mac worker 新增 `runtime.status`、`runtime.download` 和有请求标识、递增序号的进度通知。不接受任意 URL、路径或平台参数；只保留已验证的用户缓存安装包，不执行核心。之后 root 服务仍需独立验证并安装。
- 原生概览与设置新增下载、检查、进度、错误和取消操作，复用同一个 worker。界面显示“核心安装包已校验”，不将其描述为代理连接成功。取消后的最终缓存状态可以再次检查。
- 全量 Go 回归和 Windows amd64 测试程序交叉编译通过；核心竞态测试包含三种真实官方资产；新增 ZIP 拒绝案例另行通过。32 项 XCTest 全部通过，包含真实 Swift→Go 核心缓存与进度验证，无跳过。
- 独立 worker 使用正式镜像实际下载 20,701,178 字节的 Darwin arm64 核心包，收到检查、下载和校验阶段的 35 条进度通知；随后再次确认缓存可用，所有测试子进程退出。Release bundle 构建、签名和只读安装 payload 校验通过。

| 验证 | 证据 |
| --- | --- |
| 正式镜像下载与进度 | [download result](/Users/andy/Study/free-v6/build/worker-probes/5bb48f23-808e-4ad0-870c-1691319aeeb4/result.json) |
| 三种官方资产与竞态测试 | [asset tests](/Users/andy/Study/free-v6/build/macos-worker/runtime-assets-tests.log)、[ZIP tests](/Users/andy/Study/free-v6/build/macos-worker/runtime-zip-tests.log) |
| Swift 与真实 Go 集成 | [Swift tests](/Users/andy/Study/free-v6/build/macos-worker/runtime-swift-tests.log) |
| 全量 Go 与 Windows 交叉编译 | [Go tests](/Users/andy/Study/free-v6/build/macos-worker/runtime-go-full.log)、[Windows build](/Users/andy/Study/free-v6/build/macos-worker/runtime-windows-build.log) |
| Release 与签名 payload | [build log](/Users/andy/Study/free-v6/build/macos-worker/runtime-build-app.log)、[payload result](/Users/andy/Study/free-v6/build/installer-probes/54f7f705-5365-430a-adf8-bf8cd6173455/result.json) |

UI 操作仍待解锁验证；Intel 和 Windows 资产解析不代表真机运行验收。当前仍未安装 root 服务或执行实际 TUN/DNS 变更，P1、P2、P5 保持进行中。

## 2026-11-05：原生顶部栏共用命令与退出流程

- 新增 `FreeV6Desktop` 命令模型，应用菜单、窗口工具栏、状态菜单与配置表单共用可用性规则和执行入口。执行前重新核对状态，禁止重复的核心检查/下载或配置读写；尚未实现的连接、测速、导入、日志导出与更新保持禁用。
- 文件菜单接入保存配置和重新载入，页面工具栏按页面切换操作。通过 SwiftUI 的场景焦点值区分主窗口、设置页和帮助窗口，⌘S 只作用于当前代理规则编辑上下文，系统编辑命令不被应用拦截。
- 状态菜单接入真实服务检查状态、核心准备状态与已保存配置摘要，并提供页面跳转、核心准备、设置、帮助与退出。服务就绪不会被显示为“已连接”，已保存模式不会冒充实时网络模式。
- 主窗口关闭后继续隐藏，重新打开可恢复最小化窗口；保存上次页面，使用 AppKit 窗口自动保存。设置入口在 macOS 14+ 使用 `SettingsLink`，macOS 13 保留旧系统入口；新增本地使用说明窗口。
- 所有退出请求经应用代理统一处理：服务或配置操作期间暂缓；未保存草稿可保存、取消或放弃；核心下载取消后等待 worker 退出再允许 App 结束。保存失败保留窗口与草稿，不将失败当作保存成功。
- 37 项 XCTest 通过且无跳过：27 项系统测试、6 项业务客户端测试、4 项命令模型测试。新增子进程夹具在下载挂起时退出，确认客户端等待子进程处理 stdin EOF 后退出。Release App 构建及签名检查通过，无新增 entitlement。

证据：[Swift tests](/Users/andy/Study/free-v6/build/macos-worker/native-desktop-tests.log)、[Release build](/Users/andy/Study/free-v6/build/macos-worker/native-desktop-build.log)。

此轮未操作 GUI：先前锁屏阻碍尚待用户解锁。顶部菜单顺序、设置入口、焦点切换、工具栏溢出、确认框、窗口恢复、退出主线程流程、VoiceOver 和 macOS 13 仍需实机验证。命令模型和子进程测试只覆盖各自边界，UI-01 至 UI-06 不据此标为全部完成。退出流程尚不包含真实 TUN/DNS 清理。

## 2026-11-05：WARP 注册与用户钥匙串

- Go worker 增加 `warp.register`，共用既有 WARP 客户端，通过固定 API 执行注册与 MASQUE 密钥登记。请求仅接受设备名，单任务互斥、45 秒期限和两个阶段的进度；不接受服务地址、令牌或输出路径，不写 Mac `warp.json`。
- 注册结果采用 schema 1 的凭据契约。Go 与 Swift 对 P-256 SEC1/SPKI 编码、账户字段、地址、日期和大小进行校验，使用同一份公开合成样本验证互通。错误不包含私钥或上游响应正文；共用 HTTP 客户端拒绝重定向，响应限制 1 MiB，Windows 成功接口和凭据文件位置保留。
- 新增当前用户的 Keychain 适配及凭据工作流。系统操作在独立串行队列执行，不在启动时自动读取私钥；使用默认应用代码 ACL，无共享访问组或放宽 entitlement。条目通过随机 revision 执行条件替换和删除，旧版本操作拒绝。
- 注册前检查现有凭据与替换意图。保存失败保留原记录和内存中的新结果；重试只保存，不重新注册。正常退出遇到凭据操作或待保存结果会暂缓，明确保存或放弃后才能继续；强退仍可能丢失未保存结果。
- 概览与设置新增 WARP 页，接入检查、注册、重新注册、取消、删除本机凭据、重试保存和放弃待保存结果。界面只保存非敏感摘要，不显示私钥。删除本机记录、取消或放弃结果均不承诺撤销远端注册。
- 42 项 Swift 测试通过：27 项系统、10 项业务与 5 项桌面命令。真实临时独立 Keychain 的读取、条件替换、错误 revision 拒绝、删除和清理通过；未读取登录钥匙串。注册 HTTP 使用本地模拟服务，完整验证 POST 注册 → PATCH 登记、凭据契约及错误脱敏。
- Go 全量回归及 Windows amd64 交叉编译通过，相关包竞态检查通过；新的实际 Swift→Go 调用验证非法注册参数在联网前被拒绝。Release App 构建与签名通过，打包 worker 的 EOF、SIGTERM、背压与坏帧验证通过，测试子进程全部退出。

| 验证 | 证据 |
| --- | --- |
| Swift 全量及凭据工作流 | [Swift tests](/Users/andy/Study/free-v6/build/macos-worker/warp-swift-tests.log) |
| 独立 Keychain 与清理 | [Keychain tests](/Users/andy/Study/free-v6/build/macos-worker/warp-keychain-cleanup.log) |
| Go 模拟注册与竞态 | [race tests](/Users/andy/Study/free-v6/build/macos-worker/warp-go-tests.log)、[HTTP integration](/Users/andy/Study/free-v6/build/macos-worker/warp-http-race.log) |
| 真实 Swift→Go 参数拒绝 | [worker integration](/Users/andy/Study/free-v6/build/macos-worker/warp-worker-integration.log) |
| Go 全量与 Windows 交叉编译 | [Go tests](/Users/andy/Study/free-v6/build/macos-worker/warp-go-full.log)、[Windows build](/Users/andy/Study/free-v6/build/macos-worker/warp-windows-build.log) |
| Release 与打包 worker | [Release build](/Users/andy/Study/free-v6/build/macos-worker/warp-release-build.log)、[process result](/Users/andy/Study/free-v6/build/worker-probes/5b0b82c7-7f46-4910-abb1-1144329f0207/result.json) |

尚未验证真实 Cloudflare 注册、产品 App 的系统授权交互、ad-hoc 升级/回退后的 Keychain 访问、macOS 13 和 UI 操作。临时钥匙串测试使用已弃用的隔离创建/删除 API，不能代替产品的登录钥匙串及代码身份测试。后续接入实际连接时还需限制运行中凭据替换/删除，并验证凭据向受控配置流程的交接。未安装 root 服务，未启动真实 TUN。

## 2026-11-05：固定规则数据、原生准备入口与完整配置解析

- 新增固定数据清单，锁定 meta-rules-dat 提交 `fb6bd25ca61dd918d36b0f61b4bad67dfc278bcf`。实际下载三份文件并与该提交的官方 `.sha256sum` 一致：GeoSite 4,355,984 字节、GeoIP 16,546,071 字节、MMDB 7,650,367 字节。完整摘要保存在 `internal/mihomo/geodata-assets.json`。
- 新增 `geodata.status/prepare`，接口不接受路径、URL 或外部摘要。显式 bundle 资源目录只读；缓存按版本隔离，全部文件完成固定摘要校验后才返回可用。当前 Mac 构建首次准备下载数据，未新增随包数据二进制；保留同版本只读种子支持。
- 与核心下载共用有界传输，覆盖无进展期限、硬超时、大小限制、摘要校验及临时文件清理。单文件原子提交，部分失败保留已验证文件供重试。新增坏种子、坏缓存、镜像切换、部分恢复、截断、已知/未知长度超限、取消、停滞和缓存符号链接测试。
- 原生概览与设置“核心与数据”页共用准备、检查、取消和错误状态，状态菜单显示准备结果；退出取消准备并等待 worker 回收。Swift 客户端校验文件名、摘要格式、大小及整体可用状态的一致性，丢弃迟到进度。尚未进行本轮页面的实际点击验收。
- 正式 worker 通过生产镜像完成三份数据准备，收到 38 条进度通知，探针独立验证缓存大小及摘要；状态重读一致，所有测试子进程退出。Swift→真实 Go 使用官方只读种子完成准备、损坏缓存修复及重启读取。
- Darwin 配置固定相同数据版本的 geox-url，并关闭核心自动更新；Windows 输出保持原有语义。真实 arm64 mihomo v1.19.31 对完整生成配置执行 `-t` 成功，未移除规则提供者或 DNS nameserver-policy；实际加载 cn（110,177 条）、private（133 条）、geolocation-!cn（27,444 条）。该结果不验证提供者下载、WARP 联网、系统 DNS 接管或 TUN 流量。
- 44 项 XCTest 全部通过，无跳过；包含真实 worker、官方核心/规则数据及独立临时 Keychain 测试。Go 全量回归、资源及 worker 竞态测试通过；Windows 测试程序交叉编译通过，未在 Windows 执行。Release 应用完成构建及严格签名检查。
- 核对上游 LICENSE 后修正第三方说明中的 Apache-2.0-only 标注，记录上游 GPL v3 声明及多来源输入。Mac 数据随包分发与来源材料继续作为发布核对项；没有把规则数据或 mihomo 二进制提交到仓库。

本轮证据：

| 验证 | 记录 |
| --- | --- |
| 生产规则数据下载、独立摘要和进程回收 | [worker result](/Users/andy/Study/free-v6/build/worker-probes/3b4f67e8-694d-498a-8392-316a766650be/result.json) |
| 完整配置与真实 GeoSite 解析 | [core check](/Users/andy/Study/free-v6/build/macos-geodata/full-core-check.log) |
| Swift / Go / 私有 Keychain 集成 | [Swift tests](/Users/andy/Study/free-v6/build/macos-geodata/swift-tests.log) |
| Go 全量与资源故障竞态 | [Go tests](/Users/andy/Study/free-v6/build/macos-geodata/go-full.log)、[resource race](/Users/andy/Study/free-v6/build/macos-geodata/final-resource-race.log)、[worker race](/Users/andy/Study/free-v6/build/macos-geodata/go-tests.log) |
| Windows 编译与 Release 构建 | [Windows compile](/Users/andy/Study/free-v6/build/macos-geodata/windows-compile.log)、[Release build](/Users/andy/Study/free-v6/build/macos-geodata/release-build.log) |

仍未安装 root 服务或启动 TUN。下一步把 Keychain 凭据、设置 revision 和资源标识通过受控配置请求连接起来，随后由 root 服务独立验证配置与资源，不能把当前用户缓存已校验视为特权启动授权。

## 2026-11-05：WARP 配置交接与 Swift 结构校验

- 新增共享业务配置生成器及 `configuration.prepare`。请求只允许 WARP source、已保存设置 revision、凭据 revision 和四项隧道材料；未知字段、账户 token、任意路径、缺失资源及过期设置被拒绝。生成前后核对设置版本，单次准备串行化，结果不写普通配置文件。
- 继续复用 Go 渲染器、默认黑名单、白名单、模式及开发者模式语义。响应仅含模式、节点、分组、规则提供者、规则五类字段；不携带 TUN、DNS、controller、secret 等系统配置。注册身份和 token 不进入连接配置，敏感类型的常规调试描述已脱敏。
- 新增纯 Swift `FreeV6Configuration` 模块。校验未知字段、MASQUE 参数和密钥/IP、分组成员及循环、规则语法、固定提供者 URL 与受控相对路径；验证结果保留 Go 业务结构。当前只开放 WARP MASQUE 路径，链式/备用协议仍待扩展；root 服务尚未调用该模块。
- Keychain 交接复用 WARP 操作协调器，与注册/保存/删除共用忙碌状态，异步生成后再次检查凭据 revision。配置准备期间阻止界面保存其他设置或替换凭据；外部钥匙串条目替换会使当前结果失效。App 仅保留设置/凭据版本、模式和数量摘要，不把含私钥的文档放入 Published 状态。
- 概览、原生工具栏和“连接”菜单增加“检查连接配置”，共用前置条件与执行入口。缺少设置、凭据或资源时说明下一步；从菜单发起时展示概览。没有开启连接或新增后台 Keychain 读取。实际 UI 和用户钥匙串交互仍待解锁验证。
- 新增 Go/Swift 共用 `warp-business-configuration.json`，使用已公开的合成凭据，禁止用于联网。Go 校验业务等价性与无系统字段；Swift 拒绝插件、外部控制器、越界路径/来源、非法规则和循环分组。真实 Swift→Go 验证资源准备、配置生成、版本与资源绑定、过期请求拒绝和用户数据目录无凭据落盘。
- 49 项 XCTest 通过，无跳过；Go 共享业务/凭据/worker 竞态及全量回归通过，Windows 测试程序交叉编译通过。Release App 构建及严格签名检查通过，包内 worker 验证八项能力、配置参数拒绝、缺资源拒绝及进程回收。
- `macos-probe` 将同一业务配置生成器的结果与测试用系统字段组合；固定 arm64 核心对完整配置再次 `-t` 成功。该探针不是 root 服务实现，不能证明实际 TUN、DNS 恢复或规则提供者下载。

本轮证据：

| 验证 | 记录 |
| --- | --- |
| Go 业务、凭据与 worker 竞态 | [race tests](/Users/andy/Study/free-v6/build/macos-configuration/go-race.log) |
| Go 全量与 Windows 交叉编译 | [Go regression](/Users/andy/Study/free-v6/build/macos-configuration/go-full.log)、[Windows compile](/Users/andy/Study/free-v6/build/macos-configuration/windows-compile.log) |
| 49 项原生测试与真实 Swift→Go 配置交接 | [Swift tests](/Users/andy/Study/free-v6/build/macos-configuration/swift-final-tests.log) |
| 业务投影组成的完整核心配置 | [core check](/Users/andy/Study/free-v6/build/macos-configuration/full-core-check.log) |
| Release 构建与包内 worker | [Release](/Users/andy/Study/free-v6/build/macos-configuration/release-build.log)、[worker result](/Users/andy/Study/free-v6/build/worker-probes/fc9f10b4-c517-4067-b748-cfefe8032ab9/result.json) |

下一阶段需要在 root 服务中重新验证受限业务文档、可信资源 ID 和摘要，组装系统字段并管理核心进程。当前服务仍仅支持身份握手，未安装 root 服务、未启动真实 TUN；不将 App 侧结构检查当作特权启动授权。

## 2026-11-05：网络服务固定资源交接与独立复验

- 将核心和规则数据清单生成到 Swift 源码并编译进服务，构建脚本检查与 Go 清单同步。生产服务不读取用户提供的摘要清单，仅按固定资源 ID 选择当前架构核心及三份规则数据。
- XPC 协议升级至 v2，新增 `resourceStatus` 和 `installApprovedResource`，通过 `FileHandle` 传递资源。请求不接受路径、UID、URL、摘要或执行参数；身份仍绑定登记的 UID/CDHash，资源方法额外检查来源文件所有者与类型。
- 服务先复制内容到私有目录并核对摘要，再复读副本。核心用系统 zlib 有界解码单个 gzip，检查 CRC、尾部、解压上限、二进制摘要与 Mach-O 架构。文件验证、fsync 后原子发布，核心 0500、数据 0400；错误替换保留原文件。
- 存储目录逐层检查所有权、POSIX 权限、ACL 与链接；拒绝写入型 ACL，保留系统常见的 deny/read-only ACL。独占文件锁限制服务实例，互斥锁限制并发操作；重启只清理受控命名且通过元数据检查的中断暂存，不遍历或删除未知内容。
- 普通用户域的独立签名服务完成真实 FD 交接：四项资源安装、错误内容不覆盖旧文件、未知资源与未登记客户端拒绝、服务重启后重新校验与暂存清理均通过；临时 launchd job 已移除。此实验没有安装 root daemon。
- 57 项 XCTest 全部通过，无跳过，其中系统层 35 项。新增覆盖 gzip 截断/CRC/拼接成员/超限、错误 UID/架构、硬链接/符号链接、ACL、过期操作、源描述符偏移、实际官方资产、损坏修复与写入锁；其余真实 worker/独立 Keychain 回归保持通过。
- 使用服务复验后的 arm64 核心与三份数据，对既有完整合成配置执行真实 `-t` 成功。该配置仍由 Go 探针生成，不是服务端配置组装；结果不证明 WARP 联网、提供者下载、TUN 或系统 DNS 恢复。
- Release App、服务和安装工具构建及严格 ad-hoc 签名验证通过，嵌入新服务摘要的真实安装 payload 验证通过。三项原生产物的部署元数据均为 macOS 13.0，最低系统运行验收仍未完成。此次没有修改 Go/Windows 业务，不重复宣称 Windows 运行测试通过。

本轮证据：

| 验证 | 记录 |
| --- | --- |
| 57 项原生及 Swift/Go/Keychain 回归 | [Swift final tests](/Users/andy/Study/free-v6/build/macos-service-resources/swift-final-tests.log) |
| 系统层资源、ACL 与事务验证 | [System tests](/Users/andy/Study/free-v6/build/macos-service-resources/system-final-tests.log) |
| 跨进程资源传递、身份与重启清理 | [XPC result](/Users/andy/Study/free-v6/build/service-probes/5f29fba6-339a-48a7-b946-9f04cb608863/result.json) |
| 服务复验产物的实际核心配置检查 | [Core check](/Users/andy/Study/free-v6/build/macos-service-resources/core-check.log) |
| Release 构建及部署元数据 | [Build](/Users/andy/Study/free-v6/build/macos-service-resources/release-build.log)、[Bundle validation](/Users/andy/Study/free-v6/build/macos-service-resources/bundle-validation.json) |
| 新签名 payload 与非 root 拒绝 | [Installer result](/Users/andy/Study/free-v6/build/installer-probes/ecdf48d1-fca7-4aa3-8b2b-9ce4a8860c17/result.json) |

下一步接入 App 缓存到服务的资源交接、服务端业务文档复验与系统配置组装，随后实现核心进程和 DNS 事务。资源就绪不能作为启动授权；启动时仍须验证实际使用的受控文件。当前卸载保留私有资源目录，完整清理仍在卸载验收范围内。用户尚未批准的 root 安装和锁屏后的 UI 验证保持待执行。

## 2026-11-05：App 资源交接与服务配置复验

- “检查连接配置”在服务就绪时重新验证服务身份，按编译清单从固定缓存打开资源并通过 FD 交接，随后提交受限业务配置。服务资源已验证时可复用，不要求用户缓存仍存在。服务未就绪时明确显示仅完成本机检查。
- 协议升级至 v3，增加配置检查请求与摘要回复。服务独立验证资源、业务字段、版本与大小，在内存中添加 TUN/DNS/controller 等系统策略。当前检查方法不创建会话目录、不启动核心、不修改网络，也不返回或保存含私钥的配置。
- 整个异步流程保持 WARP 凭据互斥，并在末尾重新核对设置和 Keychain revision；App 仅保存摘要。菜单、工具栏和页面在检查期间阻止重复准备、配置保存、服务变更与退出，避免状态竞态。
- 真实用户域 XPC 探针调用与 App 相同的资源和配置客户端：缺资源拒绝、四项安装、系统字段注入拒绝、摘要关联、移除用户缓存后资源复用均通过。服务使用的同一配置组装器输出完整合成配置，固定核心 `-t` 通过；服务 RPC 本身尚不执行 `-t`。
- 独立普通用户核心探针验证 100 字节 Unix controller 路径、0700 父目录、`GET /version`、无 IPv4/IPv6 socket、SIGTERM 正常退出及进程回收。实测 socket 为 0666 且无需 Bearer；后续服务必须在启动前建立私有目录和受限 controller 适配器。
- 62 项 XCTest 全部通过，无跳过；包含 39 项系统层、7 项桌面命令、2 项配置契约及 14 项业务/实际 worker/独立 Keychain 测试。Release App 构建、严格签名和真实安装 payload 验证通过，非 root 安装仍被拒绝。
- 原生顶部栏计划补齐三处入口的实际交互验收清单；开发按任务依赖与证据推进，不安排人数或人力工期。

本轮证据：

| 验证 | 记录 |
| --- | --- |
| 62 项原生回归 | [Swift tests](/Users/andy/Study/free-v6/build/macos-service-configuration/swift-tests.log) |
| App 同路径的跨进程资源与配置交接 | [XPC result](/Users/andy/Study/free-v6/build/service-probes/204b0e37-38c3-4c18-bce6-a78085c8b033/result.json) |
| 服务组装配置的实际核心解析 | [Core check](/Users/andy/Study/free-v6/build/service-probes/204b0e37-38c3-4c18-bce6-a78085c8b033/core-check.log) |
| Unix controller 与进程退出 | [Controller result](/Users/andy/Study/free-v6/build/controller-probes/53cf632c-1d40-4168-8c39-e0312d9800ed/result.json) |
| Release 与签名载荷 | [Build](/Users/andy/Study/free-v6/build/macos-service-configuration/release-build.log)、[Installer result](/Users/andy/Study/free-v6/build/installer-probes/19a29276-4cf8-40e7-9d79-e9fe9c0c46a6/result.json) |

尚未安装 root 服务或修改网络；最新 UI 交互仍待解锁，最低系统和跨用户验证未完成。接下来实现受控会话目录、实际核心检查及进程管理，再接入 DNS 事务和失败恢复。

## 2026-11-05：受控子进程与回收

- 新增系统层 `OwnedChildProcess`，通过绝对路径与独立参数调用 `posix_spawn`，仅传 PATH/LANG/LC_ALL；标准输入输出定向到 `/dev/null`，其余继承文件描述符关闭，重置子进程信号屏蔽及默认处理，使用独立进程组。
- 专属观察者使用 `waitid(WNOWAIT)` 等待，再在与信号发送共用的锁内 `waitpid` 回收；只有观察者能释放 PID，避免停止与回收竞争。停止先 SIGTERM，超过宽限期才 SIGKILL；只有完成回收才报告超时已终止，回收失败保持错误，不接受调用者提供的 PID。
- 固定 `launchctl` 调用已换用新入口，普通用户只读系统 job 查询通过。当前类型管理服务本次启动创建的子进程，不覆盖服务重启后的历史 PID 识别、DNS 恢复或后代进程树清理；锁定核心的启动协调器仍待接入。
- 新增独立 C 测试夹具，不进入产品 bundle。8 项进程专项覆盖环境/描述符/工作目录/信号隔离、超出管道缓冲区的输出、正常退出、启动失败、SIGTERM、忽略 SIGTERM 后 SIGKILL、超时与析构回收、并发停止及其他子进程不受影响。
- 固定官方 arm64 核心通过新入口执行服务组装的完整合成配置 `-t`，正常退出并回收。测试没有开启实际 TUN，也没有向系统写 DNS；产品配置检查 RPC 仍只在内存中复验。
- 完整 70 项 XCTest 通过，无跳过（系统层 47 项、桌面 7 项、配置 2 项、业务 14 项）；Release 构建、严格签名与安装载荷探针通过。最低 macOS 13 的兼容分支和真实 root 操作仍待真机验收。

本轮证据：

| 验证 | 记录 |
| --- | --- |
| 70 项回归、受控实际核心与只读 launchd | [Swift tests](/Users/andy/Study/free-v6/build/macos-process/swift-tests.log) |
| Release 构建与严格签名 | [Build](/Users/andy/Study/free-v6/build/macos-process/release-build.log) |
| 更新后的真实安装载荷 | [Installer result](/Users/andy/Study/free-v6/build/installer-probes/0a03b0ed-5d49-4f6b-bbf4-899376952284/result.json) |

下一项为私有会话目录、可信资源副本与持久化恢复记录，将受控进程接入服务启动协调器；之后实现 DNS 写入/比较恢复，并执行已授权范围内的网络验证。

## 2026-11-05：私有会话准备与中断恢复

- 新增准备存储及资源层入口。服务生成 session UUID，先原子持久化 `network-session.json`，再创建 0700 会话目录、复制固定核心/三份规则数据、组装并保存 0600 配置。资源逐项复制时校验，发布前复读摘要和架构；配置摘要与设置/凭据版本绑定。
- 会话副本使用独立 inode；共享资源替换不影响已准备副本。再次交付工作目录前核对全部文件、资源权限/内容及配置摘要；非所属 UID 的读取和取消被拒绝。生产启动协调器尚未调用此入口，当前 XPC 配置检查仍只在内存中执行。
- 私有目录额外拒绝所有 allow ACL，防止只读/遍历 ACL 绕过 0700。恢复采用目录描述符、固定名称及 inode 核对；先验证全部条目，再删除已知普通文件并移除空目录，最后删除记录。未知文件、链接、子目录、未知格式与无记录孤立目录均保留并报错。
- 安装/升级/卸载和安装恢复与会话存储共用 `network.lock`；即使会话记录尚未写入，也不能并发更换服务。恢复记录存在时，安装恢复现在同样拒绝继续。健康握手不依赖网络锁，避免安装持锁时阻塞。
- 真实普通用户宿主分别在 `preparing` 与 `prepared` 阶段被 SIGKILL：活跃宿主拒绝第二进程获取锁，强退后记录保留，新进程可恢复且重复清理成功。Debug 探针使用公开合成凭据，不启动核心或改网络。
- 79 项 XCTest 全部通过，无跳过（系统层 56、桌面 7、配置 2、业务 14）。新增 8 项会话测试及 1 项安装互斥测试，覆盖实际官方资源、配置篡改/权限错误、未覆盖旧记录、缺资源、UID 隔离、ACL、路径上限与清理中断。
- Release 构建及严格签名通过。实际安装载荷的信任/拒绝路径保持通过；生产三个可执行程序未出现 Debug 会话探针符号。

本轮证据：

| 验证 | 记录 |
| --- | --- |
| 79 项完整回归 | [Swift tests](/Users/andy/Study/free-v6/build/macos-sessions/swift-tests.log) |
| 两个阶段的真实强退与新进程恢复 | [Crash recovery](/Users/andy/Study/free-v6/build/session-probes/01d4e1ea-7388-4056-8e15-edbaf69315c7/result.json) |
| Release 构建 | [Build](/Users/andy/Study/free-v6/build/macos-sessions/release-build.log) |
| 生产签名与 Debug 探针排除 | [Bundle validation](/Users/andy/Study/free-v6/build/macos-sessions/bundle-validation.json) |
| 真实安装载荷检查 | [Installer probe log](/Users/andy/Study/free-v6/build/macos-sessions/installer-probe.log) |

当前记录 v1 明确只允许无进程、无网络改动的准备阶段，不能用它清理运行中的核心或 DNS 状态。下一步扩展持久化启动意图与进程身份，再串联实际核心检查、启动和 DNS 事务。root 安装、跨用户真实访问、最低系统及 UI 操作仍待对应条件，不将普通用户测试视作这些验收通过。

## 2026-11-05：独立核心任务与控制宿主强退

- 否定了仅靠服务进程组清理核心的假设：普通用户 launchd 宿主被 SIGKILL 后，忽略 SIGTERM 的子进程仍然存活，移除宿主 job 也不能据此证明核心已回收。保留对照证据和可重复探针，测试夹具已清理；生产设计改为由 launchd 直接管理核心本身。
- 新增 `ManagedCoreJob`，任务标签仅从服务生成的 UUID 派生，生产域固定为 system；普通用户不能直接调用生产管理入口。注册使用 `RunAtLoad=false` / `KeepAlive=false`，不会提前运行核心；启动、停止、确认退出和移除明确分开，运行中不能直接移除任务。
- 停止始终按 job 标识发送 SIGTERM，超时升级 SIGKILL，确认 launchd 已回收后才允许移除。未知状态或查询失败报错，不向历史 PID 发信号。使用手册定义的 `launchctl list` 列，拒绝未知/截断输出；不依赖 `print` 的诊断结构或已弃用的 SMJobCopyDictionary 字典。
- 核心通过固定 `/usr/bin/env -i` 原位执行，环境仅 PATH/LANG/LC_ALL，输入输出 `/dev/null`，保留同一受管 PID。短时命令由现有受控子进程执行；新增并发读取、容量/时间受限的 stdout 捕获，覆盖管道填满、超量、超时及 stderr 隔离。
- 普通用户真实 job 验证覆盖：控制宿主被 SIGKILL、新控制进程查询和停止同一任务、正常 SIGTERM、忽略 SIGTERM 后 SIGKILL、退出码 37、重复确认退出、拒绝删除运行中任务、无关哨兵不受影响。固定官方核心和全部 Geo 数据通过同一 job 路径执行公开合成配置 `-t`，退出码 0；全部临时任务已移除。
- 完整 83 项 XCTest 通过，无跳过（系统 60、桌面 7、配置 2、业务 14）。沙箱曾禁止读取系统启动 UUID，正常用户环境复验通过；未将环境拒绝当作产品成功。Release 构建与严格签名通过，产品可执行程序没有 Debug 会话或核心任务探针符号。

本轮证据：

| 验证 | 记录 |
| --- | --- |
| 83 项原生回归 | [Swift tests](/Users/andy/Study/free-v6/build/macos-preflight/swift-tests.log) |
| 进程组清理不足及夹具清理 | [Group contrast](/Users/andy/Study/free-v6/build/group-probes/e885752c-55c5-470d-964d-563a99498f17/result.json) |
| 独立核心任务、强退接管与真实核心 -t | [Core jobs](/Users/andy/Study/free-v6/build/core-job-probes/3ddcbeea-774f-4679-b4d6-5def5147b543/result.json) |
| Release 构建及签名 | [Build](/Users/andy/Study/free-v6/build/macos-preflight/release-build.log)、[Bundle validation](/Users/andy/Study/free-v6/build/macos-preflight/bundle-validation.json) |
| 真实安装载荷验证 | [Installer probe](/Users/andy/Study/free-v6/build/macos-preflight/installer-probe.log) |

当前生产 RPC 仍仅在内存中检查配置，准备记录 v1 仍禁止进程及网络副作用。本轮完成的是后续启动协调器所需的任务管理模块，尚未将注册/启动意图、退出确认与持久化记录连接；不能用普通用户 job 实验宣称 root 服务、DNS 恢复或真实 TUN 已通过。下一步升级会话记录，先串联真实 `-t` 与崩溃恢复，再接入运行会话和 DNS 事务。

## 2026-11-05：服务真实核心检查与持久化恢复

- 将私有会话准备、固定资源复验、独立核心 job 和磁盘日志串联到产品 `checkConfiguration`。协议升级为 XPC v4，仅在固定核心 `-t` 返回 0 且任务/私有文件/日志均清理后返回 `coreValidated: true`；App 拒绝旧版、缺少标记、未通过或请求/revision 不匹配的回复，显示“配置已通过核心检查”。
- 新增检查记录 v2，仍保留 v1 的无进程准备语义。注册、启动、PID 确认、退出、移除分别持久化，所有副作用先记录意图；任务标签由服务 UUID 派生，历史 PID 仅作诊断。普通准备取消/恢复明确拒绝 v2，避免绕过任务回收。
- 服务启动与新检查前恢复旧日志。先确认服务归属和旧宿主组已退出，再按任务标识协调；不以任务意外丢失推断核心已停止。记录确认退出后才移除 job，最后清理固定文件及 cache.db。未知文件、字段或状态均保留；恢复失败仍提供身份握手及明确错误。
- 实际普通用户 launchd 宿主在九个记录/副作用边界被 SIGKILL，包括核心已经启动但 PID 未持久化、job 已删除而日志未更新。新宿主均恢复成功，重复恢复保持幂等；活跃宿主期间第二进程获取网络锁被拒绝。
- 额外覆盖任务意外丢失和未知文件：前者保留原日志及配置，后者在任务安全移除后保留文件与 removed 记录；消除测试异常文件后可继续恢复。Debug 非 root 故障注入验证核心非零退出与超时均停止任务、删除私有配置并返回失败，共 13 个场景。
- 独立 XPC 服务与原生客户端完成实际核心检查、资源复用、临时会话清理、系统字段注入拒绝、UID/双向签名与重启/身份轮换验证。服务数据使用短路径，完成后移动到证据目录的 service-data；测试仅使用公开合成凭据和 `-t`。
- 完整 87 项 XCTest 通过，无跳过（系统 64、桌面 7、配置 2、业务 14）。Release 构建、严格签名、非 root/探针参数拒绝及安装载荷验证通过；产品二进制不含 Debug 崩溃点和故障注入入口。

本轮证据：

| 验证 | 记录 |
| --- | --- |
| 87 项完整原生回归 | [Swift tests](/Users/andy/Study/free-v6/build/macos-preflight/v4-swift-tests.log) |
| 13 个检查恢复与失败场景 | [Recovery](/Users/andy/Study/free-v6/build/check-recovery-probes/31ba49cc-69e5-4c41-9272-06571ef51fad/result.json) |
| 真实 XPC v4 核心检查与身份验证 | [Service](/Users/andy/Study/free-v6/build/service-probes/8a149b4d-537f-4e20-9a73-0b048c306a1e/result.json) |
| Release 构建与正式入口限制 | [Build](/Users/andy/Study/free-v6/build/macos-preflight/v4-release-build.log)、[Bundle](/Users/andy/Study/free-v6/build/macos-preflight/v4-bundle-validation.json) |
| 真实签名安装载荷 | [Installer](/Users/andy/Study/free-v6/build/macos-preflight/v4-installer-probe.log) |

本轮完成真实配置检查及其恢复，没有开启代理、安装 root 服务或改动 DNS/路由。跨系统重启分支、最低系统、跨用户隔离与最新 UI 尚待相应实测；当前服务自身留下的未确认任务记录仍要求新的服务实例确认旧组退出。下一步进入受限 controller 接口、正常网络会话与 DNS 事务，继续保留同样的持久化和恢复边界。

## 下一步

1. 用户确认后验证 root Mach service 的安装、双向身份、授权取消、重启、修复和卸载；确认前继续不依赖该权限的开发。
2. 在已串联的配置检查、持久化意图和 job 恢复基础上，实现受限 Unix controller 接口、正常运行会话和 DNS 快照/写入/比较恢复事务，随后执行真实 TUN/IPv6/解析器验证；不能把检查记录 v2 当作运行会话日志。
3. 验证 Keychain 在升级/回退后的访问行为；明确 macOS 13 与 Intel 的测试设备路径。
4. 按已经验证的机制接入产品 Swift 更新助手，并补齐 quarantine 分发与网络服务升级事务。
5. 在现有 WARP 配置交接基础上提取订阅、链式及备用配置，逐协议扩展受限节点契约并验证真实核心解析；完善共用顶部栏与其余页面。解锁后验证配置生成、核心、规则数据和 WARP 面板及实际钥匙串授权；外部设备验收未完成的项目保持未验证，不阻止无依赖工作。

## 可重复验证入口

构建和探针说明见 [macos/README.md](/Users/andy/Study/free-v6/macos/README.md)。Go 测试在受限执行环境中需要允许本机回环服务器；网络依赖下载与真实网络行为分别记录，不能用沙箱失败代替产品失败。
