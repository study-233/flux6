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

## 2026-11-10 GitHub 交付准备

用户追加授权将全部本地代码改动提交到自有 GitHub 仓库，并清理无用分支，替代此前仅本地提交的安排。Windows Flutter W1–W4 与小猫图标已汇入 `refactor/windows-flutter`，保留各阶段提交历史。刷新远端后确认本分支包含最新 `origin/main`，主线要求 GitHub Actions `checks` 成功且分支与主线同步，不绕过保护规则。

唯一未跟踪目录 `output/` 为图标导出与预览副本，现加入忽略列表并原地保留；其中最新五款 SVG、PNG、预览和默认奶牛猫清单均与已跟踪的 `assets/branding/cats/` 逐字节一致，生成脚本也已纳入 `scripts/branding/`。导出 ZIP、旧版预览和构建缓存不重复提交。清理仅针对已经合入主线的任务分支，工作树中的本地构建与验证资料保留。

本次交付不创建正式发行版或切换 Windows 正式构建入口。各平台原生验收边界及 Android 广泛回归的已知失败仍以上述记录为准；推送与主线合并的最终提交、检查结果以 GitHub PR 和 CI 运行记录为准。

## 2026-11-10 首个公开正式版文档准备

用户确认首发范围为 macOS 与 Android，安装验收及 Android 真机验证已经完成；明确 macOS 不进行 Apple 公证，按公开正式版准备，并要求准备完成后先交用户验收，不得擅自发布。以上实机结论来自用户确认，本次没有补做或代填真机测试，历史记录继续保留当时的边界。

从 `main` 的 `6621133` 建立本地 `release/first-public-docs` 分支。README 精简为品牌、界面、安装、致谢、MIT 与 Star History，推荐 macOS Homebrew 并保留 DMG/Android APK 下载入口；首页引用现有 macOS 离线窗口截图，原图来自隔离 QA 宿主，来源在发布准备文档注明，未使用测试测速数值作为性能宣传。没有可核实来源的 Android 真机截图，未用模拟器或上游图片冒充。

新增 [首发准备](../releases/first-public-release.md)，记录用户决定、当前版本与拟用标签、Homebrew 分发要求、About 草稿、两端正式 Release 文案及上线顺序。同步 Mac/Android 开发入口、Mac 验收索引与更新说明：Apple 公证不是本次发布条件，代码签名与完整性校验继续保留，应用内签名更新通道和 Homebrew 分发分别准备。第三方许可证、版权与对应源码要求保持原样。

本轮为文档交付，没有修改产品版本、构建脚本或应用内预览标识，也没有重新构建安装包。现有带 `preview` 文件名的本地产物不作为新正式包；最终构建、发行命名和带真实 DMG SHA256 的 Cask 仍在打包阶段处理。README 中的 Homebrew 命令为发布后入口，需与 Tap 和 Release 就绪后同步公开；About 保存在本地草稿，尚未修改远端。

验证：仓库结构、文档本地链接、平台版本、固定第三方来源与源码打包输入检查通过，Git 差异空白检查通过。文档改动未触发 Go、Swift、Flutter 或 Android 编译测试，未运行真实代理、停止用户进程或覆盖安装。未创建远端标签、Release 或 Homebrew 仓库，未上传发行资产、推送改动或更新签名通道。

## 2026-11-10 首个公开正式版本地打包

用户继续授权准备 macOS DMG、Android APK 与 Homebrew Cask，清理预览版标识，完成后先验收、不发布。沿用 `release/first-public-docs` 本地分支，将 Mac build 递增为 7、Android build 递增为 2026111004，保留两端版本号 0.5.7 / 0.1.2。此前文档阶段的“未生成产物”状态由本节和 [首发交付清单](../releases/first-public-release.md) 更新。

Android 七种 ARB 的简介、首次引导、手动更新提示统一移除测试版文案，通过 `intl_utils` 重新生成翻译代码，关于页改用 `freev6ManualUpdates`。构建显式指定 `APP_ENV=stable`，正式 APK 与源码归档去掉 `preview` 文件名。Mac 随包安装说明改为正式版，移除等待公证的内容；系统 DNS 操作的内部显示名称去掉 preview。隔离开发宿主保留原身份，网络、权限和服务生命周期实现未改变。

Mac 构建脚本新增 `FREEV6_APP_OUTPUT`，正式 App 构建到独立的 `dist/macos/0.5.7-b7/FreeV6.app`，没有替换旧 `dist/macos/FreeV6.app` 或系统安装。DMG 脚本按版本/build 生成 DMG、应用 ZIP、与 App 内摘要严格匹配的完整源码 ZIP 及 SHA256SUMS；两端归档脚本增加同名输出保护。Android 交付目录为 `dist/android/0.1.2-b2026111004/`。

