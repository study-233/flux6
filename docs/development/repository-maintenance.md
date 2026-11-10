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
