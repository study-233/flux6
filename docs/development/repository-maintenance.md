# FreeV6 仓库整理进度

本次执行范围为 P0–P4：保存开发基线、分离签名与缓存、统一平台目录、删除已废弃内容、完善开发与 CI。Mac、Android 继续现有开发；Windows 保留现有功能，后续另做自定义 UI 重构。iOS、OpenWrt 只建立说明与待办。

| 阶段 | 状态 | 交付与验证 |
| --- | --- | --- |
| P0 保存基线 | 完成 | `chore/repo-baseline` 分支；签名材料已在仓库外备份并逐文件校验；检查源码与现有测试。 |
| P1 整理产物 | 完成 | Android 签名迁出、分级清理、历史产物整理。 |
| P2 建立结构 | 完成 | 公共资源归位；迁入 `apps/macos`、`apps/android`、`apps/windows`；新增 iOS、OpenWrt 占位。 |
| P3 删除旧内容 | 完成 | 删除旧 SwiftUI 入口、无效平台包装与上游工具；合并当前文档。 |
| P4 完善管理 | 完成 | 统一分支、版本、构建与 CI；干净源码验证；本地主线收敛。 |

## P0 基线

起点为 `mac` 分支的 `2b5a1c0`。现有未提交业务修改一并保留，分别按公共业务、Mac、Android、Windows 与文档形成基线提交。该快照表示可恢复的开发状态，不表示所有平台已经完成实机验收。

2026-11-10，Android 的 `preview.jks`、密码，以及 Mac 本机签名钥匙串、密码、公钥证书已备份到用户 Library 下的 FreeV6 Development 私有目录；备份不进入 Git 或分发源码。移动签名目录前仍保留原文件。

根忽略规则调整为只忽略根 `.agents/`，使 Android 已引用的项目规则可以随源码保存。测试夹具中的示例证书属于上游测试数据，保留其来源；真实签名材料不进入源码。

## 执行约束

- 不使用 `codex/` 分支；P0–P4 本地整理阶段不推送，后续远端整理按单独授权执行；不发布新的发行版。
- 删除历史源码后由 Git 历史保留，不建立永久 `legacy/` 副本。
- 目录迁移同步更新脚本、模块引用、打包材料和文档；每个平台独立验证。
- 真机联网、系统权限与安装升级不能用编译成功替代，未执行的检查明确记录。

P0 验证：Android 静态检查与 29 项相关测试通过；Swift 执行 193 项测试、19 项因环境条件跳过，其余通过；Windows 模块与图标检查通过。根 `go test ./...` 会进入本地 SDK 缓存，后续统一限定 `./cmd/... ./internal/... ./mobileapi/...`。基线提交只保存现有开发状态，不宣称完成真机验收。

## P1 结果

Android 签名已迁到仓库外私有目录，原钥匙库可读取且文件校验一致；缓存中的旧副本已移除，P0 备份保留。清理工具提供 temporary、compile、toolchains 三组，默认只列清单；执行前拒绝符号链接、签名文件和被进程占用的目标。7 项保护性测试通过。

保存 112 份历史报告后删除 8.42 GiB 旧探针产物及已解压压缩包。工具链和当前构建保留；Mac 0.5.2–0.5.5、Android 0.1.0 的旧包及对应源码移至 `dist/archive/`，当前与上一版留在平台分发目录。Go 源码基线中，公共库和 mobileapi 通过，Windows helper 的 `TestStartProxyBlockedWhenCloudLocked` 在解锁后进入真实 Geo 数据下载并超时；P4 将在解锁后设置明确的本地失败条件，完善测试隔离，不据此修改产品联网行为。

## P2 验证

平台源码与公共资源完成迁移，所有 Swift 测试通过（环境跳过项同 P0）；Mac Flutter 静态检查与 30 项测试通过；Android 静态检查、29 项 Flutter 测试、嵌套 Go 测试与 vet 通过，ARM64 Release APK 编译成功。APK 签名指纹与原 0.1.2 包一致。Windows 模块、图标、发布来源及包资源静态检查通过，Windows 安装包仍需对应系统验证。

Mac 正式本地应用已完成 Flutter/Swift/Go 组合构建、签名和打包校验，产物仍为 `dist/macos/FreeV6.app`；未启动应用或改动系统网络。

## P3 结果

