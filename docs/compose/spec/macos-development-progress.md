# macOS 开发进度

目标：按照 macOS 支持计划完成原生客户端、共用业务、网络服务、DMG、应用更新及验收。开发分支为 `mac`，起点 c528f26。当前整体目标尚未完成。

## 阶段状态

| 阶段 | 状态 | 当前证据与剩余工作 |
| --- | --- | --- |
| P0 技术验证 | 进行中 | 原生构建、独立用户级 XPC、只读 DNS、Darwin 完整配置、隔离升级/拒签已验证。临时钥匙串已验证升级拒读、拒绝覆盖及精确回退。Safari 下载镜像的 App 副本保留隔离标记，系统拒绝默认运行。root 安装/恢复、实际联网、钥匙串前台授权和最低系统仍待验收 |
| P1 共用业务与协议 | 进行中 | WARP、链式与校园备用配置均已接入。两端共用公告解析与校园获取逻辑；六类节点通过 Mac 服务和固定核心检查。真实 WARP 注册、校园出口和 root 启动仍待实测 |
| P2 原生应用骨架 | 进行中 | 已有导航、共用顶部栏命令、窗口焦点、服务与核心准备入口、真实配置客户端；正式 Xcode targets、完整菜单能力与页面交互验收待完成 |
| P3 原生网络服务 | 进行中 | 已有双向身份握手、App 资源 FD 交接/独立复验/受控存储、XPC v4 实际核心检查和清理确认、签名 payload 校验、安装/卸载事务与回退；v5 已接入本人会话启停、续期与恢复查询。root 安装和真实跨登录用户隔离待实测 |
| P4 TUN 与恢复 | 进行中 | 私有会话、独立核心 job 和检查日志 v2 已串联；13 个检查恢复场景通过；新增受限 Unix 控制客户端，模式/节点回读和流量采样在隔离核心上通过；DNS 准备、写入、恢复与强退重试已在隔离配置库验证，固定核心 TCP/UDP 探测通过。运行记录 v3 已串联启停和重启恢复。本机两跳测试已验证规则及全局模式的 TCP 出口、首跳故障和 UDP 拒绝。系统 DNS、真实 TUN 和完整连接界面仍待验收 |
| P5 功能完整与原生体验 | 进行中 | 已接入规则、凭据、校园检测、公告、备用配置、日志与三个顶部入口。首次协议、通用设置、日志工具栏和系统保存面板已在真机验证。临时 Aqua 登录任务及自动连接 XPC 路径已验证。实际注销登录、右上角操作与真实系统接管继续验收 |
| P6 DMG 与升级 | 进行中 | Apple Silicon 开发 DMG 已嵌入 Swift 更新助手。隔离升级、坏签名、错架构、取消及主程序失联已验证。已验证真实下载与只读安装窗口。正式通道、真实服务升级、干净账号上用户手动放行后的首次打开仍待验收 |
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

## 2026-11-05：执行计划与原生上方栏修订

- 明确后续由 Codex 按任务依赖负责实现、验证和修复，计划不安排人数、岗位、人天或固定周数。
- 补齐概览、节点、配置、日志四个页面的原生顶部布局和收窄优先级；与屏幕应用菜单、右上角状态菜单共用命令和连接状态。
- 将 UI-01～UI-06 改为“当前代码起点 → 剩余交付与完成条件”，明确模式、节点、速率和网络恢复依赖真实服务能力；已有菜单骨架不视为完整验收。
- 本次仅修订计划与记录，未改变应用代码、网络状态或阶段验收结果。

## 2026-11-05：原生受限核心控制接口

- 新增服务内部 `CoreController`，支持固定版本就绪检查、规则/全局/直连模式、节点摘要、受限分组切换、固定目标测速、累计流量及流量单次采样。模式和节点写入后重新读取确认；未确认结果不会被解释为未执行。
- 传输只连接私有会话目录的 `c.sock`，复验路径与目录 inode、拒绝链接与非 socket，并通过 UID 和 `LOCAL_PEERPID` 核对当前核心；生产 PID 来自实时 launchd job 查询。每次请求独立关闭描述符，不新增 TCP 控制端口。
- 固定 HTTP/1.0 与关闭连接的格式，限制响应头 16 KiB、普通正文 1 MiB、流量单行 4096 字节；拒绝歧义、截断、压缩或分块响应。错误不返回原始正文，流量与节点只暴露限定字段。
- 11 项新增测试覆盖实际 Unix socket 的身份、目录替换/权限、协议边界、超时、写后回读、非法成员、固定测速目标和不等待 EOF 的流量采样。完整原生回归共 98 项，无失败、无跳过。
- 固定 v1.19.31 真实核心验证三种模式、两个含中文/特殊字符的分组选择与回读、错误 PID 和非法成员拒绝、REJECT 测速不可用、累计流量及单次流量采样。100 字节 socket 路径、无 IP socket、正常退出和回收均通过。
- Release 构建及各组件严格签名校验通过，正式服务无 Debug 控制探针符号。开发说明和 [内部接口契约](/Users/andy/Study/free-v6/shared/protocol/core-controller-v1.md) 已同步。

