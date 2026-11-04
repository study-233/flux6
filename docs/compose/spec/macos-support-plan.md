---
feature: macos-support
status: implementing
updated: 2026-11-05
baseline: c528f26
---

# FreeV6 macOS 支持分析与实现计划

开发分支：`mac`。逐步交付与验证证据记录在[开发进度](/Users/andy/Study/free-v6/docs/compose/spec/macos-development-progress.md)。下文的原代码审计以 c528f26 为基线；当前实现状态以进度记录和实际代码为准。

推荐为 Mac 新建独立的 SwiftUI + AppKit 原生客户端，用 Swift 实现系统集成和特权网络服务，复用现有 Go 业务逻辑与 mihomo 网络核心。Windows 继续使用现有 Tauri 客户端。两端共享注册、订阅解析、配置规则与测试样本，分别维护符合各自平台习惯的界面。

本计划采用原生客户端路线：新增 SwiftUI/AppKit 界面、Swift/Go 协议、XPC 服务及 Sparkle 更新。当前仓库已有可构建的原生应用和部分业务、服务实现，仍需完成真实网络连接、完整界面与分发验收，才能交付完整 Mac 版本；下文 Windows 限制分析保留原审计基线。

本计划对应用户确认的范围：Apple Silicon 优先，最低 macOS 13；交付 DMG，暂不购买或配置 Developer ID、不做 Apple 公证；保留本机核心功能和应用内更新。Intel 评估并预留实现，热点共享在明确可行性、实现复杂度与维护要求后决定是否纳入。