移除旧 SwiftUI 产品、25 个页面/应用文件及专用夹具；删除 Android 附带的桌面 Runner、上游网站、发布脚本、重复工具配置和仅验证这些旧打包器的测试。保留仍供公共 Dart 与主机测试使用的插件、核心及 hooks。合并当前 XPC v6 的资源、配置与会话说明后删除 v2–v5 文档；早期设计与冗长开发日志由 P0 Git 基线保留。

Android 静态检查与 62 项相关 Flutter 测试通过，删除后 ARM64 APK 构建通过；Swift 测试通过，环境跳过项保持明确记录。旧历史记录链接已指向当前验收索引。

## P4 结果

新增统一开发指南、平台版本读取与一致性检查、目录/链接/第三方来源检查；Android APK 与对应源码按版本和 build 存放。完善 Linux/Windows Go、Windows Rust/Web、Android Go/Flutter/Kotlin/APK 和 Mac Swift/Flutter/App CI，iOS/OpenWrt 不添加构建任务。Windows 发布标签新增 `windows-v*`，兼容既有 `v*`。

修正 helper 测试的隔离条件后，根 Go 源码测试与 vet 通过。Android 224 项 Flutter 回归测试和 Kotlin 单元测试通过；维护保护 7 项通过。其中 Kotlin 为 100 项，均无失败。

干净 Git 源码快照发现根 `state/` 忽略规则误排除了 Android 的 7 个业务文件，已改成 `/state/` 并补齐源码；Android 文档忽略也限定到本平台根目录。Gradle wrapper 随源码固定保存；新增源码包输入必须被 Git 跟踪的检查，自动生成的插件注册文件由构建生成、不进入源码包。

最终验证：

| 项目 | 结果 |
| --- | --- |
| 根 Go 源码测试、vet | 通过；干净 Git 源码副本再次通过测试 |
| Android 嵌套 Go 模块 | 干净源码中的 test、vet 通过 |
| Android Flutter | 224 项回归通过；工作区与干净源码静态检查通过 |
| Android Kotlin | app 74 项、service 26 项，通过 |
| Android APK | 原工作区与干净源码副本均完成 ARM64 Release 构建 |
| Android 签名 | 正式测试包仍为 `dev.freev6.mobile`，与原 0.1.2 包证书 SHA256 一致 |
| Swift | 193 项，无失败；9 项需要额外运行环境的测试跳过 |
| Mac Flutter | 干净源码静态检查和 30 项测试通过 |
| Mac App | Flutter/Swift/Go 组合构建、原本机身份签名、打包校验通过 |
| 维护与 Windows 静态检查 | 7 项维护测试、126 个 JS 模块、45 个图标、发布来源、版本、资源路径、源码跟踪、文档链接及工作流 YAML 解析通过 |
| 对应源码 | Android 源码包与 APK 校验文件通过；Mac 源码包与 App 内嵌摘要清单一致 |

Android 本地产物为 `dist/android/0.1.2-b2026111003/`；Mac 应用为 `dist/macos/FreeV6.app`，对应源码为 `dist/macos/0.5.7-b6/`。这次是整理后的本地构建，未升级产品版本、未替换已发布资产。

本地阶段分支顺序合入 `main`，只删除已完全合并的 `mac` 与本次任务分支。所有基线和整理提交仍在主线历史中；不推送、不修改远端。当前主线规则及后续命令见 [开发指南](README.md)。本次独立验证创建的临时源码副本在结束后清除，日志保存在 `build/repository-maintenance/`。

验收边界：未触发远端 GitHub Actions；Windows 原生 Rust/NSIS 构建与安装仍须 Windows runner；Mac 托管 CI 需要 arm64 和 Xcode 27+。未执行管理员服务安装、真实校园网络连接、手机真机 VPN 或 macOS 14 实机测试。Windows 自定义 UI、iOS、OpenWrt 没有启动实现。

## 远端整理（R0–R5）