首次签名对比发现当前主机缺少此前记录的私有签名和备份，构建器生成了新身份。用户明确确认“使用新签名作为首个正式版身份”。新 Android 证书 SHA256 为 `f6cbcb4aa014f1c09785a00342cd5a47f9d8bde90e52a11676c14e7fa9d0bf7c`，Mac 证书为 `d04a87b6c995a867aa0f087c09fc7e55692758d1ea52c85228493dfac03e1e70`。两端私有材料备份到仓库外 `~/Library/Application Support/FreeV6/Development/backups/first-public-20261110/`，核验目录 0700、文件 0600；未上传密钥、口令或备份。首发说明明确旧 Android 测试版不能覆盖安装、卸载会清除数据，Mac 旧钥匙串可能重新请求授权；后续发行须复用本次身份。

新增 `packaging/homebrew/Casks/freev6.rb`，版本为 `0.5.7,7`，绑定固定标签 `macos-v0.5.7-b7` 和真实 DMG SHA256，声明 arm64/macOS 14 最低要求，仅安装 App。没有自动关闭 Gatekeeper、清除隔离属性、移除用户配置或执行网络服务操作。Tap 尚未创建，远端 URL 尚未上线。

验证结果：

| 范围 | 结果 |
| --- | --- |
| Swift | 194 项中 175 通过、19 因额外进程/服务/Keychain 夹具条件跳过，0 失败 |
| Android | Flutter analyze 无问题；本地化、动态消息键、FreeV6 业务及引导共 22 项测试通过；ARM64 Release APK 构建成功 |
| Mac 分发 | DMG 只读挂载、拖放副本及 ZIP 解压复验通过；签名、Hardened Runtime、架构、最低系统、服务摘要与生产宿主检查通过 |
| Android 分发 | APK 签名有效，包 ID `dev.freev6.mobile`，versionCode 正确，只有 arm64-v8a 原生库且不可调试 |
| 对应源码 | Mac 667 个输入与 App 内清单/源码 ZIP 逐项一致；Android 2721 个输入构建前后不变且与源码归档一致 |
| Homebrew | Ruby 语法、DSL 解析及离线审计通过；未安装 homebrew/core，排除依赖该目录的 token_conflicts 检查；未运行在线下载、公证或安装检查 |
| 仓库 | 7 项维护保护测试、结构/文档/版本/来源检查、图标、发布来源和差异空白检查通过 |

所有发行摘要已复算，Mac App 内证书与持久签名证书一致。验证报告和日志位于 `build/first-public-release/`；中间生成的非 stable Android 构建保存在该日志目录，不属于交付物。当前 App/安装包是独立的待验收产物，本轮未运行真实代理或 VPN、替换用户应用、安装系统网络服务、停止用户进程或重新执行真机联网验收。未推送提交、创建远端标签/Release、上传资产、上线 Tap、修改 About 或更新签名通道。


## 2026-11-10 首发 macOS 异常启动退出修复

用户在首发验收中反馈关闭按钮及退出入口都会提示“退出前恢复未完成，已有安装文件不完整”。只读进程路径和界面检查确认，当前运行的是 `build/macos-release-runner` 中的 Xcode 中间 App，缺少最终打包时补入的助手、协议与隐私文档；正式 DMG 内的 App 已包含这些文件。此前按同名应用检查界面时未区分中间包与最终产物，后续验收使用明确的最终路径。

根因是 `settleNetwork` 在退出前重新检查服务安装，直接向上传递不完整安装错误，连未持有网络会话的首次启动窗口也被阻止退出。现仅在普通退出、未持有会话且错误明确为安装不完整时放行；保留已有会话的恢复检查、其他服务错误与升级前校验。四项隔离回归在修复前复现同一失败，修复后全部通过，涵盖异常退出、已有会话保护、升级保护和重开时发现遗留会话的恢复。

Mac 递增为 0.5.7 build 8，新的 DMG、应用 ZIP、对应源码与摘要保存于 `dist/macos/0.5.7-b8/`，Cask 与首发文档更新为新版本和实际 DMG 摘要。新增 `FREEV6_RUNNER_WORK` 以独立目录重建，不覆盖当前运行的中间 App；旧 build 7 产物保留。继续复用用户已确认的首发签名身份。Android 产物未改动。

