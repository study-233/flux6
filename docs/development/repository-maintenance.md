# FreeV6 仓库整理进度

本次执行范围为 P0–P4：保存开发基线、分离签名与缓存、统一平台目录、删除已废弃内容、完善开发与 CI。Mac、Android 继续现有开发；Windows 保留现有功能，后续另做自定义 UI 重构。iOS、OpenWrt 只建立说明与待办。

| 阶段 | 状态 | 交付与验证 |
| --- | --- | --- |
| P0 保存基线 | 完成 | `chore/repo-baseline` 分支；签名材料已在仓库外备份并逐文件校验；检查源码与现有测试。 |
| P1 整理产物 | 完成 | Android 签名迁出、分级清理、历史产物整理。 |
| P2 建立结构 | 完成 | 公共资源归位；迁入 `apps/macos`、`apps/android`、`apps/windows`；新增 iOS、OpenWrt 占位。 |
| P3 删除旧内容 | 完成 | 删除旧 SwiftUI 入口、无效平台包装与上游工具；合并当前文档。 |
| P4 完善管理 | 验证中 | 分支规则、版本检查、平台 CI、干净 checkout 验证。 |

## P0 基线

起点为 `mac` 分支的 `2b5a1c0`。现有未提交业务修改一并保留，分别按公共业务、Mac、Android、Windows 与文档形成基线提交。该快照表示可恢复的开发状态，不表示所有平台已经完成实机验收。

2026-11-10，Android 的 `preview.jks`、密码，以及 Mac 本机签名钥匙串、密码、公钥证书已备份到用户 Library 下的 FreeV6 Development 私有目录；备份不进入 Git 或分发源码。移动签名目录前仍保留原文件。

根忽略规则调整为只忽略根 `.agents/`，使 Android 已引用的项目规则可以随源码保存。测试夹具中的示例证书属于上游测试数据，保留其来源；真实签名材料不进入源码。

## 执行约束

- 不使用 `codex/` 分支；不推送、不发布新的发行版。
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

## P4 进展

新增统一开发指南、平台版本读取与一致性检查、目录/链接/第三方来源检查；Android APK 与对应源码按版本和 build 存放。完善 Linux/Windows Go、Windows Rust/Web、Android Go/Flutter/Kotlin/APK 和 Mac Swift/Flutter/App CI，iOS/OpenWrt 不添加构建任务。Windows 发布标签新增 `windows-v*`，兼容既有 `v*`。

修正 helper 测试的隔离条件后，根 Go 源码测试与 vet 通过。Android 224 项 Flutter 回归测试和 Kotlin 单元测试通过；维护保护 7 项通过。后续记录最终构建和干净源码验证结果。