2026-11-10，按后续授权完成远端备份、正常历史合并、旧分支清理、仓库信息与缓存整理。远端只保留 `main`；[PR #1](https://github.com/study-233/free-v6/pull/1) 的 6 项检查全部通过，包括 Mac App、Android APK/Kotlin/对应源码包，以及 Windows runner 上的 Rust 编译检查。删除 13 份过时或已合并任务专属缓存，释放约 5.96 GiB，保留主线有效缓存和运行记录。

主线保护、禁止新建 `codex/` 分支、日志/附件保留周期、备份位置及验证范围见 [远端整理记录](remote-maintenance.md)。上文 P0–P4 的“未推送、未触发远端 Actions”仅描述当时本地阶段；本节为其后续结果。正式发行、Windows 自定义 UI、新平台实现及真实网络验收仍未执行。

## 远端 Actions 精简

后续按用户要求取消重复的远端客户端构建，移除 Mac/Android 完整 CI 和 Windows 标签打包，改为单个 Ubuntu `checks` 任务：始终运行仓库/Web 静态检查，按路径决定是否执行共享 Go test/vet，5 分钟超时。主线门禁相应简化，平台完整验收改在本地执行；历史整合验证结果继续保留。当前配置见 [开发指南](README.md#ci-与验收边界)。

## 本地历史产物二次清理

2026-11-10，按用户追加要求清理 P1 后保留的历史 UI 测试应用、探针工作目录、截图/日志、空临时目录、上游参考克隆和旧版本分发归档，共删除 259 个顶层目标，释放约 3.06 GiB。上游参考克隆的固定版本已保存在正式组件来源记录中，检查确认没有未提交源码修改；生成的 Gradle 缓存随参考克隆一起删除。

`dist` 从约 577 MiB 降到 125 MiB，只保留 `dist/macos/FreeV6.app`、`dist/macos/0.5.7-b6/` 对应源码以及 `dist/android/0.1.2-b2026111003/` 的 APK、对应源码和校验文件。同版本但仍使用旧目录布局的历史产物也已删除。

发现 `build/account-automation/signing-fixture` 中仍有历史签名材料，先迁到仓库外私有备份 `FreeV6/Development/backups/local-cleanup-20261110T063933Z/historical-macos-signing-fixture/`，4 个文件逐一比对摘要，目录权限 0700、文件权限 0600，然后删除工作区旧副本。当前 Mac/Android 正式本地测试签名和原有备份保持原状。

保留当前工具链、依赖与编译缓存、Android 模拟器、设计参考、当前测试使用的固定核心/规则数据及维护记录。删除前复查 Git 跟踪、文件占用和 launchd 引用，没有停止用户进程。删除后保留分发产物的 146 个文件摘要一致，Android APK/源码校验通过，Mac 对应源码 621 个文件与应用内清单一致，仓库结构检查通过。本次未更改产品源码、未重新构建或启动网络。逐项清单与校验记录位于本地 `build/repository-maintenance/local-cleanup-*.json`。

## 上游同步（2026-11-10）

从本地主线 `5cd2fec` 创建 `chore/sync-upstream-20261110`，合并 `evansrrr/free-v6` 的 `bcf3819268fa9a9202111e227e75e01e2338f154`，包含上次共同基线 `c528f26` 之后的 13 条上游提交。使用保留双方历史的合并提交，验证后快进本地主线；本次不推送、不创建发行版。

同步内容包括 Windows helper 动态回环端口、单实例与残留进程识别、失败日志、权限与网络快照的 Win32 调用、分阶段热点/DNS 恢复、停止后的状态竞态修复，以及备用配置 HTTP/1.1 直连、暂时性失败重试、UDP 防直连兜底。

冲突处理与保留范围：

- 将上游 `web/`、`src-tauri/` 的更新落在现有 `apps/windows/`；旧根目录 Tauri 配置保持删除，只将版本更新迁入当前配置。Windows Cargo/Tauri/Web 版本同步到 0.5.3；Mac 0.5.7-b6、Android 0.1.2-b2026111003 保持原版本。
- 保留多平台 README、Mac/Android 源码与 UI、XPC/worker 协议、共享夹具、第三方源码/许可证及来源记录。未实现 iOS 或 OpenWrt。
- 保留 `study-233/free-v6` 的公告、下载与反馈来源、公开 `profiles/` 路径和发行方缓存隔离；`notice.json` 保持备用配置关闭、空公告列表。协议与隐私新增内容按本发行版的公开配置来源和 Mac 脱敏日志策略调整。
- 备用配置网络修复放入 `internal/app`，Windows helper 与 Mac worker 继续共用实现。保留调用方 context 取消、数值 HTTP 状态脱敏和失败不覆盖已有配置；Windows 单独接入本地失败日志，Mac 不落完整入口。UDP 兜底扩展到 Windows，同时保留已有 Mac 规则和校验契约。
- 上游分类测试迁入共享层，新增瞬时失败/响应中断重试、重试次数上限、取消、DNS/证书错误、访问门禁、大小上限、错误脱敏测试。新增 Windows 前端隔离测试覆盖动态端口、旧壳回退、token 更新重试和停止后的过期状态响应。

验证结果（本地日志：`build/upstream-sync-20261110/`）：

| 项目 | 结果 |
| --- | --- |
| 共享 Go | `go test -timeout=180s ./cmd/... ./internal/... ./mobileapi/...`、`go vet` 通过；Mac worker 相关 race 检查通过 |
| Windows Go | windows/amd64 全部根源码测试包交叉编译、vet，以及 helper/CLI 构建通过；未执行 Windows 测试二进制 |
| Linux Go | linux/amd64 根源码范围构建通过 |
| Android Go | 嵌套 `apps/android/core` 的 test/vet 通过；android/arm64 `go build ./mobile` 通过，包含共享业务依赖 |
| Android Flutter | pub get、analyze 无问题；FreeV6、core、本地化与引导相关 224 项回归通过；源码和锁文件无变化 |
| Mac Swift/worker | Swift 共 193 项，0 失败，初次 17 项因夹具/环境跳过；已有固定资源补跑后，其中 4 项集成测试通过，剩余 13 项仍未执行。真实 worker 协议/持久化/退出探针通过，测试子进程全部退出 |
| Windows Web | 4 项 `node --test scripts/windows/test-web-runtime.mjs` 通过；app.js 语法、126 个模块与 45 个图标检查通过 |
| 仓库检查 | 7 项维护测试、版本一致性、目录/文档链接/源码跟踪/第三方来源、发布来源和 Git diff 空白检查通过 |

首轮 Go 检查发现合并新增日志函数缺少 `fmt` 导入，补齐后完整 test/vet 通过。Windows 新依赖 `golang.org/x/sys v0.47.0` 获取后完成交叉编译。

验证边界：当前是 Apple Silicon Mac，未执行 Windows 原生 Rust/Tauri 编译、NSIS 打包、安装和 Win32 运行测试；本机 Rust 工具链也未安装 rustfmt，未将语法解析当作 Rust 编译验证。未重建 APK 或 Mac 分发 App，未做真机 VPN、系统服务安装、真实校园网络、最低系统版本验收，未改动用户网络或停止用户进程。Mac 仍跳过的测试涉及额外进程/服务夹具及临时 Keychain 条件，不将跳过计作通过。

### 后续远端交付

同日按用户追加授权，将同步提交 `f94c1ab` 推送到自有仓库的 `chore/sync-upstream-20261110`，通过 [PR #4](https://github.com/study-233/free-v6/pull/4) 交付。上文“不推送”描述的是此前本地阶段，本节为后续远端操作的记录。

核验 `main-protection` 要求分支与主线同步、GitHub Actions 的 `checks` 成功，禁止删除主线及非快进强推，没有绕过权限。使用普通 merge commit 保留上游和本仓库历史，合并后清理任务分支并同步本地 `main`。PR 检查与合并后主线 CI 均需确认成功，最终合并 SHA、运行链接及检查结果保存在该 PR 与 [CI 运行记录](https://github.com/study-233/free-v6/actions/workflows/ci.yml)。

远端 `checks` 执行仓库/Web 静态检查和本次共享 Go test/vet；其成功不扩大上文平台实机验收范围，不触发安装包或正式发行。GitHub 连接器缺少 PR 写权限，写入操作通过本机已登录的 GitHub CLI 完成，未更改仓库保护或 CI 配置。

## Windows Flutter 重构准备 W0

2026-11-10，用户确认采用 Flutter + Windows 原生宿主替换 Web/Tauri，首期保留 Go helper、网络和权限实现；界面风格与页面结构对齐当前 Mac，保留 Windows 原有功能。用户有 Windows 电脑配合后续验证。

从已同步的 `main`（`81843cb`）建立 `refactor/windows-flutter-plan`，完成 [实施方案](windows-flutter-refactor.md)：功能矩阵、16 条 helper 路径、mihomo 控制器调用、原生宿主职责、WebView 偏好迁移、安装身份兼容、W1–W5 交付条件及 Windows 验收清单。同步 Windows README、开发入口和平台边界说明。

验证：仓库结构/文档链接/版本/来源检查通过；4 项现有前端隔离测试通过；126 个 JS 模块检查、`app.js` 语法和差异空白检查通过。准备阶段只改文档，未创建 Flutter Windows 工程、改产品代码、替换当前 Tauri 构建、升级版本或发布产物，未运行真实网络或停止用户进程。

验证边界：未执行 Windows 原生构建、安装、WebView 数据迁移及系统功能测试；这些属于后续阶段的完成条件。尤其不能将 helper 数据目录保留等同于 WebView 流量历史/壁纸已迁移，也不能将 Tauri NSIS hooks 直接当作 Flutter 安装器使用。

## Windows Flutter W1 源码与本机验证

用户授权按阶段实施，随后明确先在 Mac 写完源码，再由用户推送 GitHub、在 Windows 拉取编译验证。任务分支改为 `refactor/windows-flutter`；W0 文档提交为 `79cba11`。从 Mac 基线原样复制 209 个视觉/第三方文件，保留上游许可及补丁，并在 `b430e70` 单独提交机械复制。

新增固定 Flutter 3.47.6 的 Windows 工程、锁定依赖、独立预览身份、内存演示入口及 C++ 最小桥接。隐藏 `--host-probe` 提供后续 Windows Dart/C++ 往返验证；当前预览不启动 helper、不请求管理员权限、不操作真实用户数据。新增本机/Windows 检查脚本、第三方 SHA256 校验、只读旧安装信息收集脚本，以及带允许清单的界面偏好导出和解码契约。

本机验证：Flutter analyze 无问题，7 项 Dart/组件测试通过（含 1280×800 与 720×480 布局），2 项偏好导出 Node 测试通过，209 个固定来源及 1 项本地主题适配哈希核验通过。测试使用合成数据，Flutter 测试运行器因沙箱回环端口限制在授权环境运行，未启动实际代理。

W1 源码及本机检查完成，Windows C++ 编译、桥接探针、旧安装注册信息和真实 WebView 数据读取仍待用户在 Windows 验证；未将这些待验项计作通过。偏好迁移采用版本化导出/导入契约，W4 接入旧界面导出入口和新客户端导入；自动读取旧 profile 的路线尚未验证。按用户安排继续 W2–W4 代码，不切换正式入口。

## Windows Flutter W2 界面

完成 Mac 风格的侧栏、仪表盘、节点、配置、日志和设置面板，使用 Windows Ctrl 快捷键。页面通过独立 ClientModel 契约操作，演示实现仍只使用内存合成数据；包含热点、F6、自启、核心/WARP、外观、更新及旧界面备份入口。直连选项默认隐藏，开发者模式开放后才展示。

本机 Flutter analyze 通过；页面导航、配置 URL 错误、Windows 设置项和原有基础测试通过。额外生成明亮宽屏及深色紧凑窗口的所有页面与设置图，补齐测试渲染器的中文和图标字体后人工检查；产物保存在 `build/windows-flutter-visual/`，不打包本机系统字体。Windows 字体、DPI、原生窗口和系统功能仍待原生验收；本阶段界面使用演示模型，真实操作在 W3 接入。

核对旧 HTML 后修正准备文档：运行中的退出弹窗仅有“取消/停止并退出”，内部 `quitDirectly` 函数不代表存在可让用户保留连接直接退出的按钮。迁移按实际交互保留。

## Windows Flutter W3 真实接口与原生宿主源码

接入现有 helper 的动态回环端口/Bearer 接口和独立 mihomo 控制器凭据，覆盖连接、IPv6 门禁、启动重试、WARP、设置、热点状态、节点/测速、流量、核心下载、公告和更新。新增带备份恢复的界面偏好存储、导入/导出、动态取色、纯黑、壁纸、原生背景效果和季节反馈。状态代数丢弃跨设置写入、停止和分组切换的过期响应，测速并发上限 6。

新增 `live` flavor 及独立入口：C++ 宿主保留 `freev6-desktop.exe`、生产单实例 mutex、安装根路径、管理员 manifest、StartupApproved 门禁、静默启动、托盘和 F6。helper 使用每次启动随机 token、动态端口和私有环境块；只管理自身创建的子进程。退出/更新等待 helper 确认停止，更新再次校验固定缓存路径及 SHA256。默认演示入口和 `--host-probe` 不启动 helper。

Flutter analyze 与 23 项离线测试通过，包括两种凭据隔离、401 端口/token 刷新、设置保留/回滚、过期状态/节点/测速响应、6 路并发、失败停止阻止退出/更新、备份恢复及页面布局。Windows C++、DWM 背景回退、F6/托盘、管理员启动、安装器执行、真实网络和系统恢复仍待用户原生验证。本机没有运行 helper 或改动网络，也没有修改共享 Go 业务。

## Windows Flutter W4 迁移、打包与源码交付

新增旧 WebView 的独立 JSON 导出入口与复制兜底，只读取允许的 UI 偏好，不初始化另一套应用或访问 helper token。Flutter 接受旧 v1 备份及包含减少动态效果的 v2 备份，重复导入覆盖指定值、不累加流量。界面偏好写入串行化，损坏或缺失主文件时可恢复有效 `.bak`。已发布的旧二进制没有新增导出按钮时，仍需最后一版带导出入口的 Tauri 构建；没有宣称自动解析 WebView profile 或已完成实机迁移。

新增 Windows x64 构建脚本、独立 NSIS 安装器、只读进程占用检查、按本安装路径撤销自启、精确卸载文件清单，以及构建前后源码摘要一致性检查、许可证/Flutter notices/对应源码 ZIP/SHA256SUMS。默认保留 config/state/runtime 和旧 WebView；安装/卸载不会强杀代理。沿用客户端/helper 文件名、HKCU 卸载项及既有安装路径，系统范围旧安装明确停止迁移，留待实机确认。正式版本源和 Tauri 构建入口保留，未执行 W5 或发布候选。

收尾修复包含连续 Ctrl+数字切页的焦点保持、资源刷新/重新注册的过期状态保护、旧流量统计基线、公告链接与未读标记、启动失败后的组件重连、原生资源绝对路径，以及 Flutter 3.47.6 flavor 实际产物目录。视觉回归增加页面内容断言，确认抓到的是各自页面，而非仅检查未溢出。

最终本机验证：

| 检查 | 结果 |
| --- | --- |
| Flutter | analyze 无问题，30 项离线 Dart/界面回归通过 |
| 视觉 | 1280×800 明亮、720×600 深色且 1.3 文本缩放，全部页面与设置截图检查；截图保存在 `build/windows-flutter-visual/` |
| 旧 Windows Web | 4 项原接口测试 + 3 项偏好导出测试通过；127 个 JS 文件与 45 个图标检查通过 |
| 源码打包 | 2 项合成夹具测试通过：允许清单、许可/源码归档及构建后源码变化阻断；不运行夹具二进制 |
| 固定来源 | 209 个来源文件、4 项已登记视觉适配摘要通过；固定源码采用 LF，避免 Windows checkout 换行影响校验 |
| Go helper | `GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -buildvcs=false` 成功，产物确认为 Windows x86-64 PE；未执行该二进制 |
| 仓库 | 7 项维护测试、结构/文档/版本检查与 Git 差异空白检查通过 |

Windows C++ 编译/宿主探针、PowerShell/NSIS 执行、UAC/托盘/F6/DWM、旧安装/升级/卸载、实际偏好迁移、下载更新和真实校园网络仍待用户在 Windows 验证。Mac 没有 Windows 原生工具链，未把源码审查、Dart mock 或 Go 交叉编译计为这些测试通过。未改共享 Go、Mac、Android 源码，未启动真实 helper/代理，未停止用户进程。用户自己的 `output/` 品牌产物未修改或纳入提交。

交付步骤见 [Windows Flutter 验收手册](windows-flutter-acceptance.md)。本轮仅本地提交；按用户安排由用户随后推送 GitHub、在 Windows 拉取编译。W1–W4 源码与本机检查已完成，W5 正式切换和旧代码删除等待原生验收。

## 2026-11-10 小猫图标统一接入

按用户确认的造型绘制并细修五款 SVG，最终默认改为奶牛猫；其余为橘猫、炫彩猫、四色猫、地球猫。共用身体、前爪、五官和单弧尾巴，保留渐变，修正花纹接缝、耳朵切角、前爪色块台阶和尾根凸起。资源与清单位于 `assets/branding/cats/`；SVG 生成和平台导出脚本位于 `scripts/branding/`，共享 `icon.svg`、PNG 与 ICO 均采用奶牛猫。

Mac 设置增加五款选择，通过现有宿主偏好保存，更新 Dock 图标；Android 主题页增加选择器，通过系统 launcher alias 保存和切换桌面入口，关于页同步显示；Windows Tauri 设置更新窗口、托盘、侧栏及本地选择。Android 仅切换入口别名，不禁用真实 MainActivity，不调用 VPN 生命周期，切换失败保留原有选择。Windows 安装包与快捷方式、Mac Finder 图标保持默认奶牛猫。当前 Windows Flutter 重构在另一个活动分支进行，本分支不修改其尚未提交的界面和后端。

平台资源从 SVG 导出，包括 Mac AppIcon、Android 手机/TV、自适应与单色资源、Windows helper 嵌入图标。Android 自适应图标保留圆形遮罩安全区；Mac/Android 对应源码包包含 SVG 和生成脚本。构建、测试日志位于本地 `build/branding-review/`。本任务临时 worktree 被外部清理后，从已保存 SVG 和本任务操作记录恢复到仓库内 `.worktrees/cat-icon-themes`；任务改动与当前 Windows 重构工作目录隔离。

验证完成：五款 SVG 与用户确认版本逐字节一致；16/32/64/256/512/1024 像素共 30 次渲染的 alpha 轮廓一致且外圈透明；ICO 的 7 档尺寸有效。Mac 与 Android Flutter analyze 无问题；Mac 设置/无障碍 8 项、Swift 默认值/保存/非法值 1 项、Android 图标/本地化/规范/遮罩 34 项、Windows 选择及失败回退 3 项通过。Mac Flutter 原生 Debug 宿主构建通过；Android `compileDebugKotlin` 和 `processDebugResources` 通过，合并 Manifest 的 5 个 alias 均指向保持启用的 `com.follow.clash.MainActivity`。固定 `go-winres v0.3.3` 已重绘 Windows helper 的 `.syso`，Windows/amd64 helper 交叉编译通过。Web 127 个模块、45 个界面图标与发行来源检查通过。

扩大 Android `test/widgets/` 回归时，1035 项通过，旧更新功能 3 项失败；在未修改 Android 的原工作区复现同样的更新包校验和缺失更新按钮失败。两组测试随后均等待未完成的更新夹具，本任务仅中断记录过 PID 的测试进程；关闭测试通道的额外报错不计为产品回归通过或新失败。完整广泛回归未通过，不以本次相关检查替代。

验证边界：未运行 Windows Rust/Tauri 原生编译或 NSIS 打包，未进行 Android 真机桌面图标缓存验收或真实 Mac Dock 点击验收。未创建正式发行版、覆盖已安装应用、启动真实代理或停止用户进程；iOS/OpenWrt 保持占位。当前源码和可构建资源位于独立任务分支 `feat/cat-icon-themes`。

## 2026-11-10 图标分支合入 Windows 重构分支

按用户要求，将 `feat/cat-icon-themes` 的 `0872bce` 合入当前 `refactor/windows-flutter`（合并前 `5a13b42`），保留双方提交历史。维护记录的追加冲突保留双方完整阶段；Web 页面保留旧版偏好导出与新增图标选择入口。同步 Windows Flutter Runner 的 ICO 为共享奶牛猫默认图标，并将品牌生成脚本纳入 Windows 对应源码包。当前 Tauri 的五款选择功能保持生效；Flutter 候选继续遵循原有验收与正式入口切换计划。

合并后验证：仓库结构/版本/来源检查、7 项维护测试、2 项 Windows 源码打包测试、209 个视觉来源及 4 个补丁哈希、128 个 JS 模块、45 个界面图标、发行来源检查均通过；图标选择/旧偏好导出/Web 运行时共 10 项 Node 测试通过，Windows Flutter analyze 无问题。确认默认清单和共享 SVG 均指向奶牛猫，Flutter Runner ICO 与共享 ICO 逐字节一致，Web 中图标选择与偏好导出入口并存。本次未重复未改动的 Mac/Android 平台构建，既有 Windows 原生验收边界继续适用。