验证：Swift 198 项中 179 通过、19 因额外夹具条件跳过、0 失败；7 项维护测试和仓库结构检查通过。新 DMG 的只读挂载、拖放副本、签名、架构、最低系统、服务摘要和 ZIP 复验通过，668 个源文件与包内清单及源码 ZIP 一致。Homebrew 继续只做离线解析和审计，排除需要本机尚未安装的 homebrew/core 的 token_conflicts 检查。证据位于 `build/first-public-release/macos-b8-*.log` 和更新后的 `verification.json`。

验证边界：本轮没有重新执行真实网络、管理员安装或 Android 真机测试，没有替换已安装 App、停止用户进程或更改现有系统服务；新包的实际关闭与退出交互仍交用户验收。未提交、推送、创建标签或发布版本。


## 2026-11-10 首发版本统一为 0.1.0

按用户要求将 macOS、Android 的首个公开正式版本统一为 `0.1.0`。为保持升级次序，平台内部构建号递增为 Mac `9`、Android `2026111005`；拟用标签为 `macos-v0.1.0-b9` 和 `android-v0.1.0-b2026111005`。Windows 版本及 iOS/OpenWrt 占位不变。保留此前异常安装退出修复、正式包标识与用户确认的首发签名；旧验收包原地保留。

同步权威版本清单、Mac 随包安装说明、平台开发入口、首发 Release 文案和 Homebrew Cask。重新生成两端正式安装包与对应源码，分别位于 `dist/macos/0.1.0-b9/`、`dist/android/0.1.0-b2026111005/`。Mac 构建使用独立 Runner 工作目录，未覆盖已安装或运行中的 App。

验证：两端 Release 构建成功；Android 静态分析无问题，APK 的 `versionName=0.1.0`、`versionCode=2026111005`、正式签名与 ARM64 非调试属性核验通过，2721 个源文件在构建前后与源码包逐项一致。Mac 版本为 `0.1.0 / 9`，协议文件完整，签名身份与已确认的首发证书一致；DMG 只读挂载、拖放副本、ZIP 解包及签名、架构、最低系统和服务摘要校验通过，668 个源文件与包内清单及对应源码一致。4 项退出回归和 7 项维护测试通过；此前 198 项 Swift 回归（179 通过、19 跳过）及 22 项 Android 相关测试的记录保留，本次仅版本元数据调整，没有重复未受影响的完整测试。

Cask 的版本、固定标签 URL 与新 DMG 实际 SHA256 已同步，继续进行 Ruby 语法、Homebrew DSL 解析与离线审计；未安装 homebrew/core，仍排除依赖它的 token_conflicts 检查。检查报告保存在 `build/first-public-release/verification.json`，本轮日志使用 `*-010-*` 文件名。

仍等待用户验收。没有执行公证、真实联网或管理员安装，没有提交、推送、创建远端标签、发布 Release、上线 Tap、修改 About 或启用更新通道。


## 2026-11-10 精简首发 Release 正文

按用户要求将 macOS、Android 的公开 Release 正文分别整理为 `docs/releases/macos-v0.1.0.md` 和 `android-v0.1.0.md`，仅保留版本、系统支持、安装入口及旧 Android 测试版迁移这一必要说明。删除正文中的功能复述、SHA256 展示、附件清单、安全提示和内部发布流程；首发准备页改为链接这两份正文，并移除直接展示的安装包摘要。

本轮仅修改发布文档，安装包、源码包、校验文件和 Cask 的实际摘要均保持原样。文档链接与仓库检查通过；未重新构建或运行无关测试，未发布。


## 2026-11-10 加入 Android 首页实机截图

用户提供 Android 首页实机截图，原样复制为 `docs/images/android-home.jpg`，与现有 macOS 窗口截图在 README 中并列等高展示，点击可查看原图。同步首发准备页的素材来源和完成状态，移除缺少 Android 截图的过时说明。已核对原图与仓库文件逐字节一致、两张图片尺寸及 README 的本地图片链接。

本轮仅修改文档和图片，未改动应用行为、安装包、源码包或 Cask。既有源码包仍保留打包时的 README 快照，与当时的构建输入及 Mac 包内源码清单对应；新增截图在当前仓库首页展示。未发布。


## 2026-11-10 首发发布授权与预检

用户明确要求发布新版本，授权范围为此前确认的 macOS、Android 0.1.0 正式包、对应源码、精简 Release 正文、README 实机截图、仓库 About 及独立 Homebrew Tap。保留平台构建号、首发签名和不进行 Apple 公证的决定，不启用应用内更新通道。

远端 main 基线仍为 `6621133`，没有既有 Release 或冲突标签。主分支规则集要求 `checks` 且严格与 main 同步，按任务分支、CI、合并流程交付。再次核对正式产物及对应源码归档，全部摘要与已验收文件一致；构建后仓库仅增加截图与发布文档，应用代码和构建输入的非文档部分保持一致。归档保留构建时文档快照，发布标签包含后续 README 图片及发行记录。