| 验证项 | 证据 |
| --- | --- |
| 98 项完整原生回归 | [Swift tests](/Users/andy/Study/free-v6/build/macos-preflight/controller-full-tests.log) |
| 原生客户端与固定核心 | [Controller result](/Users/andy/Study/free-v6/build/controller-probes/3fd2a56d-7366-44be-ae2d-7147c9f24bb6/result.json) |
| Release 构建与签名/入口隔离 | [Build](/Users/andy/Study/free-v6/build/macos-preflight/controller-release-build.log)、[Bundle](/Users/andy/Study/free-v6/build/macos-preflight/controller-bundle-validation.json) |
| 更新后的安装载荷 | [Installer](/Users/andy/Study/free-v6/build/installer-probes/cd1d13a4-3224-477d-b042-b4b7ec43ef49/result.json) |

本轮未安装 root 服务或修改 TUN、DNS、路由。当前仅完成服务内部控制模块，尚未从 XPC 暴露运行会话和控制操作；界面真实连接仍保持未接入。跨用户、最低系统、真实流量、连续订阅和日志读取尚待后续验证。

## 2026-11-05 · DNS 接管与恢复事务

- 网络服务在私有会话目录持久化 DNS 基线，核对网络位置、物理主服务与核心监听。系统策略 v2 增加本次会话专属的本地测试域，通过默认与接口范围的系统解析查询后才确认生效。
- 恢复区分 DHCP、显式空字典和人工 DNS。用户仅修改搜索域时保留搜索域，替换解析器时保留其新设置。恢复遇到系统发布失败会保留记录，供进程重启后继续。
- 12 项 DNS 测试通过，包括写入及撤回提交后强杀测试宿主，以及固定核心在 TCP、UDP 上回答真实查询。完整回归共 110 项，全部通过。[测试日志](../../../build/macos-dns/full-tests.log)
- 普通用户环境只读检查 5 个配置服务、1 个候选物理主服务。实际 XPC v4 服务使用固定核心通过配置检查和任务清理。配置写锁、提交与激活使用隔离夹具验证，系统级 DNS/TUN、macOS 13 和真实校园网络的验收仍待执行。[只读检查](../../../build/macos-dns/system-preview.log) · [XPC 检查](../../../build/macos-dns/service-check.log)

## 2026-11-05 · Apple Silicon 开发版安装镜像

- 已生成 `dist/macos/FreeV6_0.5.2-preview_arm64.dmg`，内含签名后的应用、Applications 拖放入口及中文说明。应用包携带原项目协议、隐私说明与随包组件许可证。
- 在当前 Mac 上校验镜像、只读挂载、拖放复制到临时目录、复验代码签名与系统服务摘要，随后推出。四个可执行文件均为 arm64，部署目标不高于 macOS 13。另行运行安装载荷探针，可信副本通过，错误摘要与错误权限载荷按预期被拒绝。[构建日志](../../../build/macos-dns/dmg-build.log) · [安装载荷验证](../../../build/macos-dns/installer.log)
- 此产物可用于体验界面和准备功能。真实连接、从浏览器下载后的首次打开、安装系统服务及 App 自动更新留待各自的产品验收。

## 2026-11-05 · 原生菜单栏图标显示偏好

- “设置 → 通用”已接入原生 `MenuBarExtra.isInserted`。图标默认开启，显示开关使用同一份 AppStorage 偏好，Dock 应用和主窗口继续由原生窗口场景管理。
- 含该开关的 arm64 开发镜像已重新构建、只读挂载、复制与验签。7 项桌面命令测试通过，安装载荷探针通过。本机锁屏，实际点击开关、隐藏后由 Dock 重开、重启后的显示恢复及 VoiceOver 仍待验收。[镜像构建](../../../build/macos-dns/dmg-menu-build.log) · [桌面命令](../../../build/macos-dns/menu-tests.log) · [签名载荷](../../../build/macos-dns/menu-installer.log)

## 2026-11-05 · 正常运行会话与中断恢复

