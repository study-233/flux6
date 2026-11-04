# macOS 开发进度

目标：按照 macOS 支持计划完成原生客户端、共用业务、网络服务、DMG、应用更新及验收。开发分支为 `mac`，起点 c528f26。当前整体目标尚未完成。

## 阶段状态

| 阶段 | 状态 | 当前证据与剩余工作 |
| --- | --- | --- |
| P0 技术验证 | 进行中 | 原生构建、当前系统 UI、独立用户级 XPC 服务、只读 DNS、Keychain 单次读写、Darwin 离线配置、隔离更新助手的真实升级/拒签已通过；root 安装/恢复、实际联网、quarantine 分发、凭据升级和最低系统尚未通过 |
| P1 共用业务与协议 | 进行中 | 已提取共享设置、固定平台核心下载与进度协议；Swift→Go 握手/保存/重启及真实下载通过；WARP、订阅、GeoSite 与配置生成仍待提取 |
| P2 原生应用骨架 | 未完成 | 可构建应用已有导航、部分顶部栏、服务入口和真实配置客户端；正式 Xcode targets、完整菜单与页面交互验收待完成 |
| P3 原生网络服务 | 未完成 | 已有握手服务、签名 payload 校验、安装/卸载事务与回退；root 系统级流程待用户确认后实测，核心管理与完整协议待实现 |
| P4 TUN 与恢复 | 未开始 | 尚未修改系统 DNS、路由或启动 TUN |
| P5 功能完整与原生体验 | 进行中 | 已接入代理规则编辑、保存和核心准备面板，界面实测待解锁；其他业务页面与真实网络状态未接入，连接按钮禁用，无模拟连接成功状态 |
| P6 DMG 与升级 | 未完成 | 已验证隔离应用的更新与错误签名拒绝；产品更新助手、DMG、正式 appcast 和服务升级事务待完成 |
| P7 回归与交付 | 未完成 | 当前 Mac Go 回归已通过；Windows 运行测试、macOS 13、Intel 及实际校园网络待验收 |

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

## 下一步

1. 用户确认后验证 root Mach service 的安装、双向身份、授权取消、重启、修复和卸载；确认前继续不依赖该权限的开发。
2. 实现 DNS 事务、受控核心进程和失败恢复，再执行真实 TUN/IPv6/解析器验证。
3. 验证 Keychain 在升级/回退后的访问行为；明确 macOS 13 与 Intel 的测试设备路径。
4. 按已经验证的机制接入产品 Swift 更新助手，并补齐 quarantine 分发与网络服务升级事务。
5. 在现有 worker 上继续提取 WARP、订阅、GeoSite 与配置生成，接入凭据存储；完善共用顶部栏命令与其余页面。解锁后验证代理规则表单及核心准备面板；外部设备验收未完成的项目保持未验证，不阻止无依赖工作。

## 可重复验证入口

构建和探针说明见 [macos/README.md](/Users/andy/Study/free-v6/macos/README.md)。Go 测试在受限执行环境中需要允许本机回环服务器；网络依赖下载与真实网络行为分别记录，不能用沙箱失败代替产品失败。