## 2026-11-10 0.1.0 正式发布完成

退出修复与首发整理分别提交为 `fb8438e`、`a30142b`，通过 [PR #6](https://github.com/study-233/free-v6/pull/6) 合入 main；PR 与合并提交的 `checks` 均通过。两个附注标签 `macos-v0.1.0-b9`、`android-v0.1.0-b2026111005` 均指向 `232f7b73ec6a3a7a9d120eddd4ad335b52358abf`。

[macOS 0.1.0](https://github.com/study-233/free-v6/releases/tag/macos-v0.1.0-b9) 与 [Android 0.1.0](https://github.com/study-233/free-v6/releases/tag/android-v0.1.0-b2026111005) 已公开，`draft=false`、`prerelease=false`；正文采用用户确认的精简内容，不展示 SHA256。两个 Release 共 8 个安装包、源码包与摘要附件，逐项核对 GitHub 返回的大小及摘要与本地一致后才公开。

已创建公开 [Homebrew Tap](https://github.com/study-233/homebrew-tap)，首个提交 `ce46948` 包含经审核的 Cask、安装说明与许可证；线上 Cask 与本地逐字节一致。匿名下载 DMG 的摘要与 Cask 匹配，Android APK 的匿名下载入口返回 HTTP 200。仓库 About 已更新为正式版描述、下载入口及七个主题，README 包含用户提供的 Android 首页截图。

验证资料保存于 `build/first-public-release/publish/`。本轮没有安装或启动产品、修改系统网络、进行 Apple 公证或启用应用内更新通道。发布后的本次提交仅同步文档结果，不移动发行标签或替换已发布附件。


## 2026-11-10 统一每版本一个 Release

用户纠正发布布局：同一软件版本只保留一个 Release，不按平台拆分。0.1.0 统一为 `v0.1.0`、标题 `FreeV6 0.1.0`，沿用原发布提交 `232f7b73ec6a3a7a9d120eddd4ad335b52358abf` 与已验收安装包；macOS build 9、Android build 2026111005 及签名保持不变。八个附件集中到同一页面，精简正文合为一份。旧平台标签作为构建历史保留，重复 Release 在附件完整核验后移除。

版本工具、Mac 更新包 URL、Homebrew Cask 与活动文档统一使用 `v<版本>` 规则；原平台构建号保留在资产文件名内。增加统一标签与更新下载地址的离线回归，连同 7 项维护测试共 9 项通过；仓库、发行来源及 Cask 离线检查通过。此次仅调整发行布局和打包工具，不重新构建或替换已发布安装包；历史源码归档仍对应原构建输入。


## 2026-11-10 精简公开附件与发布文案

按用户要求移除 Release 正文及活动发行清单中的旧 Android 测试版迁移提示。公开安装包统一采用 `FreeV6-0.1.0-macOS.dmg`、`FreeV6-0.1.0-Android.apk`；Mac 应用 ZIP 与两端对应源码也去掉 build 和架构后缀，源码保留 `-source` 标识。Release 不再提供三个 SHA256 校验附件，剩余五个正式附件。同步文档下载链接与 Homebrew Cask 的 DMG 地址。

仅调整现有 GitHub 附件名称和发布展示，不重新构建、重签或修改安装包及源码内容；本地构建目录、校验文件和签名记录保留，Homebrew 使用实际 DMG 摘要。仓库结构、发行来源与 Cask 语法检查用于核验本次文档和链接变更，不重复应用构建、安装或真实网络测试。

## 2026-11-10 Flux6 官网与品牌首页

用户要求借鉴 FlClash 官网并更换项目名，最终选定英文名称 `Flux6`。在 `feat/project-website` 分支新增 `site/` 与 `scripts/site/`，仓库 README 同步使用 Flux6。网页从 FlClash 固定提交 `be84736605527034689c95bf27828ff27d912c5e` 改编，保留上游 GPL-3.0 许可证、各原始文件 Git blob 和本地改动记录；来源入口见 [网站说明](../../site/README.md)及 [来源清单](../../site/UPSTREAM.json)。

沿用参考站的排版、暖灰配色、背景动效、双语与主题切换、下载标签页、更新日志搜索及键盘交互。改用仓库现有猫咪图标、macOS 隔离截图、Android 实机截图和实际功能介绍。公开下载只列 macOS Apple Silicon 与 Android ARM64，五个发行附件的名称、大小、SHA-256 按 GitHub v0.1.0 元数据核对。构建时嵌入发行数据与双语日志，无需浏览器访问 GitHub API；无 JavaScript 时仍保留安装链接及日志。网站构建无外部依赖，产物为 `dist/site/`，预览服务仅绑定 loopback。

官网明确注明当前 0.1.0 安装包仍使用 FreeV6 名称；本轮未改变应用显示名、包 ID、安装路径、签名、配置目录、Homebrew Cask、仓库 URL 或已发布资产，也未重打包客户端。iOS/OpenWrt 继续仅占位，Windows 未列为已发行下载。

验证：静态构建、JavaScript 语法、网站本地资源/链接、仓库结构、9 项维护测试、图标、发行来源、128 个既有 Web 模块和差异空白检查通过。内置及备用 CUA 浏览器连接超时后，用户明确授权 Playwright；在隔离 Chrome 中完成 320/390/768/1024/1440px 检查，无横向溢出、损坏图片或浏览器错误。验证下载 URL、命令/摘要复制、平台标签和键盘切换、搜索匹配/空态/Escape、双语与主题持久化、普通动画模式和禁用 JavaScript 的回退。视觉复查修复平台名在窗口改变后被旧像素宽度裁切的问题，改为字体相对宽度；最终桌面/手机截图与参考站联合对比通过。详见 [设计 QA](../../site/design-qa.md)，本地截图及检查结果位于 `build/site-qa/`。

验证边界：仅网页与文档改动，未重复 Go、Swift、Flutter、Android 或 Windows 构建；未启动实际客户端、代理/VPN，未停止用户进程或修改系统服务。没有提交/推送、创建 PR、注册站点、调整 GitHub Pages 或进行线上发布。

## 2026-11-10 Flux6 全平台品牌与 0.1.0 重打包

用户明确授权统一项目名、重新打包替换 0.1.0、部署 GitHub Pages 并更新 About。界面、菜单、七种语言、安装包、构建脚本、当前文档和发行来源统一为 Flux6；仓库目标名称为 `study-233/flux6`。保留应用 ID、原签名、钥匙串标识、服务名称、加密缓存命名空间及 Windows 数据/注册表路径。历史记录、上游署名与技术内部标识不做破坏性重命名。macOS 登录项补充旧名称识别与迁移，使用安全临时目录完成回归。

新正式包为 macOS 0.1.0 build 10、Android 0.1.0 build 2026111006。两端签名与已发布正式版一致；macOS DMG、应用 ZIP、源码 ZIP 与 Android APK、源码 tar.gz 均构建完成。668 个 macOS 源文件与包内清单及归档一致；2721 个 Android 输入构建前后及归档一致。原发布资产和元数据留存，不覆盖本地旧构建。

共享 Go 与 Android 嵌套模块测试/vet 通过；Swift 199 项中 177 通过、22 按夹具条件跳过、0 失败；Android analyze 及 19 项相关测试、macOS Flutter analyze/31 项测试、Windows Flutter analyze/30 项测试通过。仓库结构、9 项维护测试、45 项图标、发行来源、128 个 Web 模块、2 项 Windows 打包工具测试通过。官网改名后的五档宽度、交互及无 JS 回退复验通过。日志与摘要保存在 `build/flux6-release/`，浏览器记录在 `build/site-qa/`。

本轮仅构建、单元测试、隔离夹具及只读包验证，没有启动产品网络/VPN、执行管理员安装、停止用户进程或更换签名身份。Windows 源码品牌同步，但本机未进行 Windows 原生构建，也不发布 Windows 资产。Pages、Release 和 Tap 的线上结果在后续完成记录中补充。

## 2026-11-10 Flux6 发布与官网部署完成

[PR #10](https://github.com/study-233/flux6/pull/10) 已合入主线 `0a256d7bc28c68341c145318e76a03ad7b373f27`；PR 与主线 `checks` 均成功。仓库已改名为 [study-233/flux6](https://github.com/study-233/flux6)，本地 origin 同步更新。用户授权替换的 `v0.1.0` 标签现指向该合并提交；用原标签对象 `c1052ea3c0512a567f98e32f902d1a687ae71f3d` 的精确 lease 保护远端更新，原提交 `232f7b73ec6a3a7a9d120eddd4ad335b52358abf` 继续保留在历史记录和原平台标签中。

[Flux6 0.1.0](https://github.com/study-233/flux6/releases/tag/v0.1.0) 保持正式版与 Latest，现包含五个 Flux6 名称的新附件。先上传全部新文件并逐项核对 GitHub 返回的大小、SHA-256，再移除旧名称附件。匿名下载 DMG 的实际摘要与本地及 Cask 一致。旧五个文件和发布元数据仍保存在本地旧发行目录及 `build/first-public-release/release-before-flux6.json`，本轮未将私钥或口令上传。

[Homebrew Tap](https://github.com/study-233/homebrew-tap) 已更新至 `52d8f1c`，包含 Flux6 Cask、0.1.0/build 10、新 DMG 摘要、安装说明和 `freev6` → `flux6` 的迁移映射。Ruby 语法与 Homebrew 本地 DSL/离线审计通过；未安装 homebrew/core，排除依赖该目录的 token_conflicts 检查。线上 Cask 和迁移文件与本地逐字节一致，没有运行 brew install/upgrade 或更改用户安装。

[GitHub Pages 部署](https://github.com/study-233/flux6/actions/runs/42836218561) 已成功，官网为 https://study-233.github.io/flux6/，启用 HTTPS。仓库 About 与 Tap 官网链接均指向该地址，主题中的旧品牌已替换为 flux6。线上页面在隔离 Playwright/Chrome 中完成 320、390、768、1024、1440px 验证：无横向溢出、损坏图片或控制台错误；下载链接、双语/主题持久化、复制、键盘操作、日志搜索与无 JS 回退通过，线上 release.json 与本地已验证附件元数据完全一致。截图和记录位于 `build/flux6-release/site-live/`。

另外通过 Windows Go helper 的 amd64 交叉编译；这不等于 Windows 原生安装或运行验证。所有既有测试边界继续有效：本轮未执行实际 VPN/代理联网、管理员安装、真机覆盖安装、Apple 公证，也未停止用户进程。后续维护记录提交不改动签名产物、对应源码或发行标签。

## 2026-11-10 统一代理规范与仓库技能

借鉴 FlClash v0.9.3 的 `AGENTS.md` 和五个技能，固定来源为 `be84736605527034689c95bf27828ff27d912c5e`。根入口增加按平台阅读导航、任务范围、生命周期归属、生成代码、隔离验证和检查结果报告要求，保留 Flux6 原有分支、签名、联网、第三方来源及预留平台约束。来源文件映射、本地适配与 GPL-3.0 许可见 [代理规范来源](../../.agents/UPSTREAM.md)。

按用户要求，删除 Android 内的五个技能及旧索引，在根 `.agents/skills/` 维护 `localization`、`ui-work`、`core-platform`、`ui-performance`、`pre-commit-quality-review`，名称不加前缀。Android 的架构、命令、设置归属、界面与编码参考保留，入口改为引用 [统一技能索引](../../.agents/skills.md)。根忽略规则仅开放这套技能、索引和来源许可，本地代理状态继续忽略。技能按 Mac Swift/XPC、Android ServiceState、Windows Go helper 和各端实际文案机制适配，未引入上游 hooks、子代理配置或发布流程。

验证：五个技能通过 `skill-creator` 的 `quick_validate.py`；根仓库检查通过；新增及修改的代理文档本地链接、代码路径、技能名称唯一性、Android 技能目录移除、GPL 原文一致性、文案扫描命令和 Git 忽略边界均已核对；`git diff --check` 通过。校验依赖只安装到临时目录。此次为代理文档与配置整理，没有修改应用代码或构建/源码打包脚本，因此没有重复平台编译、安装、签名或真实联网验收；现有验证结论不因此扩大。

用户随后要求提交全部本地遗漏改动，本轮将独立工作树中的该组改动提交，并与最新 Flux6 主线合并；保留完整的官网、重打包和发布记录。新增代理文档中的项目名同步为 Flux6。按 pre-commit-quality-review 的文档整理分流跳过结构审查；复核五个技能格式、71 个本地链接、许可一致性、忽略边界及仓库检查。当前已发布 0.1.0 安装包和对应源码归档保持原发布快照，不因代理文档更新而重打包。


## 2026-11-11 macOS 与 Android 应用内更新本地准备

按用户要求接入两端正式更新通道，随后明确要求“先不要发布”。使用独立 `feat/app-updates` 工作目录，保留原目录中另一项 macOS 服务修复。候选版本为 macOS 0.1.1 / build 11、Android 0.1.1 / build 2026111101；没有提交、推送、创建标签或 Release，没有部署 `macos-updates` 分支，也没有更改官网、Homebrew 或已发布的 0.1.0。

macOS 构建默认嵌入 Flux6 的 HTTPS 更新地址和公开 Ed25519 公钥，支持已有环境变量覆盖；正式更新身份由 Sparkle 工具生成，私钥位于仓库外私有目录、专用钥匙串及私有备份中。更新包重新签名时显式使用原代码签名钥匙串。DMG 从已经签名的更新 ZIP 解包产物制作，确保两种安装方式提供同一 App。

Android 恢复关于页“检查更新”和首次引导结束后的自动检查，沿用现有偏好、下载进度、SHA256 校验及系统安装确认。查询和下载使用强制 TLS 验证的 Flux6 自有源，GitHub API 限流时只接受同一仓库的正式版本跳转。ARM64 APK 名称与准备的发布附件一致；未发布的 Android 架构使用网页下载回退。上游来源和贡献者链接保留。手动检查增加重复请求保护，复用已有七种语言文案，没有修改 ARB 或手工修改生成文件。

验证：Swift 199 项中 177 通过、22 因外部夹具条件跳过、0 失败；六项隔离原生更新探针通过，覆盖实际升级、坏包签名、未签名清单、取消安装、取消下载和安装许可前宿主退出。macOS Release 构建、签名清单与 ZIP 验签、DMG 只读挂载和拖放副本检查通过，669 个归档源码与 App 内清单及当前文件一致。Android analyze、42 项更新相关测试及 27 项 UI 规范测试通过；含 390/900 dp、明暗主题的关于页交互检查。Android Release APK 构建和 2716 个源码归档文件核对通过。两端公开证书摘要均与 0.1.0 一致；仓库链接/版本/来源检查、9 项维护测试及差异空白检查通过。

本地交付物位于该工作目录的 `dist/release/0.1.1/`：macOS DMG、签名更新 ZIP、签名 appcast、Android APK、两端对应源码和统一 `SHA256SUMS`。验证报告位于 `build/app-updates-validation/validation.json`，发布步骤和密钥保管见[应用内更新准备](../releases/in-app-updates.md)。0.1.0 两端均需手动安装一次带通道的新版本。

验证边界：没有部署公开更新源、替换已安装应用、执行管理员系统服务升级、启动真实代理/VPN、进行 Android 真机覆盖安装或 Apple 公证。隔离升级通过不等同于以上验收完成。macOS 正式清单尚未上线，候选当前访问该公开地址会失败，不能把本地准备描述为线上更新已开放。

## 2026-11-12 0.1.1 提交与发布准备

macOS 与 Android 的更新候选基于主线 `83b212f`。已整理[用户发行说明](../releases/v0.1.1.md)，核对两个平台对应源码、六份候选文件的 SHA256 和签名清单引用的 ZIP 名称与大小。发布来源检查覆盖 Android 更新仓库、macOS 公钥及清单地址，仍支持仅检出 Windows 的工作目录。

应用源代码与上一轮签名构建一致，沿用上述本地构建和测试结果。Android 真机覆盖安装与 macOS 公开源升级仍待验收。

## 2026-11-12 上游更新准备

本地准备分支 `chore/sync-upstream-20261112` 基于 Flux6 远端主线 `be1bef5`。上次同步点 `bcf3819` 到上游主线 `68d93c3` 共 7 个提交、12 个文件。源码标签 `v0.5.4` 位于 `8e99541`，之后一个提交只改上游说明和公告。核查时 GitHub 的最新正式 Release 为 `v0.5.3`，按 `v0.5.4` 查询公开 Release 返回 404。动态 helper 端口和残留进程处理已在上次同步中纳入。本轮差异没有修改跨平台协议、依赖版本或许可证。[上游提交差异](https://github.com/evansrrr/free-v6/compare/bcf3819...68d93c3) · [上游源码标签](https://github.com/evansrrr/free-v6/tree/v0.5.4)

| 上游提交 | Flux6 接入建议 | 验证要点 |
| --- | --- | --- |
| `822e507` 启停按钮 | 优先移植到 Windows Web。启动成功或停止返回时使在途状态查询失效。Windows Flutter 候选已有忙碌标志和操作完成时的代数校验。 | 在现有 Web 回归里补上“发出停止 → 发出轮询 → 停止完成 → 旧轮询返回”，以及启动时的对称时序。后续轮询应能反映真实变化。 |
| `73193fa` 停止时恢复 DNS | 分开评估减少 `netsh` 命令和异步恢复。当前快照只记录服务器地址，无法区分静态配置与 DHCP 下发的地址。上游在后台恢复期间可删除快照并返回成功，新启动可能与旧恢复并行，退出 helper 也可能中断恢复。首轮建议保留 helper 等待恢复结束的顺序。 | 用空地址、单协议、双协议和旧快照验证命令及顺序。Windows 上核对 DHCP/静态配置、快速重启和停止后立即退出，再评估耗时。 |
| `e2d49c7`、`96482c2` 刷新 | 上游最终实现会重载 WebView。Flux6 的 `autoRun.startupHandled` 只存于页面内存，重载可再次触发启动时自动连接。建议保留当前数据刷新，增加可见的刷新反馈。 | 开启自动连接、手动停止、点击刷新后仍应停止。核对节点和公告确实更新。 |
| `870875a` 流量环 | 可独立移植对数绘制，图例和详情继续展示实际字节数。 | 验证零流量、单方向流量和上下行差距悬殊的样例。 |
| `8e99541`、`68d93c3` 版本与文案 | 保留 Flux6 的 README、公告源及版本策略。上游版本作为来源记录，Windows 是否升版留到其发行准备时决定。 | Flux6 基线为 Windows 0.5.3、macOS/Android 0.1.1。 |

`git merge-tree` 预演得到 5 个冲突路径。根 `README.md` 与 `notice.json` 沿用本项目内容。Windows 的 `apps/windows/src-tauri/Cargo.toml` 与 `apps/windows/web/index.html` 涉及版本和品牌，旧根路径 `src-tauri/tauri.conf.json` 涉及删除与修改冲突。当前配置位于 `apps/windows/src-tauri/`，选取修复时需同时核对自动合并的 `Cargo.lock`、`CHANGELOG.md` 与配置中的版本。

现有主线的 4 项 Windows Web 测试、128 个本地 JS 模块、9 项维护测试、仓库检查和 macOS 主机上的 `go test ./internal/network ./cmd/freev6-helper` 通过。helper 的回环测试夹具在沙箱中被拒绝绑定端口，在普通用户环境重跑通过。额外的 Node VM 探针模拟了停止期间发起的轮询：主线收到过期响应后回到运行中，相同输入下预演树的 Web 代码保持已停止。另一组内存夹具验证了自动连接开关打开时的手动停止场景：在原页面刷新状态排队 0 次，重新创建页面后排队启动 1 次。此次仅完成差异评估与基线验证；Windows 原生构建、系统 DNS 恢复和停止耗时仍待实际接入后验证。

## 2026-11-12 接入上游修复并重新准备 0.1.1

从 Flux6 主线 `be1bef5` 接入上游至 `68d93c3`。Windows Web 在启停成功后丢弃旧状态响应，覆盖定时轮询和手动刷新。刷新保留当前页面、自动连接会话及焦点，在数据请求结束后解除忙碌状态。流量环对上传、下载使用对数权重，图例保留实际字节数。

Windows helper 在恢复 DNS 前只读枚举网卡，按接口名、索引及协议族比对有序服务器列表。相同配置跳过 `netsh`，列表变化、接口缺失或枚举失败时沿用已有恢复命令和顺序。停止路径在 helper 的原有锁内等待恢复结束。Windows 工程保留独立版本 0.5.3，生产入口仍为 Tauri。

本地 0.1.1 发行候选重新签名构建为 macOS build 12、Android build 2026111201。两端沿用原证书。六份附件及统一校验文件位于本工作树的 `dist/release/0.1.1/`。清单文件自身的 SHA-256 为 `41e52897e3ba4a2da5fb8496d7942dd4a50ecc94d152aeada32e6e35f168eb56`。安装和早期试用者升级步骤见[发行说明](../releases/v0.1.1.md)。

| 验证范围 | 本轮结果 |
| --- | --- |
| Windows 与共享 Go | 根模块和 Android 嵌套核心的 test/vet 通过。Windows/amd64 的根模块测试包交叉编译、vet 和 helper 构建通过。DNS 夹具覆盖地址相同、单协议变化、地址优先级变化、恢复 DHCP 与无当前快照时的回退。 |
| Windows Web | 8 项运行时回归通过。隔离 Chrome 用浅色 720×520 和深色 1080×760 验证流量环、字节图例、连续点击刷新、忙碌状态和减少动画。 |
| macOS | DMG 只读挂载和拖放副本、Sparkle 更新 ZIP 与清单验签、原代码签名证书、669 项源码与 App 内清单均通过。带独立身份的 build 11 测试宿主通过本地签名清单安装并重启 build 12 候选副本，确认新进程加载 Flutter 和 App 框架。 |
| Android | APK 的签名、应用 ID、版本、ARM64 架构及 2716 份对应源码核对通过。隔离 Android 15 模拟器从旧 0.1.1 APK 覆盖安装到新 build，首次安装时间一致。公开更新检查使用软件版本号，同为 0.1.1 的早期 APK 需手动覆盖安装。 |

日志及截图位于本地 `build/release-validation/`。Windows 原生安装、真实 DNS 还原及性能数据、macOS 管理员服务升级、Apple 公证和 Android 实体手机仍待相应环境验证。独立修复分支 `fix/macos-missing-launchdaemon` 上的 `d30d15b` 不在该候选基线中。