后续开发全权交由 Codex 负责。计划只保留任务依赖、交付物和验收条件，不安排人数、岗位、人天或固定周数。Codex 负责细化、实现、验证和修复，并继续下一项依赖已满足的任务；用户无需逐项分派。阶段顺序见[实施阶段和验收条件](#实施阶段和验收条件)，原生上方栏的具体任务见[顶部栏开发清单](#顶部栏开发清单)。

macOS 原生顶部栏是首版必交付项：屏幕顶部应用菜单提供完整命令，窗口标题栏与工具栏提供页面操作和连接控制，右上角状态菜单支持关闭主窗口后的后台控制。P2 完成原生结构和共用命令，P5 接入真实连接与业务状态，P7 完成交互和系统兼容验收；三处入口全部通过对应验收后，才视为顶部栏交付完成。

本次修订确定以下执行约定，后续任务拆分以此为准：

| 决策 | 执行要求 |
| --- | --- |
| 开发责任 | Codex 全程负责选型、实现、调试、验证和交付，以任务依赖与验收结果组织开发 |
| 推进单位 | 使用有明确输入、输出和验收条件的任务；按依赖顺序推进，以可运行结果汇报进度 |
| 原生顶部栏 | 应用菜单、窗口工具栏、右上角状态菜单共同作为首版功能，统一命令、状态和错误反馈 |
| 用户参与 | 需要产品范围取舍时先给出分析与推荐；需要系统授权、真实网络或测试设备时说明具体操作；常规实现由 Codex 自行处理 |
| 完成依据 | 代码、构建、交互和真实网络分别记录验证结果；待验证项目保持待验证，最终交付以验收矩阵为准 |

## 已确认范围和建议交付边界

| 项目 | 交付目标 |
| --- | --- |
| Apple Silicon | 原生 arm64，完整本机功能，独立 DMG |
| 最低系统 | macOS 13.0；原生界面与后台服务均以此作为部署目标 |
| Intel | 保留 darwin/amd64 构建；使用兼容 CPU 基线；经 Intel 真机验证后再声明正式支持 |
| 安装 | DMG 内含 FreeV6.app 和 Applications 快捷入口，应用内安装网络服务 |
| Apple 签名公证 | 首版使用 ad-hoc 代码签名，Developer ID 和公证后置；ad-hoc 不提供 Apple 开发者身份信任 |
| 更新 | 校验版本、架构和更新签名后替换应用；更新签名独立于 Apple 证书 |
| 本机功能 | WARP 注册、TUN、规则/全局/直连模式、开发者模式、校园白名单与黑名单、节点选择与测速、链式代理、备用配置、设置、日志、流量显示 |
| 界面 | 按 macOS 原生习惯重新设计，业务功能保持一致；不要求沿用 Windows 视觉设计 |
| 代码组织 | 同一仓库内新增 Mac 原生入口；共用 Go 业务模块，保留 Windows 客户端 |
| 桌面集成 | 屏幕顶部原生应用菜单、窗口标题栏与工具栏、右上角状态栏入口、关闭隐藏、退出清理、登录启动、静默启动、自动运行、快捷键和系统主题 |
| 执行方式 | Codex 按任务依赖持续实现、验证、修复和更新交付文档；以验收证据确认完成 |
| 热点共享 | 独立可行性阶段；不默认为已经包含，也不永久排除 |

无公证 DMG 可以作为当前交付形式，但首次运行仍要遵循系统对未经公证应用的打开流程。网络服务需要的管理员授权与应用公证是两套机制。计划不依赖关闭 SIP、全局关闭 Gatekeeper 或让整个界面以 root 运行。[Apple 关于打开未知开发者应用的说明](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)

## 技术选型及取舍

| 方案 | 对本项目的收益 | 成本和限制 | 结论 |
| --- | --- | --- | --- |
| 继续 Tauri + Web + Go | 复用现有界面最多，两端视觉和功能容易同步 | 仍需重做 Mac 权限与网络层；原生菜单、窗口、设置和 WebKit 兼容需要额外适配 | 适合优先降低迁移成本，和本次原生体验偏好不完全一致 |
| SwiftUI + AppKit + Go 业务模块 + Swift 网络服务 | 原生界面与系统 API 配合直接，已有网络业务可复用，Windows 业务可同步修复 | 增加 Swift 技术栈、两套界面和进程协议维护 | 推荐 |
| SwiftUI + 全 Swift 业务后端 | Mac 技术栈统一 | 需要重新实现和验证 WARP 注册、订阅解析、配置渲染及下载逻辑；与 Windows 长期分叉 | 首版不采用，后续有具体收益时再逐模块评估 |
| 改用 Flutter、Qt 或 Electron | 可另建跨平台界面 | 又一次界面迁移，仍要做原生权限服务，无法消除本项目的关键系统工作 | 当前没有足够收益支持更换 |

“原生”优先落实在用户界面、窗口行为、系统权限、网络设置和安装生命周期。Go worker 编译为本机 arm64/amd64 可执行程序，不需要用户安装 Go，也不妨碍 SwiftUI 原生体验。保留 Go 的理由是复用已有业务实现和测试，不能据此把当前 Windows helper 原样搬到 Mac。

| 职责 | 选型 | 具体边界 |
| --- | --- | --- |
| 界面 | SwiftUI，AppKit 补充 | 导航、表格、设置、菜单栏、窗口和退出流程；SF Symbols 与系统字体 |
| 流量图 | Swift Charts | 有界历史采样、后台降频；不移植 WebGL 效果 |
| 应用状态 | Swift async/await、actor、ObservableObject | UI 状态在主线程，启停串行化；macOS 13 基线不直接依赖 SwiftData 或新版 Observation |
| 业务模块 | Go | WARP、订阅/链式/备用配置、白黑名单、配置生成、核心下载、GeoSite、公告 |
| 系统网络服务 | Swift + Foundation / SystemConfiguration / Security | XPC、身份校验、root 核心安装、子进程、DNS 事务、恢复 |
| 网络数据面 | 锁定版本的 Darwin mihomo | MASQUE、TUN、规则与流量转发，继续独立进程运行 |
| 业务通信 | 私有 stdin/stdout JSON-RPC | App 启动 Go worker；Mac 不再暴露现有 13335 HTTP 控制接口 |
| 特权通信 | Foundation NSXPCConnection | App 直接连接固定 Mach service；Go worker 无特权接口 |
| 更新 | Sparkle 2 + 独立原生更新助手 | 主 App 协调普通用户助手检查和安装；主 App 保留严格 Hardened Runtime；服务升级另行协调 |
| 构建与测试 | Xcode、Swift Package Manager、Go、XCTest/XCUITest | 固定工具和依赖版本；Mac 构建不要求 Rust 或 Web 前端工具链 |

SwiftUI 的分栏导航适合本项目的状态、节点、配置和日志页面；macOS 13 是 NavigationSplitView 的可用基线。应用菜单通过 SwiftUI Commands 实现，右上角状态栏入口采用 MenuBarExtra，复杂窗口行为通过 AppKit 补充。[Apple 导航说明](https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view)、[MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)、[Swift Charts](https://developer.apple.com/documentation/charts)

两套界面的维护是明确接受的成本。通过共享业务模块、版本化协议、功能清单和跨平台测试样本控制分叉；不在 Swift 里再实现一套订阅和 WARP 业务规则。

## 项目架构和现有启动链路

| 层 | 当前实现 | 迁移判断 |
| --- | --- | --- |
| 前端 | 原生 HTML、CSS、JavaScript，Material Web 与 Lit 本地 vendoring，没有 npm 构建流水线 | 保留为 Windows 界面；Mac 复用功能定义和交互语义，重新实现原生界面 |
| 桌面壳 | Tauri 2，Rust，锁文件中 tauri 为 2.11.6；窗口、托盘、快捷键、sidecar、更新 | 保留 Windows 入口；Mac 新建 Swift 入口，避开这里的 Win32 编译依赖 |
| 普通业务 | Go 1.25，freev6-helper 提供本地 HTTP API | 提取注册、订阅、配置等为共享模块；Windows 保留 HTTP 适配，Mac 使用独立 worker |
| 网络数据面 | 外部 mihomo v1.19.31，通过配置启用 MASQUE 和 TUN | 上游已有 Darwin 构建基础，需要正确选包和实测 |
| 网络状态 | Windows PowerShell、netsh、ICS、WinRT | macOS 实现缺失，由新的 Swift 服务承担 |
| 发布 | GitHub Actions 在 Windows 构建 NSIS，发布单个 Windows 更新描述 | 新增 Mac 构建和按平台发布的更新元数据 |

当前链路是：Tauri 启动 → 用 Win32 随机数 API 生成 token → 启动 Go sidecar 并传入 FREEV6_ROOT 和 FREEV6_API_TOKEN → 前端访问 127.0.0.1:13335 → helper 渲染配置、准备 GeoSite、捕获网络快照、启动 mihomo → 前端直接携带 controller secret 访问 127.0.0.1:9090。

运行状态主要保存在安装根目录下的 config、state、runtime 中。前端的主题和累计流量等另有 localStorage 状态。CLI 的 start/stop 与 GUI helper 存在重复的生命周期逻辑。Mac 的诊断与恢复命令统一连接原生服务；现有 Go CLI 不直接作为 Mac 的网络启停入口。

## 阻碍 macOS 支持的具体问题

以下是当前实现的审计结果。原生方案避开 Rust/Web 的 Mac 移植工作，但核心资产、配置、权限、目录与恢复问题仍需解决；这些问题不能因更换界面而消失。

### 编译和构建

1. [tauri.conf.json](/Users/andy/Study/free-v6/src-tauri/tauri.conf.json:8) 的构建前命令使用 del、move、Windows 路径和固定的 x86_64-pc-windows-msvc sidecar 名；bundle.targets 仅为 nsis。
2. [main.rs](/Users/andy/Study/free-v6/src-tauri/src/main.rs:93) 无条件链接 advapi32、user32、kernel32，使用 SystemFunction036、RegisterHotKey、MessageBoxW 等 Win32 API；update_apply 无条件导入 std::os::windows::process::CommandExt。这是明确的 Darwin 编译或链接阻碍。
3. [build.rs](/Users/andy/Study/free-v6/src-tauri/build.rs:1) 围绕 Windows manifest 配置。若选择继续移植 Tauri，需要隔离这些配置；当前原生方案不编译此入口。仅设置 WindowsAttributes 未必本身就造成 Mac 编译失败，不能与上述无条件 Win32 调用混为一谈。
4. 当前没有 Mac 图标、Mac bundle 配置、服务安装资源或 Darwin CI。

### 核心下载和识别

[download.go](/Users/andy/Study/free-v6/internal/mihomo/download.go:24) 固定下载 Windows amd64-v3 ZIP，哈希也只对应该包。临时文件固定为 .zip；解压器虽然有 gzip 分支，但靠临时文件扩展名选择格式，输出名仍固定为 Windows .exe。只替换 URL 仍会失败。

[runtime.go](/Users/andy/Study/free-v6/internal/mihomo/runtime.go:15) 根据 GOOS 和 GOARCH 拼文件名，却对所有平台加 .exe；两个发现测试也硬编码 Windows 名称。因此 Go 使用了跨平台语法，并不代表运行时和测试已经跨平台。

上游固定版本的构建工作流包含 darwin/arm64 和 darwin/amd64，并对非 Windows 输出 gzip。实施时应核实对应 release 资产存在、下载并锁定实际摘要，不凭文件名推测 SHA256。Intel 优先选择 amd64-v1，避免直接沿用当前 Windows amd64-v3 的 CPU 要求。[mihomo v1.19.31 构建工作流](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/.github/workflows/build.yml)

### 权限和网络操作

[snapshot_other.go](/Users/andy/Study/free-v6/internal/network/snapshot_other.go:10) 的 CaptureSnapshot 直接返回 ErrWindowsOnly；RestoreSnapshot 也返回该错误。helper 的 startProxy 无条件捕获快照，因此即使手动放入可执行的 Darwin mihomo，当前启动链路仍会在这里失败。[启动调用点](/Users/andy/Study/free-v6/cmd/freev6-helper/main.go:643)

非 Windows 的 IsAdministrator 固定返回 false，而 helper 仅在 Windows 执行管理员检查。macOS 没有权限安装、授权拒绝、服务故障或权限撤销的状态模型。Windows 当前依赖整个桌面程序提权，再由 sidecar 继承权限；Mac 版应改为普通用户界面配合专用网络服务。

### TUN 和 DNS

[config.go](/Users/andy/Study/free-v6/internal/mihomo/config.go:197) 将 device 固定为 FreeV6TUN，并共用 strict-route、auto-route、dns-hijack 等字段。Mac 应使用动态 utun 设备，记录实际设备名和本次会话所拥有的资源。

这里有一个需要准确区分的细节：固定版本 mihomo 会检查 Darwin 设备名，对 FreeV6TUN 这类不合法名称警告并重新生成 utun 名称。因此这一配置不能直接判定为必然启动失败，但依赖 Windows 固定名称的上层逻辑不能沿用。[固定版本 TUN 实现](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/listener/sing_tun/server.go)

DNS 是实际功能风险：发往局域网 DNS 的请求不能假定被 dns-hijack 自动接管；strict-route 的 Windows 行为也不能当作 Mac 的泄漏防护。当前 DNS 监听 0.0.0.0:1053，系统 DNS 设置通常只接受地址，不能简单把系统 DNS 写成 127.0.0.1 就假设请求会到 1053。[mihomo TUN 文档](https://wiki.metacubex.one/en/config/inbound/tun/)

当前上游文档出现的 dns-mode 不能直接抄入本项目：检查 v1.19.31 的配置结构没有该字段。Mac 方案必须基于锁定核心做真实解析和流量测试；升级核心应作为单独决策。[v1.19.31 配置源码](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/config/config.go)

### 数据目录和资源

Rust 将 current_exe().parent() 传给 FREEV6_ROOT；在 .app 内这通常对应 Contents/MacOS。继续在这里写 config、state 和 runtime，会产生安装位置权限、签名完整性和升级丢数据问题。[start_helper](/Users/andy/Study/free-v6/src-tauri/src/main.rs:543)

GeoSite 的种子文件查找也假设 state 的父目录就是安装根，而 Mac bundle 的资源目录与可执行文件目录不同。Rust 的 settings_flag 同样从可执行文件旁读取。原生方案通过 Bundle 和显式目录契约解决 Mac 的资源定位，不复用这段 Rust 路径推断。[geodata.go](/Users/andy/Study/free-v6/internal/mihomo/geodata.go:194)

### 退出和崩溃恢复

[process.go](/Users/andy/Study/free-v6/internal/mihomo/process.go:75) 停止 mihomo 时直接 Kill；Start 没有对应的 Wait 回收。Unix 下需要优雅终止、限时等待和子进程回收，不能以删除 PID 文件表示停止完成。

[process_unix.go](/Users/andy/Study/free-v6/internal/mihomo/process_unix.go:10) 将 signal(0) 的所有错误视为未运行。拆出 root 核心后，普通用户探测可能得到 EPERM；此时不能判定进程已退出。仅记录 PID 还可能误识别复用后的其他进程。

Rust 的 stop_helper 直接杀 sidecar；正常退出的网络停止依赖前端先调用停止 API。当前没有 Go 信号处理和 HTTP Shutdown，也没有统一覆盖 Cmd+Q、强制退出、注销、关机、后台服务重启的清理机制。

残留快照恢复失败后，现有 healLeftoverSnapshot 记录告警并允许继续启动，新快照可能覆盖旧基线。Mac 版需要独立的恢复事务，防止把已修改的 DNS 重新记为原始状态。[恢复逻辑](/Users/andy/Study/free-v6/cmd/freev6-helper/main.go:698)

### 桌面功能和前端兼容

登录启动依赖 schtasks 和注册表；外观取色依赖 reg；快捷键依赖 Win32 消息循环；背景效果是 Windows mica/acrylic；界面窗口按钮也是 Windows 形式。非 Windows 上部分功能会直接报错，部分会返回空结果而表面成功。

macOS 的 WKWebView 与 Windows WebView2 不同。现有 [index.html](/Users/andy/Study/free-v6/web/index.html:12) 使用 Import Maps，Material Web 通过裸模块名导入。Import Maps 和 constructible stylesheets 在 Safari 16.4 才加入，早期 macOS 13 自带的 WebKit 不能假定兼容。若继续使用 Web 界面，还需检查 Material Web 的 ElementInternals、CSS color-mix 和玻璃效果的降级；单纯打出 .app 可能仍出现控件未注册或主题异常。原生方案避开这部分兼容工作，该项仅保留为技术选型依据。[WebKit 16.4 发布说明](https://webkit.org/blog/13966/webkit-features-in-safari-16-4/)

### 更新和发布

[update.go](/Users/andy/Study/free-v6/cmd/freev6-helper/update.go:113) 固定下载 freev6-update-setup.exe；version.json 只有一个 download 和 sha256，没有平台与架构映射。Rust 使用 NSIS 的 /S 和 /FREEV6REL 参数执行安装。Mac 更新要替换整个 .app，并协调服务版本和网络恢复。

目前元数据和安装包都可能经过同一镜像，SHA256 可检验文件是否与给定摘要一致，但不能单独建立发布者身份。Mac 更新应使用内置公钥验证发布签名，这不要求 Apple Developer 账号。[Sparkle 更新签名说明](https://sparkle-project.org/documentation/)

NSIS 还承担用户协议展示、运行中检测和卸载清理。换成 DMG 后，需要把对应行为迁入应用的首次启动和服务卸载流程，不能只移植安装文件。

## 推荐的 Mac 架构

```mermaid
flowchart TD
    App[SwiftUI / AppKit 原生应用 当前用户] -->|私有 stdio JSON-RPC| Worker[Go 业务 worker 当前用户]
    Worker --> Shared[共用 Go 业务模块]
    Win[现有 Windows HTTP helper] --> Shared
    App -->|受限 XPC| Service[Swift 网络服务 root]
    Service -->|会话专属 job| Launchd[launchd 核心任务管理]
    Launchd --> Core[mihomo root]
    Service --> Network[SystemConfiguration / DNS / 恢复事务]
    App --> Keychain[当前用户 Keychain]
    App --> UpdateAgent[原生更新助手 当前用户 Sparkle]
    Worker --> UserData[用户业务配置与下载缓存]
    Service --> RootData[root 所有的核心与会话数据]
```

启动路径为：App 检查服务状态 → Go worker 准备业务配置与资源 → App 通过 XPC 提交结构化启动请求 → Swift 服务校验、准备事务并启动 mihomo → App 从服务订阅状态、流量与日志。界面、业务 worker、网络服务和核心分别承担不同职责，只有后两者以 root 运行。

首版继续使用 mihomo 的 utun 路径。Network Extension 涉及扩展目标、签名授权及核心嵌入方式，不作为本次无 Developer ID 版本的默认实现；后续取得签名身份后再单独评估。首版采用站外 DMG 分发，不以 Mac App Store 或 App Sandbox 为目标。

### Go 业务复用与协议

先将 cmd/freev6-helper 中混合在 HTTP handler 内的业务提取到 internal/app 等共享包。Windows handler 继续适配原有请求与响应，新的 cmd/freev6-worker 只负责 Mac 的进程协议。复用 internal/warp、internal/mihomo 中的平台无关部分和相关测试；平台启停、ICS、注册表、schtasks 与 Windows 更新不进入 worker。

Go worker 由 App 从 bundle 内固定位置启动，以私有管道通信。协议采用带长度前缀的 JSON-RPC 2.0，定义握手、协议版本、请求 ID、错误码、超时、取消和进度通知。stdout 只输出协议，日志写 stderr；限制消息尺寸、导入尺寸和并发数量，处理管道背压。父进程断开后 worker 退出，App 负责回收；worker 崩溃不会自行重启 TUN。

业务方法包括 settings、registerWarp、importChain、fetchCloudConfig、prepareConfiguration、downloadRuntime、prepareGeodata、fetchNotice。它们返回业务数据或受控资源标识，不能执行系统命令。协议样本放在同一目录，Swift/Go 两端都用这些样本验证字段、默认值和错误码。

首版采用独立 worker，避免引入 Go 动态库、cgo 与 Swift 跨语言内存管理。若以后测得进程成本显著，再评估库化；本阶段没有为语言统一而重写业务的必要。

### 配置进入 root 的边界

Go 负责生成规范的配置模型，Mac 适配器输出结构化 JSON。Swift 服务使用受限 DTO 和字段规则验证模型，并自行生成或覆盖 controller、secret、工作目录、DNS/TUN、日志与 GeoSite 路径；订阅不能决定这些字段。校验节点协议与字段类型，拒绝任意插件、脚本、外部控制器和不受控本地路径。确有需要的本地资源先导入并映射为服务管理的资源 ID。

当前交接契约进一步限制为五类业务字段：模式、节点、分组、规则提供者和规则。系统字段不经过 worker 结果交接，由服务组装；请求绑定已保存设置 revision、凭据 revision 与固定资源 ID。App 按用户操作从 Keychain 提取隧道密钥及地址，注册 token 不进入该流程；UI 只保留脱敏摘要。WARP 路径与 Swift 结构校验已接入，链式/备用节点协议、root 复验和启动仍按后续阶段完成。

计划让 mihomo 读取服务生成的 JSON 配置，以避免 Swift 再解析用户 YAML。P0 必须用锁定核心执行真实 -t 验证该格式、字段和等价性；不能仅凭 JSON 属于 YAML 子集便认定可用。若核心不接受，只更换最后的序列化适配，并评估固定版本 YAML 库，不复制订阅业务。Windows 继续使用现有 YAML 输出。

服务只允许固定资源安装、startSession、stopSession、status、recoverSession 和有限 controller 操作，不提供任意命令、任意 URL 代理或任意路径写入。当前资源接口命名为 installApprovedResource/resourceStatus，覆盖核心和三份规则数据；其余生命周期方法随网络阶段实现。启停串行化，重复 stop 幂等，请求绑定用户与 session ID。

用户下载的核心只能作为暂存文件。服务使用随可信发布交付的版本/架构摘要清单重新验证，将内容复制到 root 所有的暂存文件后复验，再原子安装和执行。不可接受调用者同时提交任意二进制和任意“期望哈希”；文件描述符或受控资源交接也要防止符号链接与替换竞态。

mihomo controller 采用服务私有目录内的 Unix socket，App 通过受限 XPC 获取连接、节点、测速、切换和流量状态；服务验证目标名称及参数，不转发任意 controller 路由。已通过锁定核心的普通用户探针验证 100 字节 socket 路径和关闭 IP controller。该版本 Unix listener 不使用 secret 认证且将 socket 设置为 0666，因此启动前必须由服务创建并验证 root 所有、0700、无 allow ACL 的父目录，不能依赖 secret 或让核心自行创建目录。跨用户隔离与 root 运行仍须实测。[固定版本 Unix listener](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/route/server.go#L237)

服务内部的 [核心控制接口 v1](/Users/andy/Study/free-v6/shared/protocol/core-controller-v1.md) 已实现版本就绪、模式、节点、固定目标测速和流量读取，并在普通用户隔离核心上验证。每次请求核对目录、socket 与当前 job 的对端 UID/PID；模式和节点写入后回读确认。当前 XPC 仍为 v4，尚未提供运行会话及这些控制方法，需由后续会话协调器接入所有者校验、串行操作和恢复状态。

### 无 Developer ID 时的服务安装和 XPC

macOS 13 提供 SMAppService，但 ad-hoc 签名不能被视为稳定服务授权身份。Apple DTS 指出，App 与 helper 使用 ad-hoc 签名可能出现授权持久性问题。因此当前选择固定安装程序 + launchd，后续将注册方式替换为 SMAppService。[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)、[Apple DTS 说明](https://developer.apple.com/forums/thread/799910)

1. 用户将 App 拖入 Applications，首次启用 TUN 时完成网络服务安装。
2. 固定 bootstrap 通过系统管理员授权执行有限安装操作。可在原型中使用 osascript 管理员授权入口；参数严格编码，只允许安装、修复、卸载和受控版本切换，不能拼入订阅内容或任意命令。
3. 将 Swift 服务安装到 /Library/PrivilegedHelperTools/dev.freev6.network-service，将固定 Label 和 MachServices 的 plist 放入 /Library/LaunchDaemons；文件 root 所有、普通用户不可写，安装失败回滚。
4. App 通过 NSXPCConnection 连接固定 Mach service。launchd 注册与 XPC 通信是不同问题，使用 XPC 不要求把首版安装方式绑定到 SMAppService。
5. 服务升级、客户端身份更新与卸载走同一管理入口。无证书阶段可能需要再次管理员授权，不承诺所有升级静默完成。

当前安装原型把服务 SHA256 嵌入安装工具的已签名 Mach-O，服务源文件先复制至 root 私有暂存并验证，再进入固定安装目录。客户端只登记与管理员授权请求中 CDHash 匹配、启用严格 Hardened Runtime 的代码；首版要求该代码不携带 entitlement。原始资源不用于选择 root 可执行程序。安装事务保留旧文件及其摘要，跨文件替换前先持久化记录，健康检查通过后提交；回退失败时保留恢复资料。固定恢复工具也被登记为 root 管理客户端，仅在已获管理员权限时使用。

安装、卸载及安装恢复与会话准备共用全局网络锁，在锁内检查会话记录，避免检查后又创建会话。健康握手不依赖该锁；启动后的网络恢复另行调度，不能在安装尚持锁时阻塞健康检查。会话准备的磁盘格式与验证见 [session-preparation-v1.md](/Users/andy/Study/free-v6/shared/protocol/session-preparation-v1.md)；当前格式只覆盖未启动进程的准备数据，不能代替后续网络事务。

XPC 使用公开 API 在激活连接前设置对端代码要求。已检查本机 SDK：NSXPCConnection.setCodeSigningRequirement 从 macOS 13 可用。服务同时检查 effective UID、安装时登记的客户端代码摘要与会话归属；App 也验证服务身份。不能只核对 PID、进程名或路径，也不依赖私有 auditToken 属性。[Apple XPC API](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))

无 Team ID 阶段，在管理员安装时登记允许的客户端 CDHash；新版本代码摘要变化后，默认重新授权登记。未来可用服务独立验证的发布签名清单更新可信摘要，但这属于明确实现的协议，不能用 App 的自报版本绕过。P0 验证双向身份检查、ad-hoc 重新构建后的行为及重新授权流程。

登记客户端前同时检查 Hardened Runtime 与代码注入相关 entitlement。主 App 和网络服务保持严格 Library Validation，不携带 get-task-allow、允许 DYLD 环境注入或关闭库校验的权限。更新助手需要单独的库加载配置，不能登记为特权服务客户端，也不能代替主 App提交特权操作。CDHash 登记与运行期保护共同构成身份边界。

将服务注册封装为 ServiceInstaller。以后取得 Apple 签名身份后迁到 SMAppService，并从 CDHash 登记改为受控签名要求；升级时先清理旧服务，保证只有一个实例管理网络。

### 数据所有权和目录

| 内容 | 位置 | 唯一写入方 |
| --- | --- | --- |
| Swift App、Go worker、可选只读 GeoSite 种子 | FreeV6.app/Contents 下的标准目录 | 构建与应用更新 |
| 外观、窗口、快捷键、登录启动偏好 | UserDefaults | Swift App |
| 业务设置、订阅、规则、累计流量 | ~/Library/Application Support/dev.freev6.desktop | Go worker；App 通过协议修改 |
| WARP 私钥、凭据与敏感订阅令牌 | 当前用户 Keychain | Swift App，经私有管道按需提供给 worker |
| 下载暂存 | ~/Library/Caches/dev.freev6.desktop | Go worker；Sparkle 使用其自身缓存机制 |
| 用户诊断日志 | ~/Library/Logs/dev.freev6.desktop | 日志模块，按来源独立文件并轮转 |
| 受信核心、配置、恢复事务 | /Library/Application Support/dev.freev6.desktop | Swift 网络服务 root |
| 服务锁、会话配置和 controller socket | /Library/Application Support/dev.freev6.desktop 下的私有目录；socket 使用 sessions/<UUID>/c.sock | Swift 网络服务 root |

资源路径由 Bundle 提供，显式传递 DataDir、ResourceDir、CacheDir、LogDir，淘汰 Mac 的单一 FREEV6_ROOT 假设。业务 schema 保留版本号和迁移备份，保证 Windows 的“省略字段即保留”语义不因提取模块丢失。运行状态由网络服务负责；累计流量按 session ID 去重，App 采样后交 worker 持久化。

GeoSite、GeoIP 与 MMDB 通过同一固定版本清单准备，校验每个文件的大小上限及 SHA256。当前 Mac 构建采用首次准备下载，缓存放在 `CacheDir/geodata/<revision>`；只读种子接口保留，若后续随包分发，需核对对应数据来源、许可证和源码材料。上游 meta-rules-dat 仓库当前声明 GPL v3，不能直接套用旧说明中的 Apache-2.0-only 标注。[上游许可证](https://github.com/MetaCubeX/meta-rules-dat/blob/master/LICENSE)

三个文件全部准备完成后才进入网络启动检查；Darwin 配置固定数据 URL 并关闭核心自动更新，root 服务按自身清单复验副本。上游版本更新经开发验证后随受信应用版本发布，不能接受调用者传入的 URL 或摘要替换可信清单。

Keychain 接入需要抽象现有 Go 凭据读写接口，避免注册时再次保存明文私钥。ad-hoc 升级后的 Keychain 访问和重新授权列入 P0，不承诺无提示迁移。服务运行核心所需的临时配置仍可能包含凭据，使用 root 私有目录与 0600 文件，停止后按恢复需求清理；日志与诊断包脱敏。

所有 root 会话按 UID/session 区分。同一时间只允许一个网络会话持有者，其他用户看到占用状态，不能读取其凭据或停止其会话。App 退出与后台存活语义由显式状态机决定，不以窗口是否存在判断。

## TUN 和网络恢复设计

### 配置和 DNS

RenderOptions 增加显式平台能力参数，避免渲染函数隐式依赖当前编译主机。Windows 保留 FreeV6TUN；Mac 让核心选择 utun，并读取实际运行结果。macOS 首版不自动修改系统 HTTP 或 SOCKS 代理，因为当前目标是 TUN；若以后增加系统代理模式，再单独实现其快照和恢复。

DNS 原型比较两条路径，选定一条后固定到实现和测试：

- 把活动网络服务的 DNS 指向可由 TUN 接收的专用地址，由 mihomo 的端口 53 劫持交给内部 DNS；必须验证 IPv4、IPv6、LAN DNS 和启动时序。
- 若锁定核心无法可靠处理上述路径，则在 loopback 的 53 端口提供受控 DNS 入口，转交内部 1053；先检查 TCP 和 UDP 53 占用，避免与其他 DNS 软件冲突。

系统 DNS 由 Swift 服务调用 SystemConfiguration，按网络服务标识读取与设置；networksetup、scutil 可作为原型和诊断工具。保存的是用户显式 DNS 配置及“未手动配置、由 DHCP 提供”的区别，而不是将 scutil 的有效解析器列表原样写回。保存 search domains 和本次实际修改的服务，尊重 VPN 的 scoped resolver，避免粗暴覆盖全部网卡。

### 网络事务

建议状态：stopped → preparing → starting → running → stopping → stopped；失败可能进入 recovering 或 recoveryRequired。

启动顺序为：校验服务权限、核心与配置 → 检查端口和现有会话 → 恢复旧事务 → 记录基线并持久化事务 → 启动核心 → 确认 controller 与 TUN 就绪 → 应用所需 DNS → 验证解析和出口 → 标记 running。

停止顺序由 Mac 后端定义，不能直接复制 Windows 为 ICS 设计的顺序。目标是先让系统 DNS 回到仍可用的原解析路径，再向核心发送 SIGTERM，等待路由与 utun 清理，超时才升级为 SIGKILL，最后核验残留并完成事务。失败保留恢复记录和错误，不覆盖原基线。

只撤销本会话确实拥有的改动。恢复前比较当前值与本次写入值；如用户或其他 VPN 已改过 DNS，应保留其新设置并报告冲突。网卡服务被删除、重命名、切换 Wi-Fi、拔插网卡时，按稳定服务标识重新关联，不能只依赖显示名称。

核心使用由 launchd 直接管理的会话专属 job，名称从服务生成的 session UUID 派生；服务通过该标识管理核心，不向历史 PID 发送信号。2026-11-05 的普通用户实验发现，仅让核心继承服务进程组并设置 `AbandonProcessGroup=false`，仍可能留下忽略 SIGTERM 的子进程，因此不能将其作为核心恢复保证。直接管理 job 的对照实验已验证正常停止、SIGKILL 升级、控制宿主强退后的新进程接管及固定核心 `-t`；root 与最低系统验收仍需完成。

启动记录须包含 session ID、系统启动 UUID、服务启动来源、固定核心身份、任务用途及持久化阶段。先记录注册意图，再注册 `RunAtLoad=false`、`KeepAlive=false` 的 job；注册本身不运行核心。确认注册后先持久化启动意图，再执行 `kickstart`。退出后先记录确认的退出结果，再移除 job 和清理会话文件；未知结果或任务意外缺失时保留记录，不把“查询不到”直接当作核心已安全退出。准备记录 v1 仍只允许无进程、无网络改动，新的 job 协调器不得复用其清理语义。

`ManagedCoreJob` 使用受限的固定 `launchctl` 命令，依据手册定义的 `list` 列读取任务状态，不解析 `print` 的诊断文本。停止先按 job 标识发送 SIGTERM，宽限超时后发送 SIGKILL；确认 launchd 已回收核心后才允许移除 job。核心以固定 `/usr/bin/env -i` 清空继承环境后原位执行，标准输入输出均指向 `/dev/null`。短时命令仍通过受控 `posix_spawn`、`waitid(WNOWAIT)` 与互斥的 `waitpid` 回收；需读取的命令输出有容量和时间上限。[检查记录 v2](/Users/andy/Study/free-v6/shared/protocol/session-check-v2.md) 已串联服务内的注册/启动意图、job 退出与恢复，[XPC v4](/Users/andy/Study/free-v6/shared/protocol/service-v4.md) 在实际核心 `-t` 成功并清理后才确认通过；正常网络会话与 DNS 事务仍待接入，检查恢复不代表网络恢复完成。

root 服务的状态仍是 UI 的权威来源。GUI 意外消失后默认在短暂重连宽限期后停止会话并恢复网络；宽限时间在实机验证后确定。服务重启时先协调旧 job 与原 DNS 基线，再接受新会话，不能自动启动另一份核心。

睡眠和唤醒、网络变更时重新探测出口与解析器；网络不可用时进入可理解的等待状态，避免无限重启或把新 DHCP 信息覆盖为旧值。关机强杀无法保证即时执行清理，因此下一次服务启动必须先恢复再允许启动新会话。

## 原生界面与功能对应

主窗口采用 NavigationSplitView：侧栏提供“概览、节点、配置、日志”，通用偏好使用标准 Settings 场景。Mac 保持正常 Dock 应用形态，提供完整的屏幕顶部应用菜单、窗口顶部工具栏与右上角状态栏入口。界面数据通过 ViewModel/actor 连接 worker 与服务，View 不直接读写系统网络或业务文件。

### macOS 原生顶部栏设计

顶部区域包含以下三个原生入口，作为同一套功能设计和验收：

| 入口 | 出现位置与时机 | 主要用途 |
| --- | --- | --- |
| 应用菜单栏 | 屏幕顶部左侧，FreeV6 为当前应用时 | 完整命令、快捷键、设置、更新、窗口管理和退出 |
| 窗口标题栏与工具栏 | 主窗口顶部，随当前页面变化 | 页面常用操作、连接状态与连接/断开按钮 |
| 状态栏入口 | 屏幕顶部右侧，应用在后台时仍可使用 | 快速查看连接、切换模式/节点、打开主窗口与退出 |

三处均使用 macOS 原生组件。应用菜单跟随当前应用切换；后台入口独立提供快捷控制。[Apple MenuBarExtra 文档](https://developer.apple.com/documentation/swiftui/menubarextra)

```text
屏幕顶部，FreeV6 激活时：
  FreeV6  文件  编辑  显示  连接  窗口  帮助       …  [FreeV6 状态图标]  [系统项目]

主窗口顶部：
[系统红黄绿按钮]  [侧栏开关]  [页面名称]       [页面操作]  [连接状态]  [主要操作]

各页面的默认布局（已完成准备、未连接时）：
概览    [概览]                                 [未连接]  [连接]
节点    [节点]       [搜索节点…] [测速]         [未连接]  [连接]
配置    [配置]       [保存] [重新载入] [更多 ▾] [未连接]  [连接]
日志    [日志]       [级别 ▾] [暂停] [导出]     [未连接]  [连接]

右上角 FreeV6 状态图标展开后（已连接示例）：
已连接 · 规则模式
当前节点：所选节点
上传 / 下载速率
────────────────────
断开连接
工作模式             ▸
切换节点             ▸
────────────────────
打开主窗口
设置…
────────────────────
退出 FreeV6
```

这只是布局示意，表示控件分组与优先级，不固定像素坐标。四个页面共用系统窗口按钮与侧栏开关；配置页“更多”包含导入和刷新备用配置。已连接时主要操作为“断开”；准备未完成时显示对应准备入口。Apple 菜单、窗口按钮和系统项目由 macOS 管理；App 使用系统菜单与标题栏组件。右侧状态图标的位置由系统和用户安排。

#### 三处入口的命令对应

下表是最终产品的命令分配，作为实现与交互验收的共同清单。应用菜单承担完整命令入口，工具栏保留当前页面的高频操作，状态菜单保留后台快捷操作。工具栏命令同时提供应用菜单入口，符合系统工具栏可隐藏的使用方式。[Apple 工具栏设计说明](https://developer.apple.com/design/human-interface-guidelines/toolbars)

| 操作 | 屏幕顶部应用菜单 | 主窗口工具栏 | 右上角状态菜单 |
| --- | --- | --- | --- |
| 连接 / 断开 | “连接”菜单，⌘⇧K | 各页面均可达的主要按钮 | 状态摘要之后的主要操作 |
| 工作模式 | “连接 → 工作模式”，勾选当前模式 | 从配置页编辑，保持顶部紧凑 | 规则 / 全局 / 直连子菜单 |
| 切换节点 | “连接”菜单进入节点选择 | 节点页搜索与测速，列表选择节点 | 当前节点、最近节点及“全部节点…” |
| 保存 / 重新载入 | “文件”菜单，保存为 ⌘S | 配置页按草稿状态启用 | 通过打开配置页完成 |
| 导入 / 刷新备用配置 | “文件 / 连接”菜单 | 配置页次要操作 | 通过打开配置页完成 |
| 日志 / 诊断导出 | “文件”菜单 | 日志页导出，诊断从详情进入 | 错误状态提供诊断入口 |
| 设置 / 更新 | “FreeV6”菜单，设置为 ⌘, | 保留给页面操作 | 设置入口；更新在设置中可达 |
| 打开主窗口 | “窗口”菜单 | 已处于主窗口 | 固定入口，恢复并激活主窗口 |
| 退出 | “FreeV6”菜单，⌘Q | 使用系统窗口按钮管理窗口 | 固定“退出 FreeV6”，共用退出流程 |

表中快捷键均为应用内命令；全局唤出快捷键单独配置。主窗口的红色关闭按钮和 ⌘W 隐藏主窗口，保留后台连接与草稿；设置、帮助等辅助窗口的 ⌘W 只关闭当前窗口，草稿按对应编辑页规则处理。⌘Q 执行完整退出，标题栏不另加退出按钮。功能暂不可用时，由同一命令模型决定禁用状态，并在对应页面说明所缺条件。

当前代码已有 [NativeCommands.swift](/Users/andy/Study/free-v6/macos/Sources/FreeV6App/NativeCommands.swift) 中的菜单、工具栏和状态菜单骨架，以及 [DesktopCommands.swift](/Users/andy/Study/free-v6/macos/Sources/FreeV6Desktop/DesktopCommands.swift) 中的共用命令模型。后续在这些入口上补齐本设计：真实连接状态、模式与最近节点切换、流量摘要、状态栏显示偏好及交互验收仍属待完成项。已有菜单结构不表示上述命令已经全部可用。

#### 原生组件与实现落点

后续开发在已有入口上补齐以下职责；按职责扩大后再拆文件，避免另建一套菜单或连接状态。

| 设计部分 | 原生实现 | 当前入口与待完成工作 |
| --- | --- | --- |
| 屏幕顶部应用菜单 | SwiftUI Commands、CommandGroup、CommandMenu，焦点通过 FocusedValue 传递 | NativeCommands.swift：补齐模式与节点命令；保存、导出和搜索根据当前窗口与页面启用 |
| 标题栏和工具栏 | 系统红黄绿按钮、统一工具栏样式、ToolbarItem；需要时使用 NSToolbar | FreeV6App.swift、NativeCommands.swift：连接当前页标题、搜索、过滤和真实连接按钮，验证收窄及隐藏后的操作入口 |
| 右上角状态菜单 | MenuBarExtra 的菜单样式和显示偏好；需要时使用 NSStatusItem | FreeV6App.swift、NativeCommands.swift：补齐真实状态、速率、模式、最近节点和显示开关；后台操作保持窗口焦点 |
| 共享命令与状态 | DesktopCommand、命令可用性、AppModel 与连接协调器 | DesktopCommands.swift、AppModel.swift：三处使用同一请求与状态；重复触发、超时和失败按同一规则处理 |
| 窗口和退出 | NSApplicationDelegate、NSWindowDelegate 与标准 Settings 场景 | FreeV6App.swift、AppModel.swift：区分主窗口隐藏、辅助窗口关闭、Dock 重开和完整退出；连接退出接入网络恢复事务 |

菜单和工具栏遵循系统组件的焦点及显示行为；工具栏中的动作同时提供菜单入口。参考 [Apple 菜单与焦点说明](https://developer.apple.com/documentation/swiftui/building-and-customizing-the-menu-bar-with-swiftui)和[工具栏设计规范](https://developer.apple.com/design/human-interface-guidelines/toolbars)。上表是实现任务映射，API 的最低系统可用性与交互效果在 macOS 13 上单独验证。

#### 屏幕顶部应用菜单

采用“FreeV6 → 文件 → 编辑 → 显示 → 连接 → 窗口 → 帮助”的菜单顺序。FreeV6 为当前应用时显示其菜单；切换到其他应用后遵循系统菜单切换行为。

| 菜单 | 内容与行为 |
| --- | --- |
| FreeV6 | 关于 FreeV6、设置…（⌘,）、检查更新…、macOS 标准“服务”子菜单、隐藏与显示、退出 FreeV6（⌘Q） |
| 文件 | 导入链式代理配置…（⌘O）、保存配置（⌘S）、重新载入配置…、导出日志…、导出脱敏诊断…、关闭窗口（⌘W）；采用系统文件选择与保存面板 |
| 编辑 | 保留系统撤销/重做、剪切/复制/粘贴、全选等命令，跟随当前输入框或列表焦点启用 |
| 显示 | 显示/隐藏侧栏、概览/节点/配置/日志（⌘1–⌘4）、显示/隐藏工具栏、进入/退出全屏；查找（⌘F）聚焦当前页面搜索，日志过滤与暂停显示命令仅在对应页面可用 |
| 连接 | 连接/断开（⌘⇧K，应用内快捷键）、工作模式、当前节点切换、测量节点延迟、刷新备用配置；分组提供“设置网络服务…”与核心准备入口；模式和节点用勾选表达当前选择 |
| 窗口 | 系统最小化、缩放、窗口切换等命令，以及显示主窗口；窗口行为由 AppKit 协调 |
| 帮助 | FreeV6 使用说明、安装与网络恢复指引、打开诊断页面 |

以 SwiftUI `.commands`、CommandGroup 和 CommandMenu 扩展系统菜单，侧栏等操作优先使用系统命令组；AppKit 仅补充需要的行为。标准编辑命令保持 responder chain 的焦点语义，避免应用级快捷键截获正在编辑的文本。[Apple 原生菜单实现说明](https://developer.apple.com/documentation/swiftui/building-and-customizing-the-menu-bar-with-swiftui)

“保存配置”与“重新载入配置…”只作用于当前获得焦点的规则编辑页，包括主窗口配置页和设置窗口中的代理规则页。重新载入遇到未保存内容时先确认；保存失败保留草稿。保存成功仅表示业务配置已持久化，运行中是否应用、是否需要重连由连接协调器明确反馈。macOS 标准“服务”菜单与本应用的“设置网络服务…”分别保留各自语义。

#### 窗口标题栏与工具栏

采用系统标题栏和统一样式的原生工具栏。左侧保留系统红黄绿按钮与侧栏切换，以“概览”“节点”等当前页面名称帮助定位，右侧优先显示连接状态和主要连接操作。页面标题跟随系统布局，不强制绝对居中。标题栏保留可拖动区域，支持系统双击、全屏和窗口缩放行为。

页面相关操作放在主操作之前：节点页提供搜索和测速，配置页提供导入与刷新，日志页提供过滤和导出。窗口变窄时，由系统溢出菜单收纳放不下的次要操作，连接状态与连接/断开入口保持可达；额外的“更多”菜单只承载固定的低频操作，不另造一套随宽度变化的溢出逻辑。每个工具栏命令在顶部菜单中有对应入口，隐藏工具栏后仍可使用。[Apple 工具栏设计说明](https://developer.apple.com/design/human-interface-guidelines/toolbars)

| 页面 | 页面相关工具栏操作 | 操作条件 |
| --- | --- | --- |
| 概览 | 保持简洁，以连接状态和连接/断开为主 | 缺少安装、凭据或配置时，主要操作显示明确的准备入口 |
| 节点 | 搜索、测量节点延迟 | 搜索只改变当前列表；测速中显示进度并阻止重复提交同一任务 |
| 配置 | 保存配置、重新载入；导入配置、刷新备用配置作为次要操作 | 保存与重新载入针对当前草稿；导入和刷新按配置来源启用，遵守链式/备用配置互斥规则 |
| 日志 | 级别过滤、暂停/继续显示、导出日志 | 暂停只停止界面追加，后台日志仍按容量上限采集；导出前脱敏 |

首版采用固定的工具栏分组与系统溢出行为，保留“显示/隐藏工具栏”，不增加工具栏自定义编辑器。设置使用独立标准窗口；该窗口获得焦点时，节点测速、日志导出等依赖主窗口上下文的命令禁用，连接、检查更新和打开主窗口等应用级命令仍按各自状态工作。

实现采用 SwiftUI `.toolbar`、ToolbarItem/ToolbarItemGroup 和统一工具栏样式，必要时桥接 NSToolbar。使用系统图标、字体和间距，图标按钮提供帮助文本与 VoiceOver 标签；在 macOS 13 上使用可用的原生材质，较新系统的视觉效果按 availability 增强。

#### 视觉规格与尺寸适配

| 设计项 | 首版规格 |
| --- | --- |
| 整体外观 | 系统字体、语义颜色、SF Symbols 与原生材质；随深浅色和辅助功能设置变化；品牌标识放在应用图标、关于窗口及状态栏图标中 |
| 工具栏分组 | “导航与页面名称 / 当前页面操作 / 连接状态与主要操作”三个逻辑组；使用系统间距，保留窗口拖动区域 |
| 连接按钮 | 保留文字标签“连接”“断开”或对应准备操作；忙碌时显示进度和具体状态，避免只用播放/停止图标表达网络行为 |
| 信息密度 | 窗口顶部展示短状态；当前节点、速率和详细错误放在页面或状态菜单内，长节点名不得挤占连接操作 |
| 窗口尺寸 | 默认 920 × 620 pt，最小尺寸以 720 × 480 pt 为起点进行实机验证；窄窗口允许折叠侧栏，页面内容滚动，首屏不因错误提示遮住主要操作 |
| 收窄优先级 | 优先保留主要操作与可辨认的连接状态；搜索可收为系统搜索入口，次要操作进入原生溢出菜单；全部命令仍可从应用菜单访问 |
| 状态图标 | 使用系统菜单栏尺寸和模板渲染；正常、活动和异常状态可辨认，辅助功能名称同时说明 FreeV6 与当前状态 |
| 动效与刷新 | 状态变化采用短暂系统过渡，遵循“减少动态效果”；速率变化不引起菜单宽度反复跳动，失联后停止显示为实时数据 |
| 不同系统 | macOS 13 使用其原生外观；较新系统随系统组件呈现相应效果，新 API 逐项检查可用性，保持同一套功能和操作顺序 |

这些尺寸是初始产品规格，按真实窗口、文本长度和可访问性验证调整。工具栏的原生布局与溢出行为遵循系统组件；视觉验收同时检查深色、浅色、减少透明度和键盘焦点。[Apple 工具栏设计说明](https://developer.apple.com/design/human-interface-guidelines/toolbars)

#### 屏幕右上角状态栏入口

应用运行期间提供单色模板状态图标，使用 MenuBarExtra 的原生菜单样式，必要时以 NSStatusItem 补充。图标区分已连接、未连接和需要处理的状态；展开后始终用文字说明，不能只靠颜色。默认保持紧凑，不在顶部持续滚动日志或显示长节点名。

展开菜单依次提供：当前状态与简短流量摘要、连接/断开、工作模式、当前节点与有限数量的快速切换项、打开主窗口、设置…、退出 FreeV6。完整节点列表和错误详情在主窗口查看。关闭主窗口后该入口继续工作；点击打开主窗口会恢复窗口并激活应用。[Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)

快速节点菜单显示当前节点和最近使用的节点，去重后最多 5 项，末尾提供“全部节点…”进入节点页；首次无历史记录时只显示现有可用项。模式菜单提供规则、全局、直连；开发者模式遵循现有独立业务设置。切换完成前不提前改变勾选，失败时保留服务确认的选择并给出原因。

状态栏默认只显示紧凑模板图标；上传/下载速率放在展开的菜单中，不持续占用屏幕顶部宽度。菜单关闭时停止仅供该菜单使用的刷新任务。后台控制不主动抢占应用焦点；只有打开页面、处理授权或查看错误详情时才激活对应窗口。状态栏位置遵从系统安排，不要求固定在时钟左侧或始终可见，Dock 入口仍可恢复主窗口。

设置提供“在菜单栏中显示 FreeV6”，默认开启。MenuBarExtra 使用带 `isInserted` 绑定的初始化方式，与主窗口场景共存；隐藏状态入口只改变显示偏好，不能等同于退出或断开。该入口隐藏后，用户仍可从 Dock 打开主窗口并在设置中恢复显示。[Apple MenuBarExtra 显示绑定](https://developer.apple.com/documentation/swiftui/menubarextra/init(isinserted:content:label:))

异常时沿用同一菜单结构：状态文字改为“需要设置网络服务”“正在恢复网络…”或“状态未知”，主要操作改为对应的设置、查看进度或诊断入口。失联时不继续显示上次的实时速率，最后一次确认的数据明确标为历史状态。网络尚未恢复时，退出入口进入恢复流程并说明结果。

#### 首次打开、后台运行与偏好

首次打开显示协议与安装引导，主窗口可见；完成引导后，普通启动恢复上次页面，静默启动仅保留后台入口。静默启动遇到授权或配置问题时显示待处理状态，由用户打开设置处理，避免反复激活窗口。自动连接始终受服务授权、凭据和配置前置条件约束。

记住上次页面、侧栏与工具栏可见性、窗口尺寸及位置；显示器变化后将窗口恢复到可见区域。模式与节点恢复业务设置，但连接状态必须重新向服务查询，不能依据上次显示值认定已经连接。首版保留正常 Dock 图标和默认状态栏入口，关闭主窗口后仍可从任一入口重开。

#### 共用状态与交互约束

应用菜单、窗口工具栏和状态栏菜单调用同一 AppCommands/ConnectionCoordinator，读取服务提供的权威状态，不分别实现启停。连接中、停止中和恢复中显示明确文字，并禁用重复操作；服务尚未安装时，连接操作进入已定义的安装流程，不能提前显示连接成功。

| 服务与连接状态 | 三处统一显示 | 主要操作与限制 |
| --- | --- | --- |
| 服务未安装或待授权 | 需要设置网络服务 | “设置网络服务…”打开安装说明与授权流程；后台启动不反复弹出授权 |
| 已就绪、未连接 | 未连接 | “连接”；缺少凭据、核心或配置时先显示对应准备步骤 |
| 正在准备或连接 | 正在准备… / 正在连接… | 禁用重复启停、切换模式和节点；进度及失败原因可从主窗口查看 |
| 服务确认运行 | 已连接 | “断开”；允许当前能力支持的模式与节点切换，提交期间禁用对应操作 |
| 正在停止或恢复 | 正在断开… / 正在恢复网络… | 禁止新建会话；恢复确认后才显示“未连接” |
| 启动失败且已恢复 | 连接失败，网络已恢复 | 提供重试与查看详情；重试重新检查前置条件 |
| 服务失联或恢复失败 | 状态未知 / 网络恢复失败 | 提供诊断与恢复入口；不推断已断开，不允许直接新建会话覆盖恢复记录 |

状态快照包含会话标识与递增版本，迟到的事件不覆盖新状态。菜单打开期间若服务断开，要更新命令可用性；无论操作来自哪一处，最终执行前都再次检查状态。命令失败反馈关联原请求，避免快速切换时把旧任务的结果显示为当前任务成功。

无可用目标的命令保持可见但禁用；菜单中的模式和节点勾选与页面同步。全局唤出快捷键与应用内快捷键分别管理。关闭窗口继续后台运行；所有“退出 FreeV6”入口统一停止会话、恢复网络并回收进程。设置、帮助等打开窗口的操作，从后台入口触发时应正确激活目标窗口。

#### 顶部栏交互交付检查

以下流程作为三处顶部入口的共同验收场景，每项记录实际操作与结果。页面能显示、按钮能点击和真实业务成功分别核验。

| 场景 | 用户操作与预期结果 |
| --- | --- |
| 首次启动、准备未完成 | 主窗口展示准备步骤；应用菜单、工具栏和状态菜单均依据相同前置条件显示可用操作；缺少服务、凭据或资源时说明下一步，不显示“已连接” |
| 正常连接与断开 | 从任一入口发起操作，另两处同步忙碌状态；服务确认后再更新连接状态、模式与节点勾选；断开完成包括网络恢复与进程回收 |
| 关闭主窗口、后台控制 | 关闭窗口后连接按既定策略继续；从右上角菜单查看状态、切换模式或节点；这些操作不主动弹出主窗口；“打开主窗口”和 Dock 点击可恢复窗口 |
| 连续操作、切换窗口 | 在三处快速重复触发连接、准备或退出，不创建重复任务；切换到设置窗口后，保存等命令跟随编辑焦点；普通文本编辑快捷键保持系统行为 |
| 关闭辅助窗口 | 设置或帮助窗口获得焦点时，⌘W 只关闭该窗口；不误隐藏主窗口、不停止连接；配置草稿按编辑页规则保留或确认处理 |
| 服务失联、恢复失败 | 三处显示“状态未知”或恢复失败，停止展示旧的实时速率；提供诊断或恢复入口，禁止新会话覆盖未完成的恢复记录 |
| 退出应用 | 应用菜单、状态菜单和 ⌘Q 使用同一退出流程；有未保存草稿时处理草稿，运行中先停止并恢复网络；失败时明确说明当前结果 |
| 隐藏状态入口、空间受限 | 隐藏状态图标不改变连接；图标因全屏、自动隐藏或刘海屏空间不可见时仍能通过 Dock 重开窗口；工具栏收窄或隐藏后仍能从应用菜单执行对应操作 |

视觉与可访问性另外覆盖：应用激活/失焦、默认与最小窗口尺寸、长节点名、多显示器、全屏、系统自动隐藏菜单栏、深浅色、减少透明度、键盘导航与 VoiceOver。三处入口的文字、勾选和命令可用性必须一致；在 macOS 13 与当前系统分别记录结果。

### 功能对应清单

| 当前功能 | Mac 实现 | 验收重点 |
| --- | --- | --- |
| 启动、停止、状态 | 原生主按钮与菜单栏操作，共用启停状态机 | 安装缺失、等待网络、正在恢复、失败状态可区分，不能重复启动 |
| 实时流量与累计流量 | Swift Charts、小型统计卡片 | 有界采样、后台降频、跨重启累计值和断线重连去重 |
| 节点和测速 | 原生 Table/List、搜索、排序、上下文菜单 | 切换/测速结果对应实际节点，大列表和批量任务不阻塞 UI |
| 规则/全局/直连及开发者模式 | 设置中的原生 Picker/Toggle | 保留现有行为和互斥关系，运行中修改策略明确 |
| 校园白名单与黑名单 | 可编辑列表、校验提示、导入/删除 | 域名与 CIDR 规则继续由共用 Go 模块校验 |
| 链式代理 | URL 输入和 NSOpenPanel 文件选择 | 导入、启用、清除、错误反馈；保存其他设置不会误关链式 |
| 备用配置 | 校园入口设置、获取与刷新、更新时间 | 和链式代理的互斥与字段保留语义一致 |
| WARP 注册与核心下载 | 原生进度、取消、重试和状态 | Mac 设备名、缺凭据、缺核心、错误架构和失败恢复 |
| 日志与公告 | 有界原生日志列表、过滤、复制/导出、公告视图 | 脱敏、容量限制、长时间运行内存稳定；远端内容按数据呈现 |
| 外观 | 深浅色/跟随系统、系统强调色、原生材质 | 尊重提高对比度/减少透明度；纯黑与自选背景可用原生绘制保留 |
| 登录与静默启动 | 原生设置 + 登录项适配器 | 用户关闭系统后台权限时显示实际状态；不等于启动即开启 TUN |
| 自动运行 | 网络就绪后由 App 协调连接 | 先满足协议同意、服务授权与凭据条件，避免重复弹窗或循环重试 |
| 更新、关于、协议、重置 | 标准菜单与设置页面 | 首次同意协议、展示版本、可检查更新；重置先停止会话并说明数据范围 |
| 热点共享 | 能力项与单独验证报告 | 在真实可用之前不提供可开启但无效的开关 |

Mica、Acrylic 和 WebGL 液态玻璃属于 Windows/Web 实现细节，在 Mac 中映射为系统材质与标准窗口效果。自定义外观不能影响可读性与可访问性；macOS 13 不依赖更新系统才提供的视觉 API，后续可按 availability 增强。

桌面生命周期由 AppKit 协调：关闭窗口隐藏到菜单栏，Dock 点击重开；Cmd+Q 和菜单退出走停止、恢复、回收流程，恢复未完成时显示明确状态。二次打开聚焦已有实例，不按固定端口或进程名杀进程。网络服务安装与运行状态分别显示，不再用单个 admin 布尔值决定全部功能。

提供标准编辑菜单、Cmd+C/V/A、Cmd+W、Cmd+,、键盘导航和 VoiceOver 标签。应用菜单使用 Commands；右上角状态栏入口使用 MenuBarExtra，如最低系统行为有缺口，局部使用 NSStatusItem。全局快捷键采用小型原生注册适配器（优先验证 RegisterEventHotKey），允许修改组合键、检测冲突，不为简单热键默认要求辅助功能监听权限。

登录启动在无证书阶段采用固定用户级 LaunchAgent，参数仅包括静默启动等已定义选项；记录“希望开启”和系统“实际启用”两种状态。通过 LoginItemManager 隔离，后续切换经验证的 SMAppService 登录项方案。禁用登录启动不自动卸载网络服务，卸载服务不应破坏用户的业务配置。

Swift UI 状态采用 macOS 13 可用的 ObservableObject/@Published 与 async/await；使用 actor 管理连接和并发。避免将整套代码建立在更高系统版本才可用的 SwiftData、@Observable 或新视觉 API 上。日志、节点和流量使用批量更新与有界缓存，P5 记录空闲 CPU、连接时内存及长时间运行曲线作为基线。

## DMG、更新与卸载

产物先按架构分开：`FreeV6_<version>_arm64.dmg`；Intel 验证后提供 `FreeV6_<version>_x86_64.dmg`。首版不要求 Universal 2；以后合并时必须同时处理 App、Go worker、Swift 服务和其他嵌入组件的架构。Intel 使用兼容 CPU 基线，并独立验证所有依赖和最低系统，不以 Rosetta 运行成功替代真机结果。

Xcode 工程包含 App、网络服务、bootstrap/恢复工具与测试 target；Swift Package Manager 固定第三方依赖。构建脚本先生成指定 GOOS/GOARCH 的 worker，再放入 bundle 固定位置；构建设置统一最低 macOS 13。Mac 不打包 Web 页面、Tauri Rust 壳或 Windows helper。使用系统 hdiutil 制作 DMG，提供 Applications 拖放入口和简短安装说明。

首版使用 ad-hoc 签名，按内部组件到外层 bundle 的顺序签名并验证完整性；这不等同于 Developer ID 或公证。安装测试必须来自实际下载、带 quarantine 的 DMG，覆盖系统允许的首次打开流程。检测直接从只读 DMG 或转移路径启动，引导完成安装后再安装网络服务。

mihomo 保持首次下载：按架构取得锁定资产、检查摘要与解压上限、设置执行位，再交服务复验安装。项目的 THIRD-PARTY 明确把运行时下载的 mihomo 与随包分发区分，本轮不把核心直接加入 DMG；分发方式变更时需同步更新许可与源码交付材料。[当前第三方说明](/Users/andy/Study/free-v6/THIRD-PARTY.txt:78)

### 原生应用更新

采用 Sparkle 2，通过独立的普通用户 Swift 更新助手接入检查更新和安装流程，由主 App 的 UpdateCoordinator 协调。发布每架构独立 appcast 与完整 .app ZIP 更新包。发布包使用 Ed25519 签名，公钥内置 App，私钥仅用于受控发布；Apple 开发者证书不替代该发布密钥。Windows 继续使用现有 version.json，避免旧客户端获取 Mac 资产。[Sparkle 官方接入说明](https://sparkle-project.org/documentation/)

依赖锁定经审查的确切版本；P0 已使用 2.9.6 官方资产并验证摘要，安全记录包含该版修复。Sparkle 只在普通用户更新助手中运行，不进入 root 网络服务或安装工具。[Sparkle 安全与可靠性记录](https://sparkle-project.org/documentation/security-and-reliability/)

P0 已复现 ad-hoc 主程序启用严格 Hardened Runtime 时，dyld 因 Team ID 不匹配拒绝加载 Sparkle。因此调整为：主 App 只链接系统框架并保留严格库校验，Sparkle 嵌入独立更新助手；仅助手设置 disable-library-validation。助手从自身所属的固定 App bundle 获取更新目标、公钥和 feed，不接受任意目标路径或外部传入的更新公钥。正式客户端采用 Swift；P0 的 Objective-C 测试宿主只用于直接验证框架 API，不随产品交付。

独立助手已在当前 Apple Silicon 系统完成真实本地 N→N+1 更新和重启；错误 Ed25519 签名被拒绝且旧版保留。该实验使用临时密钥、随机测试 bundle ID 和回环更新源，未覆盖带 quarantine 的下载、最低系统或生产服务事务，不能据此宣称分发验收完成。其余 P0/P6 验证继续覆盖嵌入签名、带 quarantine 的 DMG、macOS 13 和更新后的服务重新登记。[验证记录](/Users/andy/Study/free-v6/docs/compose/spec/macos-development-progress.md)

应用更新协调顺序：取得并验证更新 → 检查 App/worker/服务协议和数据 schema → 恢复网络并停止会话 → 暂停自动运行 → 由 Sparkle 替换 App → 必要时通过固定 bootstrap 更新服务与登记客户端身份 → 握手与健康检查 → 恢复用户操作。服务不兼容时保持断开状态，提供完成升级或回退入口，不允许旧服务接收未知启动请求。

计划支持相邻版本的协议兼容窗口，并将最小服务版本、配置 schema 与核心摘要清单纳入受信发布数据。服务升级需要管理员授权时提前告知；取消后保持已恢复的网络，保留旧服务与数据备份。App 更新与系统级服务更新是两个事务，要用持久化标记覆盖中途退出和重启。

服务安装包和可信客户端清单若由服务自动接受，必须使用其内置公钥独立校验，不能仅依赖 App 声称“Sparkle 已验证”。首版优先通过明确的管理员安装入口升级服务，之后再增加受信清单的自动登记能力。发布密钥需有备份与轮换方案；无 Developer ID 时丢失更新密钥会影响后续可信升级。

应用无写权限、下载失败、错误签名、错误架构和服务升级失败均不得先删除旧的可用版本。保留可安装的上一版 DMG 与迁移备份，实际验证恢复流程；不能默认 Sparkle 会自动回滚业务数据或系统服务。手动安装 DMG 作为故障恢复入口保留。

### 卸载和恢复

应用提供“停止并卸载网络服务”和“删除应用数据”独立操作。正常卸载停止核心、恢复 DNS/会话资源、移除 launchd 服务和登录项，再清理状态；删除凭据需由当前用户 App 处理 Keychain。

DMG 同时提供签名一致的原生恢复/卸载工具，服务安装时保留可供管理员调用的固定恢复入口。误删 .app 后仍能停止会话、恢复网络、卸载服务。仅把 .app 拖到废纸篓不会自动删除手动安装的 LaunchDaemon，必须在说明和验收中覆盖此情况。

## 热点共享可行性与实施复杂度

现有热点功能是 Windows ICS/WinRT 拓扑切换，不能移植 API 名称后继续使用。Mac 的系统 Internet Sharing 支持在不同接口间共享，例如 Ethernet 上网、Wi-Fi 下发，但这只证明基础共享能力，不证明下游流量会经过本项目的 mihomo TUN。[Apple Internet Sharing 说明](https://support.apple.com/en-sg/guide/mac-help/mchlp1540/mac)

| 方案 | 效果 | 限制 | 实施复杂度与必要工作 |
| --- | --- | --- | --- |
| 首版只支持本机 TUN | 本机完整功能 | 手机共享暂不可用 | 无共享模块；完成本机 TUN 验收 |
| 局域网 HTTP/SOCKS 代理 | 支持代理设置的手机或应用可使用 Mac 出口 | 不等于透明热点，部分应用和 UDP 流量不能覆盖；需要访问认证和限定监听接口 | 中：增加认证、接口绑定、设备接入指引与访问控制测试 |
| 系统共享加下游路由适配 | 指定双接口拓扑下让手机透明使用代理出口 | 需验证转发、DNS、NAT/PF、IPv6、TUN 栈对转发流量的处理；系统共享可能重建规则 | 高：先验证指定拓扑，再实现转发、DNS、NAT/PF 与启停恢复 |
| 自动管理任意热点拓扑 | 接近 Windows 一键共享体验 | 当前没有已验证的跨版本实现；内置 Wi-Fi 同时上联与作为 AP 不能预先承诺 | 尚不确定：先验证硬件与公开能力，再决定支持范围 |

建议先在 Ethernet/USB 网卡上联、Wi-Fi 下发的明确拓扑做验证，手机分别检查 IPv4、IPv6、DNS、UDP 和实际出口；验证停止后系统共享恢复原状。若需要 PF，只使用专用 anchor 并记录本次改动，不替换或清空系统全局规则。未验证前，Mac capability 应返回不支持热点，不能出现可打开却没有效果的开关。

热点是否纳入首版由验证报告决定；局域网代理作为独立产品选项，不标为“已完成热点共享”。

## 文件级实施拆分

下表为建议落点，文件名可随实现调整。Mac 系统能力放在 Swift 内，不再另建一套 Go 的 Darwin DNS/权限后端。

| 模块 | 建议文件或目录 | 工作 |
| --- | --- | --- |
| 原生工程 | macos/FreeV6.xcodeproj、macos/Packages | App/服务/工具/测试 targets、SwiftPM 锁文件、部署目标 |
| 界面 | macos/FreeV6App/Features、AppModel、Resources | 概览、节点、配置、日志、设置、图标、首次启动和协议 |
| 桌面系统层 | macos/FreeV6App/Platform | AppKit 生命周期、快捷键、登录启动、Keychain |
| 顶部栏与共用命令 | macos/FreeV6App/Commands、macos/FreeV6App/Toolbar、macos/FreeV6App/MenuBar | 应用菜单、原生标题栏/工具栏、状态栏入口、焦点与命令可用性、统一连接操作 |
| Swift 业务连接 | macos/FreeV6App/Clients/WorkerClient | 子进程、stdio 编解码、取消、进度和故障重连 |
| Go 业务提取 | 新增 internal/app、internal/paths；调整 internal/warp 与 internal/mihomo | 与 HTTP/Windows 解耦、注入目录和凭据存储接口、保持业务语义 |
| Mac worker | 新增 cmd/freev6-worker | JSON-RPC 适配，仅普通用户业务，无 HTTP 控制端口 |
| Windows 适配 | cmd/freev6-helper/main.go、chain.go、cloudconfig.go 等 | 调用共享业务，维持原有 API、字段保留与更新行为 |
| 协议契约 | shared/protocol、shared/fixtures | Swift/Go DTO、版本、错误码、功能能力和等价配置样本 |
| XPC 共享层 | macos/Packages/ServiceProtocol | 固定方法、受限消息类型、版本握手和调用超时 |
| 原生网络服务 | macos/FreeV6NetworkService | 身份校验、配置验证、核心安装、进程、controller 代理、DNS 与事务恢复 |
| 服务管理 | macos/ServiceInstaller、macos/Resources/LaunchDaemons | 固定 bootstrap、plist、身份登记、升级回退、卸载 |
| 恢复工具 | macos/FreeV6Recovery | GUI/命令入口，复用服务恢复接口；误删 App 后仍有恢复路径 |
| 核心与资源 | internal/mihomo/download.go、runtime.go、config.go、geodata.go | 平台资产映射、格式/哈希、Mac 配置输出、真实资源路径；修正平台相关测试 |
| 原生更新 | macos/FreeV6App/UpdateCoordinator、macos/FreeV6UpdateAgent | 普通用户更新助手、Sparkle、服务兼容检查、升级事务和重新授权流程；助手无特权 XPC 身份 |
| Mac 发布 | scripts/macos、独立 Mac CI/release jobs | Go 目标构建、xcodebuild、签名、DMG、appcast、来源证明 |
| 文档 | README、THIRD-PARTY、Mac 开发/安装/更新/恢复指南 | 双平台支持范围、工具链、权限与用户流程 |

Windows 的 src-tauri 和 web 保持各自的平台入口。本阶段不新增 tauri.macos.conf.json、不为 Mac 改造 Material Web、不采用 Tauri updater，也不要求将 Windows 一起迁到 Swift。

## 实施阶段和验收条件

后续开发由 Codex 负责方案细化、编码、构建、测试、问题修复和交付文档，按照下列依赖顺序持续推进。阶段编号表示任务依赖与验收范围。常规技术选型、模块拆分和问题修复由 Codex 自行处理；涉及已确认范围的实质变化时，提交具体取舍给用户。需要用户亲自操作的系统授权、真实校园网络或额外测试设备时，说明需要完成的操作与验收目标。

| 执行情形 | 处理方式 |
| --- | --- |
| 常规选型、编码、调试、构建及回归 | Codex 在已确认范围内自行推进，记录结果与下一项任务 |
| 单项实现完成 | 附改动、验证结果和剩余限制，继续下一项依赖已满足的工作 |
| 缺少真机、网络环境或必须由用户完成的系统操作 | 提出具体所需条件，该验收保持待验证，同时推进不依赖它的任务 |
| 热点是否纳入、提高最低系统、要求购买证书或缩减核心功能 | 先给出实验结论、可选方案和推荐，再由用户决定范围变化 |

每项任务记录输入与前置条件、实现范围、交付文件、验证方法、通过证据及剩余问题。完成一项后继续处理依赖已满足的下一项，阶段汇报围绕可运行结果，不要求用户逐项安排开发工作。文档更新、构建成功、模拟验证与真机验收分别记录，不能互相替代。

开发记录统一使用“待开始、进行中、待外部条件、已验收”四种任务状态。“已验收”必须附对应证据；“待外部条件”说明缺少的具体设备、网络或系统操作，并列出可继续开发的任务。进度汇报只包含本次交付、验证结果、剩余问题及下一项任务，不使用人数配置或按工时推算的完成百分比。

| 阶段 | 主要交付 | 依赖 | 完成条件 |
| --- | --- | --- | --- |
| P0 技术验证 | 原生最小 App、Darwin 核心、XPC/安装、DNS、Keychain 与更新实验 | 无 | 在 macOS 13 和当前系统验证核心配置、真实 TUN、恢复、无证书服务身份与 N→N+1 更新；输出可重复操作记录 |
| P1 共享业务与协议 | Go 业务提取、凭据/路径接口、Mac worker、协议样本 | P0 | Windows 原有测试与 API 语义通过；Swift/Go 协议对齐；业务 worker 不接触特权操作 |
| P2 原生应用骨架 | Xcode targets、导航、AppModel、顶部应用菜单/工具栏/状态栏、设置、目录契约 | P0、P1 | arm64 干净构建；真实 worker 握手；最低系统打开所有基础页面与原生顶部栏；基础命令可用；bundle 内无运行期写入 |
| P3 原生网络服务 | launchd/bootstrap、XPC 身份与权限、核心安装、卸载和服务协议 | P0、P1 | 授权接受/取消、重启、代码摘要变化均有明确结果；错误身份/架构/哈希/任意路径请求被拒绝 |
| P4 TUN 与恢复 | 配置策略、DNS 事务、进程管理、断线和恢复冲突处理 | P0、P3 | 启停、强退、核心崩溃、睡眠、网络切换后可恢复；原始基线不被覆盖；无跨用户操作 |
| P5 功能完整与原生体验 | 全部业务页面、顶部栏状态/焦点联动、图表、日志、快捷键、登录启动、可访问性 | P2、P4 | 功能对应表逐项通过；关闭与退出语义一致；性能、主题和数据保存符合验收 |
| P6 DMG 与升级 | ad-hoc 分发、Sparkle、客户端登记/服务升级、恢复工具 | P3、P5 | 实际下载的 DMG 可安装；N→N+1 完成；授权取消和升级失败可恢复；误删 App 可卸载服务 |
| P7 回归与交付 | Apple Silicon/最低系统、Intel 评估、Windows 回归、发布文档 | P6 | 发布矩阵通过；Intel 未过真机验收明确标预览；资产、签名与更新清单一致 |

每次开发按以下顺序形成可审查的结果：选择依赖已满足的任务 → 细化输入、输出及失败行为 → 实现最小完整功能 → 执行针对性验证并修复 → 更新进度与证据 → 推进下一项。表中依赖落实到具体任务的前置验证：例如，最低系统设备尚未就绪时，可以继续共享业务提取和菜单布局；真实网络启停仍须先通过身份、核心配置与恢复机制的相应验证。暂缺设备的验收保持“未验证”，不据此宣称阶段完成。

### 顶部栏开发清单

以下任务均由 Codex 逐项实施。当前起点依据仓库代码核对，完整能力仍以实机验收为准。顺序为：UI-01 补齐命令与状态契约 → UI-02、UI-03、UI-04 补齐三处入口 → UI-05 接入真实网络状态 → UI-06 完成交互验收。布局、焦点和偏好可先实现；连接、模式和节点切换需等待服务接口具备对应能力。

| 任务 / 阶段 | 当前起点 | 剩余交付与完成条件 |
| --- | --- | --- |
| UI-01 共用命令 / P2 | 已有 DesktopCommand、可用性判断和场景焦点 | 补充连接/断开、模式和节点命令；三处共用执行入口；保存跟随编辑上下文，标准编辑快捷键跟随输入焦点 |
| UI-02 应用菜单 / P2 | 已有文件、显示、连接、帮助等命令骨架；未接入能力禁用 | 补齐模式/节点子菜单、搜索和日志命令；验证菜单顺序、分组、快捷键与勾选；无主窗口时仍可打开主窗口、设置和退出 |
| UI-03 标题栏与工具栏 / P2 | 已有统一工具栏、按页面切换的操作、服务状态和主要按钮 | 按上方四页布局接入搜索、过滤、导入及真实连接状态；验证收窄、隐藏、拖动、全屏与系统窗口按钮；所有动作有应用菜单入口 |
| UI-04 状态菜单 / P2、P5 | 已有 MenuBarExtra、准备状态、主窗口与设置入口 | 补齐真实连接、速率、工作模式、最近节点及显示偏好；关闭窗口后可控制连接；隐藏图标后可从 Dock 恢复；后台操作不无故抢焦点 |
| UI-05 状态联动 / P5 | 已有配置检查互斥和部分迟到结果保护，尚无运行会话状态 | 接入会话标识与递增版本；统一忙碌、失败、失联和恢复反馈；勾选只随确认结果变化；启动重新查询，旧事件不覆盖新状态 |
| UI-06 交互验收 / P5、P7 | 早期窗口与快捷键已有部分实测，最新完整流程待验证 | 逐项执行“顶部栏交互交付检查”；退出完成网络恢复；覆盖 macOS 13、静默启动、全屏、多显示器、键盘与 VoiceOver，并记录实际结果 |

每项交付记录实现文件、操作步骤和验证证据。当前相关代码入口为 `FreeV6App.swift`、`NativeCommands.swift`、`DesktopCommands.swift` 和 `AppModel.swift`；继续在现有结构上完善。仅完成布局或命令模型测试时，真实连接及系统交互仍保留待验收状态。

### 技术验证与后续推进

P0 要产生明确结论，而非仅展示一个原生窗口：

1. 锁定 mihomo 在 Darwin 上的 MASQUE、TUN、配置格式和 DNS 路径是否满足现有业务。
2. launchd 安装、双向 XPC 身份校验、无证书客户端升级后的重新授权是否可靠；恢复工具能否独立工作。
3. Keychain 在 ad-hoc 首装、升级和回退时的行为，以及凭据存储接口如何迁移。
4. Sparkle 与无证书分发配置能否在最低系统和当前系统完成真实更新；无法达成时应怎样调整实现路线与任务依赖。
5. Xcode/Go 工具链、依赖与核心资产对 macOS 13/arm64 的实际支持；Intel 构建是否有基础阻碍。

这些问题主要需要实验，不需要现在再让用户选择实现细节。只有原型发现必须提高最低系统、引入 Apple 证书、缩减功能或更改热点范围时，再将结果与具体取舍交用户决定。

先提取共享业务并维持 Windows 行为，再分阶段新增 Mac targets。每阶段独立提交可审查改动，配置语义变化用相同输入样本比较 Windows 与 Mac 的业务部分；TUN/DNS 等平台差异单独断言。避免把界面重做和所有系统操作混在一个大补丁里。

## 测试和发布验收矩阵

| 类别 | 必须覆盖的情况 |
| --- | --- |
| 系统与架构 | Apple Silicon 的 macOS 13、至少一个中间主版本、当前系统；Intel 真机独立验收；检查 App/worker/服务/核心架构一致 |
| 安装与授权 | 实际下载带 quarantine 的 DMG、Applications 安装、直接在 DMG 中运行、标准用户使用管理员授权、拒绝/取消、中断与重启 |
| IPC 与身份 | worker 协议错版本、截断/超大消息、超时/取消/背压、进程崩溃；XPC 错误身份、旧 CDHash、伪造服务、断线重连、跨用户调用 |
| 核心与配置 | 平台资产映射、ZIP/gzip、错误哈希/架构、解压限制、执行位、替换竞态；真实核心 -t、字段白名单、危险路径和 controller 字段覆盖 |
| 业务 | WARP 注册与重试、规则/全局/直连/开发者模式、白黑名单、测速/切换、链式与备用配置互斥、字段省略保留、缺 GeoSite、公告与重置 |
| 凭据与数据 | Keychain 首装/升级/回退/拒绝访问、敏感 URL、日志脱敏、迁移失败、磁盘满、缓存损坏、重复采样不重复累计流量 |
| 网络 | DHCP/静态 DNS、多个 resolver、IPv6 校园网、LAN DNS、IPv4/IPv6 解析与出口、其他 VPN/代理和端口冲突 |
| 生命周期 | 重复启停、Cmd+Q、关闭隐藏、App/worker 强退、核心崩溃、服务重启、注销/关机、睡眠唤醒、Wi-Fi 切换、USB 网卡拔插 |
| 恢复与占用 | 用户或其他 VPN 修改 DNS/路由、网络服务删除/重命名、事务写入中断、旧快照损坏、恢复失败、快速切换用户与会话占用 |
| 原生 UI | macOS 13、深浅色、Retina/多显示器、Dock 重开、VoiceOver、减少透明度、登录/静默启动、大节点列表和长时间日志 |
| 顶部栏 | 应用菜单顺序、焦点与编辑快捷键、工具栏折叠/隐藏、全屏与自动隐藏菜单栏、状态栏后台控制、窗口重开、三处状态一致、重复触发与退出清理 |
| 更新与卸载 | N→N+1、错误签名/架构/版本、下载中断、应用无写权限、服务协议不兼容、重新授权取消、回退、误删 App 后恢复和卸载 |
| Windows 回归 | 原有 Go 单测、HTTP API、Tauri 构建、NSIS、提权、热点、配置与更新保持可用 |

自动化分四层：共享 Go 业务与协议样本；Swift XCTest 的状态机、配置验证和 XPC 测试；XCUITest 的原生界面流程；专用 Mac 测试机上的权限、真实核心和网络场景。普通 CI 构建成功不能替代真实校园 IPv6 网络验证，也不能证明校园计费结果。

CI 分开构建 Windows 和 Mac。Mac job 显式设置 Xcode DEVELOPER_DIR、部署目标与 GOARCH，固定 SwiftPM/Go 依赖；不要默认 runner 的当前架构就是目标架构。共享 Go 模块在两平台执行测试，Windows 继续执行 Rust/Web 的现有检查。

发布由单一汇总 job 收齐产物后创建草稿 release，校验版本、架构、更新包、签名和 appcast 一致。密钥不暴露给外部 PR，沿用 provenance attestation，并将 DMG、更新包、服务发布数据纳入来源与完整性检查。最低系统与网络实机验收通过后再标记相应平台正式支持。

## 分析基线与当前验证范围

原始代码审计以提交 c528f26 为基线，检查了主要启停调用链、Go 业务与平台耦合、Tauri/Web 入口、核心下载、设置、测试及发布流程，并对照 Apple、Sparkle 和固定版本 mihomo 的资料。上文的迁移问题描述基线行为；后续实现的完成情况由[开发进度](/Users/andy/Study/free-v6/docs/compose/spec/macos-development-progress.md)记录。

当前工作区已有原生应用雏形、部分 P0 验证代码、设置/核心/WARP/规则数据 worker 方法、Keychain 凭据存储及三处顶部入口的共用命令。App 已通过 XPC v4 接入缓存资源 FD 交接、服务独立复验、私有配置准备和实际核心 `-t` 检查。受控命令、可信副本、独立核心 job 与检查记录 v2 已串联，通过普通用户域的成功清理、持久化边界强退、核心拒绝/超时和异常状态保留验证；正常代理会话和 DNS 事务仍待接入。开发记录包含当前 Apple Silicon 系统上的原生构建、早期基础窗口操作、Go 测试、真实 Swift→Go 设置与资源操作、正式核心/规则数据下载、模拟 WARP 注册及独立 Keychain 验证；最新页面与顶部栏交互、真实 WARP 注册及凭据升级授权、root 安装与真实连接/网络恢复、产品 DMG 更新、macOS 13 和 Intel 验收仍未完成。配置解析不证明规则提供者下载或实际网络路径通过，已有骨架不等于本计划中的原生界面和核心功能已交付。

本次修订明确由 Codex 全权承担开发，计划仅按依赖、交付物和验收结果组织；三类原生顶部入口均列为首版必交付项，并补齐现有代码落点、主窗口与辅助窗口的关闭区别及对应验收。修订核对现有计划与原生应用入口，并查阅 Apple 的菜单与工具栏资料；设计要求本身不构成实现或测试通过声明，实际开发结果与证据另记于进度文档。

当前建议是独立原生 Mac 入口、共用 Go 业务和 Swift 系统服务。能否按上述范围完成无证书安装、自动更新和可靠网络恢复，必须由 P0 的真实原型确认；Intel 与热点继续按各自验证结果决定支持声明。