- 新增[运行记录 v3](../../../shared/protocol/network-run-v3.md)。同一网络锁覆盖私有配置、DNS、常驻核心 job、断开及清理。停止先记录恢复意图，恢复 DNS 后才停止核心。服务重启会先处理旧会话。客户端 UID、会话 UUID 与修订号共同限制停止操作。
- 实现核心所属 utun 的内核控制套接字检查、接口释放检查和固定 HTTPS 204 对端路由检查。普通用户测试使用模拟的 utun 与出口，真实系统接管仍需管理员环境实测。
- 23 个实际 launchd 场景通过，包括普通启停、出口失败回滚、DNS 正在恢复时进程被杀、恢复失败仍保留运行核心、核心单独崩溃、任务丢失、规则缓存和外来 socket。使用固定核心、真实 Unix controller 和回环 TCP/UDP DNS，所有系统 DNS 修改都替换为独立配置文件。[运行验证](../../../build/macos-run/interruptions.log)
- 旧配置检查的 13 个恢复及失败场景和 113 项原生测试通过。[旧记录回归](../../../build/macos-run/legacy-check.log) · [原生测试](../../../build/macos-run/full-tests.log)

## 2026-11-05 · 三处原生入口接入运行会话

- 应用菜单、窗口工具栏与右上角状态菜单共享服务端确认的状态。启动使用一次性空闲令牌，断开使用本人会话标识与修订号。关闭窗口后继续续期。⌘Q 由应用委托统一处理，确认网络恢复后再退出。服务失联或恢复失败时保留重试入口。[服务协议 v5](../../../shared/protocol/service-v5.md)
- 16 个签名 XPC 场景通过，包括桌面命令模型启停和退出、旧请求、重登记、核心崩溃、服务重启与租期超时。测试使用用户级临时服务、真实固定核心、回环 DNS 和模拟隧道。[桌面与服务验证](../../../build/macos-run/campus-desktop-xpc.log)
- 普通连接先限时检查公网 IPv6，与 Windows 使用相同回显服务和两个校园前缀。开发者模式经确认并保存后跳过检测。测试用本地响应覆盖端点、体积上限、网段匹配、无效响应和跳过查询。此次未向回显站点发送实机请求。
- 回归时曾遇到核心控制端就绪而 DNS 监听检查失败。实现现在限时等待同一核心的 TCP 与 UDP 应答，探针分配端口时也检查两个传输协议。修复后 23 个运行恢复场景通过，13 个旧检查恢复场景通过。[运行恢复](../../../build/macos-run/campus-run-recovery.log) · [旧记录恢复](../../../build/macos-run/v5-legacy-recovery.log)
- 完整原生回归共 124 项通过。arm64 开发镜像的复制、验签和安装载荷复验分别留存日志。测试机处于锁屏，本轮未点击真实菜单，未安装系统服务或修改系统 DNS。生产网络、macOS 13、Intel、发布更新和 Windows 回归仍待验收。[原生测试](../../../build/macos-run/release-candidate-tests.log) · [镜像](../../../build/macos-run/release-candidate-dmg.log) · [签名载荷](../../../build/macos-run/release-candidate-installer.log)

## 解锁后的原生顶部栏验收

在 Apple Silicon、macOS 27.0.1 上使用当前用户，从本地签名构建打开 FreeV6。测试时网络服务尚未安装。

| 操作 | 观察结果 |
| --- | --- |
| 打开顶部“连接”菜单，按 ⌘2，再打开“连接 → 切换节点 → 全部节点…” | 菜单和工具栏都显示需要设置网络服务。两个入口均能打开节点页，测速按钮给出连接前置条件。首测发现“设置网络服务…”重复，修复并重新构建后在菜单中实数为一项 |
| 从 FreeV6 菜单打开“设置…”并按 ⌘W | 系统打开“通用”设置窗口，菜单栏图标开关为开启。关闭设置后返回原主窗口 |
| 在主窗口按 ⌘W，从访达再次打开同一个 FreeV6.app | 收起后没有可见窗口，应用仍在运行。重新打开后恢复标识为 `freev6-main` 的主窗口 |
| 从屏幕右上角后台操作、从 Dock 图标重开 | 仍待直接点击验证。当前桌面自动化未能定位系统状态图标，获取 Dock 控件时超时。访达重开单独记录 |

开发构建也已接入模式、实际节点、首选接入点和速率。XPC 探针使用临时服务、固定核心和本地测试节点，覆盖切换、拒绝过期请求、读回结果和断开。流量按会话的累计字节分别去重后计入观测月份。异常退出可能遗漏最后一次采样以后的流量。链式组的控制使用合成配置，产品的订阅导入仍需开发。[服务验证](../../../build/macos-controls/selection-xpc.log) · [服务契约 v6](../../../shared/protocol/service-v6.md)

原生回归 128 项通过，Go 竞态检测回归通过，arm64 开发 DMG 已重新打包并完成挂载、复制和签名校验。本次没有安装系统级服务、注册真实 WARP 设备或更改系统 DNS。[原生回归](../../../build/macos-controls/unlocked-tests.log) · [Go 回归](../../../build/macos-controls/go-tests.log) · [镜像](../../../build/macos-controls/unlocked-dmg.log) · [安装载荷](../../../build/macos-controls/unlocked-installer.log)

## 原生链式代理与隔离转发验收

- 从“文件 → 导入链式代理配置…”可以选择 Clash/mihomo YAML。配置页支持手动导入和刷新 URL、查看节点、启用及清除。已在重新启动的 Release App 点击文件菜单打开系统选择器，再验证取消返回；订阅窗口使用安全文本栏，空地址禁用导入，取消后配置没有待保存改动。此次桌面操作没有写入个人订阅或访问登录钥匙串。
- 文件和订阅复用共享 Go 解析器。App 在提交前校验六类节点的受限字段，服务在接收配置时独立复验。URL 与节点参数加密保存。隔离测试覆盖失败刷新保留上次快照、版本冲突、钥匙串密钥不匹配、恢复普通 WARP，以及本机服务拒绝七种配置篡改。[worker 契约](../../../shared/protocol/worker-v1.md#链式文件与订阅)
- 固定 mihomo v1.19.31 对 28 个 WARP 接入点和 6 个导入节点的组装配置通过 `-t`。实际回环流量测试以本机代理替代 WARP 首跳，使用导入的 HTTP 节点作为第二跳。规则与全局模式均经过两个代理，首跳失败后目标未收到 TCP，不支持的 UDP 也未到达。显式直连模式下目标收到 TCP 和 UDP。其他五类节点的远端握手、WARP 实际出口仍待验证。[服务与转发结果](../../../build/macos-chain/xpc.log)
- 当前 Apple Silicon 设备上的 129 项原生测试、19 项普通用户 XPC/转发探针、Go 竞态回归和 4 项安装载荷检查通过。Windows amd64 helper、Intel Mac worker 均成功交叉构建。开发 DMG 的 SHA256 为 `b05d67286ba649ce471d4155bf2fedca62805a095c6a4ff05a30c8bf3ed94916`。[原生回归](../../../build/macos-chain/native.log) · [Go](../../../build/macos-chain/go.log) · [交叉构建](../../../build/macos-chain/architectures.log) · [DMG](../../../build/macos-chain/dmg.log) · [安装载荷](../../../build/macos-chain/installer.log)

## 测速期间断开与重连

测试代理在本机收到固定核心的测速 CONNECT 请求后保持等待。此时从另一条已认证的 XPC 连接发出断开请求，服务在本次实测中用 0.09 秒返回已停止，独立配置库已恢复 DNS。新会话成功启动，旧会话的请求被拒绝。该用时仅计服务接收断开到确认恢复，测试使用普通用户域和回环代理。[服务与恢复实测](../../../build/macos-chain/disconnect-xpc.log)

原生桌面测试另外控制两个回复的到达顺序。新连接先写入 12 ms 结果，旧连接的 900 ms 回复随后返回。界面保留新连接的 12 ms，旧批次也没有继续测量下一个节点。本轮 130 项原生测试与 20 个服务及转发场景全部通过。[桌面回归](../../../build/macos-chain/disconnect-tests.log)

## 校园备用配置与维护者公告

概览显示维护者公告。公告明确开放备用配置时，可以在配置页填写校园登录页、选择文件或输入自定义地址。获取成功后，下次连接直接使用校园节点，无需 WARP 凭据。“连接 → 刷新备用配置”仅对可刷新的已保存来源开放。切换前需停用当前链式或备用配置，两份快照可同时保留。

- 使用打包后的 worker 从项目公开源读取公告，并从独立测试目录重新读取缓存。2026-11-05 10:45（新加坡时间）返回 1 条公告，备用入口关闭。离线时最多使用七天内的有效缓存。另用合成公告验证开放、撤回、过期与无缓存状态；撤回后即使有旧快照也无法发起新的校园连接。[公开源与缓存实测](../../../build/worker-probes/731c7f07-059c-4832-85ab-0bdbdbdd87c8/result.json)
- 六类节点通过服务独立校验和固定 mihomo v1.19.31 的配置检查。服务拒绝了五种篡改，包括插入额外代理跳、改写出口和移除 UDP 保护。回环实测中，规则和全局模式的 TCP 仅经过一个受控校园代理；代理失效或遇到不支持的 UDP 时目标均未收到请求。直连对照组收到 TCP 和 UDP。另经普通用户 XPC 启停，不提供 WARP 凭据，服务按校园快照标识启动并恢复独立测试库中的 DNS。[23 项服务与转发验证](../../../build/macos-cloud/xpc-final.log)
- 131 项原生测试、Go 竞态回归、`go vet` 和 4 项安装载荷检查通过。Windows amd64 helper 与 Intel Mac worker 完成交叉构建。arm64 预览 DMG 通过只读挂载、复制和签名校验，SHA256 为 `0313127a4368abb0736bc7652bb2a3ad9cf8ba4a6e7195fbe4d07b733102ed67`。[原生测试](../../../build/macos-cloud/native-final.log) · [Go](../../../build/macos-cloud/go-final.log) · [架构](../../../build/macos-cloud/architectures.log) · [镜像](../../../build/macos-cloud/dmg.log) · [安装载荷](../../../build/macos-cloud/installer.log)

真实校园获取和出口需在维护者开放且处于相应网络时验收。当前测试使用独立目录和普通用户服务；真实系统 DNS/TUN、macOS 13 和 Intel 真机验收仍待执行。

## 原生日志与脱敏导出

日志页显示应用观察到的服务、业务组件和核心状态变化。“显示”菜单和原生工具栏共用级别筛选、暂停及继续显示操作。“文件”菜单可以导出当前日志或整份脱敏诊断，服务异常时概览也提供诊断入口。暂停期间仍收集有界事件。设置窗口取得焦点后禁用页面日志导出，应用级诊断导出仍可使用。

日志按来源保存最近 128 条，使用用户私有目录、0600 文件、文件锁和原子替换。持久化与导出接收预定义事件类型，时间与事件之外的原始异常、节点及凭据不会进入该数据类型。磁盘不可用时保留内存记录，界面提示保存状态。测试覆盖重启后读取、启动期间新事件、暂停与筛选快照、重复批次、分来源容量、恶意历史文件与菜单焦点。

135 项原生测试和 4 项安装载荷检查通过。当前 arm64 预览 DMG SHA256 为 `5cf75521103a7ae5fa1b9ee0eec9a795f4174557715b8f58925349b13eb81fab`。[测试](../../../build/macos-diagnostics/native-final.log) · [DMG](../../../build/macos-diagnostics/dmg.log) · [安装载荷](../../../build/macos-diagnostics/installer.log)

本轮再次尝试打开 Release App 时，桌面工具报告 Mac 已锁屏，已请求用户解锁。新公告/备用配置页面、日志工具栏及系统保存面板的实际点击验证待继续。原始核心日志的受限采集、长时间运行资源基线以及完整发布更新仍在后续验收范围内。

## Swift 应用更新与发布包

- FreeV6 应用菜单已接入“检查更新…”。已配置的构建使用宿主公钥和分架构 feed。普通用户 Swift 助手验证父进程与磁盘宿主的签名身份、签名清单、架构、构建范围、worker/服务协议和设置 schema。Sparkle 校验下载的 ZIP，再由主程序确认并准备安装。预览包会说明发行通道待配置。
- 主程序保存草稿、确认服务空闲与网络恢复，持久化升级意图后再同意安装。其他登录用户占用服务时拒绝继续。重启后，新版本将签名清单与实际安装的构建号、兼容信息、核心清单及服务二进制摘要比对；已有服务还须握手并匹配已安装的服务摘要。复验失败时暂停新连接，并提供修复提示。现阶段升级窗口接受 worker v1、服务 v6、设置 schema v1。跨协议迁移和真实 root 登记仍需独立验收。
- 首轮取消测试复现了“用户取消后仍安装”的问题。修正后 Sparkle 以助手作为安装生命周期的宿主，主程序在收到安装确认后退出。助手收到取消请求时等到撤销完成才结束。真实隔离测试覆盖 N→N+1 重启、坏 ZIP 签名、未签名清单、错误架构、取消下载、取消安装与主程序在许可前消失。后六种均保留旧版。[升级](../../../build/macos-updater/upgrade-final.log) · [拒签](../../../build/macos-updater/bad-archive-final.log) · [清单](../../../build/macos-updater/unsigned-feed-final.log) · [架构](../../../build/macos-updater/wrong-arch-final.log) · [取消下载](../../../build/macos-updater/cancel-download-final.log) · [取消安装](../../../build/macos-updater/cancel-final.log) · [主进程失联](../../../build/macos-updater/lost-host-final.log)
- 发布工具校验私钥与通道公钥匹配、签名载荷、架构、归档与 feed 签名。使用一次性密钥和预留测试域名打包成功，密钥不匹配时没有产生发行目录。实测使用普通用户临时应用和模拟的网络准备许可。[发布验证](../../../build/macos-updater/release-package.log) · [原生回归](../../../build/macos-updater/native-final.log) · [隔离服务回归](../../../build/macos-updater/xpc-final.log) · [安装镜像](../../../build/macos-updater/dmg.log) · [安装载荷](../../../build/macos-updater/installer.log)

当前 arm64 开发 DMG 的 SHA256 为 `131b2df22163e87a57d33d5e1f8b53a9170f9c80e7f7c4d21a7862fc98160a82`。142 项原生测试、23 项隔离 XPC/转发验证、4 项安装载荷检查通过。生产发布仓库与发布密钥仍待确定。公网 appcast、下载带 quarantine 的镜像、真实系统服务更新、安装授权取消、跨登录用户和 macOS 13/Intel 验收继续按原计划推进。

## 已有连接时安装更新

在普通用户域中启动真实 XPC 服务与固定核心，使用回环流量和独立的 DNS 配置库。签名测试宿主通过产品更新助手下载本地签名包；安装决定来自桌面端实际使用的 `disconnectBeforeUpdate`。记录的两个结果如下。

| 场景 | 安装结果与网络状态 |
| --- | --- |
| 下载时已有连接 | 收到“准备安装”后，桌面端请求断开并再次确认服务空闲。测试核对 DNS 已还原、核心任务已退出，才同意安装。旧版退出后，新进程从已替换的 v2 启动。[更新事件](../../../build/native-update-probes/69c7dacb-85e2-4025-8af3-4a5868a14fae/result.json) |
| 在断开时注入 DNS 恢复错误 | 服务保留恢复记录与运行中的核心，返回需要恢复。更新助手收到拒绝并结束，本地安装保持 v1。移除故障后，服务自动恢复 DNS 并清除核心任务。[拒绝安装](../../../build/native-update-probes/afb05414-6e67-4597-8c63-aeac6fe4017b/result.json) · [服务报告](../../../build/service-probes/385b6cd9-d8db-4c0e-9e35-4c0bc708e50f/result.json) |

主程序只有在收到更新助手的“正在安装”回执后才允许直接退出。回归测试覆盖同意安装后管道直接关闭、助手提前结束和正常确认三种情况。143 项原生测试、25 项隔离服务及转发场景、4 项安装载荷检查通过。最新版 arm64 预览 DMG 已只读挂载、复制并验签，SHA256 为 `e55c73f017e5b0a40a6138997a765e77786d52757cbd83e146b2b6d92a178664`。[原生回归](../../../build/macos-updater/connected-native-tests.log) · [DMG](../../../build/macos-updater/connected-dmg.log) · [安装载荷](../../../build/macos-updater/connected-installer.log)

用户已选择公开仓库 `study-233/free-v6`。发布工具按架构生成 `macos-updates` 分支的清单地址，按版本和构建号生成 GitHub Release ZIP 地址。使用一次性密钥本地打包并读取 ZIP 内的实际配置，核对清单中的链接，验证错误仓库地址和错误发布密钥会被拒绝。正式密钥、首个公开 Release、远程清单分支及公网更新留待发布验收。[发布包实测](../../../build/release-package-probes/993835bd-6e7d-4dc9-87f0-0f428f349b4b/result.json)

用户回复已解锁后，本次两次打开 Release App 的尝试仍收到桌面工具的锁屏提示。右上角菜单和新日志工具栏的点击保留待验；此前已通过的应用菜单与窗口测试见[顶部栏记录](#解锁后的原生顶部栏验收)。上述升级测试使用独立宿主及普通用户服务，真实系统 TUN、DNS 和管理员重新登记需分别验收。

## 首次打开、登录项与自动连接

- 最终 Release App 已在这台 Mac 上实际打开首次启动窗口。用户协议与隐私政策支持独立切换，辅助功能树显示分节标题。隐私页首节显示 Mac 钥匙串、数据与日志目录、系统服务、启动时的请求，以及上游项目和 Mac 发行仓库的区别。核对了同意之前“连接”菜单的安装、下载、检查配置和测速命令均禁用。接受状态绑定两份随包文档的内容。
- “设置 → 通用”分别保存登录启动、收起窗口与启动时自动连接。登录项写入固定用户级 LaunchAgent；设置读取 macOS 的实际授权状态。首轮实验发现 `open -g` 会向运行中的应用发送重开事件。改用签名原生助手后，临时 Aqua 任务两次运行均正常退出，观察 App 的整个生命周期只有一次启动和一次退出，没有重开事件。临时任务和登记文件已移除。[首次实验](../../../build/login-probes/0b106dbd-2961-48be-96ca-e0139c13fbcd/result.json) · [最终登录任务](../../../build/login-probes/cb3dfa86-8643-4f9a-865d-3f7e7f81d06a/result.json)
- 启动协调器每进程最多尝试一次，等待网络可用后再次验证服务、更新、凭据及配置。使用临时钥匙串证实，锁定条目时后台读取失败且原交互开关恢复。普通用户签名 XPC 探针在真实网络路径可用后尝试两次，固定核心只启动一个会话，退出后独立配置库的 DNS 恢复。[原生测试](../../../build/macos-startup/final-native.log) · [服务与转发](../../../build/service-probes/ebd1b03c-c915-4415-a298-3f49fe75f317/result.json)
- 147 项原生测试、26 项隔离服务及转发场景、4 项安装载荷验证通过。最终镜像已挂载、复制、核对两份随包文档并验签。arm64 开发 DMG SHA256 为 `1ebfc22edfaf42dd5c4826d643aad78124ddeaf12c18741524505bbe99331742`。签名升级包也已在本地重新生成并验证。[镜像](../../../build/macos-startup/final-dmg.log) · [安装载荷](../../../build/macos-startup/final-installer.log) · [升级包](../../../build/macos-startup/final-update-package.log)
- 在 Apple Silicon 上为 Intel 交叉构建了界面、登录助手、网络服务、安装工具、生产更新助手与 Go worker。五个 Swift 程序的 Mach-O 均标记为 `x86_64 / macOS 13.0`。Go worker 的最低版本为 12.0，已核对固定摘要的 Intel 核心最低为 10.13。此项验证了构建和二进制元数据。Intel 硬件和 macOS 13 的实际启动、更新、网络转发仍待运行验收。[二进制清单](../../../build/macos-startup/intel-binaries.json) · [Swift 构建](../../../build/macos-startup/intel-build.log) · [更新助手](../../../build/macos-startup/intel-updater.log)

本轮登录和网络探针使用临时目录、独立测试 App 及用户域任务。实际用户注销登录、系统设置中关闭登录项、macOS 13 静默启动与 Dock 恢复、真实校园网络及管理员服务仍待实机验收。

## 下载隔离、安装窗口与系统分发检查

- 在 Apple Silicon、macOS 27.0.1，通过 Safari 从只监听本机回环的 HTTP 服务下载开发 DMG。Safari 下载列表显示 10.9 MB。下载件与原镜像的 SHA256 均为 `1ca507f03733d3b131af501c13321c6ccf3ab7a399a4b44802e75967f677388c`。镜像的隔离属性含 Safari 标识；从只读卷复制到临时目录后，App 保留同一个隔离事件标识，深度签名校验通过。系统执行评估返回 `rejected`、退出码 3。[下载与系统策略](../../../build/distribution-probes/3463cac0-1a8e-4d83-97dc-20d3aebe786e/result.json)
- 首轮系统分发检查发现 Swift 更新助手存在指向构建机 Xcode 的 Sparkle 搜索路径。打包现在先移除开发环境路径，再依次签名内部程序、网络服务、安装工具和应用。拖放副本和升级包均验证路径。修复后的检查只报告 ad-hoc 签名与缺少公证票据，临时更新宿主完成 1 → 2 安装和重启。[修复前](../../../build/macos-delivery/local-policy.json) · [修复后](../../../build/macos-delivery/final-local-policy.json) · [升级](../../../build/native-update-probes/c1978fc7-318b-4b51-82e8-412aba04ea3f/result.json)
- 从本地构建的只读镜像实测打开“安装 FreeV6”窗口，显示拖入“应用程序”、推出镜像和重新打开的步骤，窗口只有“打开‘应用程序’”和“退出”两个按钮。这个入口先于业务模型初始化，避免已有用户的自动连接或静默启动影响安装。通过 ⌘Q 退出并推出临时卷。工作区的可写副本随后正常打开主界面。
- 当前账户接受记录与两份随包文档匹配，工作区副本重启后进入主窗口。⌘, 打开原生通用设置，显示菜单栏图标已开启，登录启动、收起窗口与自动连接均为关闭。⌘4 打开日志，工具栏的暂停和恢复反馈一致。点击导出后，macOS 保存面板写出与屏幕相符的 9 条事件。[导出结果](../../../build/macos-delivery/FreeV6-日志.txt)
- 148 项 Swift 测试全部通过。安装载荷、签名更新包和单应用升级验证通过。当前用户会话尝试定位系统控制中心超时，尚待直接点击右上角 FreeV6 菜单。干净账号在系统设置中手动放行后首次运行、macOS 13、Intel 以及真实管理员服务分别保留为实机验收项。[原生回归](../../../build/macos-delivery/native.log) · [安装载荷](../../../build/installer-probes/dab1e4c1-a70b-4679-8e8f-3fe0319bce33/result.json) · [更新包](../../../build/release-package-probes/3794726e-6cc4-4729-b8f0-8411df69f4d2/result.json) · [Apple 首次打开说明](https://support.apple.com/zh-cn/102445)

## 升级与回退时的钥匙串访问

- 在 Apple Silicon、macOS 27.0.1，原版测试 App 使用产品存储代码在独立临时钥匙串写入合成 WARP 凭据、链式代理和备用配置密钥。另一个不同签名标识的 App 后台读取三项全部被拒。Sparkle 在同一位置实际安装并重开版本 2，保留 bundle ID，代码签名摘要随版本改变。新版的三项后台读取都需要用户授权。注册前检查同样被拒，远端注册回调调用次数为零。[升级事件、签名与访问结果](../../../build/native-update-probes/c9694990-0e64-4304-8745-75a7fcf5cc3d/result.json)
- 将原签名、原内容的版本 1 放回同一路径后，产品读回三个原始修订号和数据。探针删除了临时钥匙串，并核对测试前后的用户钥匙串搜索列表一致。现场用户点击系统“允许”或“拒绝”的交互、登录钥匙串和 macOS 13 仍待独立实测。此测试覆盖同一账号下临时文件式钥匙串的访问行为。
- 配置页为已经保存的链式代理和备用配置分别提供只读检查。检查只读取对应旧密钥，不触发订阅、校园出口获取或新密钥生成。WARP 手动或启动检查会先清除过期的账户状态，拒绝读取后需重新检查才能注册或替换。安装确认及原生帮助已说明升级后可能出现的授权请求。
- 148 项原生测试通过；私有钥匙串测试覆盖空条目、成功读取保持内容和修订号、锁定时后台拒读。最新 arm64 开发 DMG SHA256 为 `20dfbc2d75e433642a4033eb3ba937cb1ee0efd21dc54c9c4af6a8ec17760e10`。已只读挂载、复制、验签，并重新验证安装载荷与签名更新包。[Swift 回归](../../../build/macos-keychain-upgrade/native.log) · [DMG](../../../build/macos-keychain-upgrade/dmg.log) · [安装载荷](../../../build/installer-probes/f26de631-fb49-4beb-a27e-620fb4f0467c/result.json) · [更新包](../../../build/release-package-probes/fc640ea7-fead-4b06-8635-33a33884d3f6/result.json)

## 下一步

1. 用户确认后验证 root Mach service 的安装、双向身份、授权取消、重启、修复和卸载；确认前继续不依赖该权限的开发。
2. 已在隔离网络与桌面状态模型验证测速期间可断开、旧回复不覆盖新结果。接下来在真实桌面验证右上角菜单、Dock 重开和失联时的反馈，随后在获授权的测试网络上执行已连接状态的完整交互。
3. 在专用测试账号验证升级后的钥匙串前台授权、取消和再次手动检查，并在 macOS 13、Intel 设备上分别验收。
4. 在干净账号验证下载 DMG 并由用户选择首次放行后的启动流程，在正式 App 上验证升级、重启后的服务重新登记与回退。对选定的 GitHub 通道完成发布密钥备份、公开资产校验与上一版 DMG 恢复演练。
5. 补充核心诊断事件和长时间运行资源基线。公告开放且具备测试校园网络时，验证实际获取、刷新和校园出口。真实 WARP、各出口协议、macOS 13 与 Intel 分别验收。

## 可重复验证入口

构建和探针说明见 [macos/README.md](/Users/andy/Study/free-v6/macos/README.md)。Go 测试在受限执行环境中需要允许本机回环服务器；网络依赖下载与真实网络行为分别记录，不能用沙箱失败代替产品失败。
