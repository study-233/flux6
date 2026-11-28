# 应用内更新

三端当前 Latest 为 [Flux6 0.2.0](v0.2.0.md)。从 0.1.x 升级前请先断开连接并退出旧版，首次运行会清空旧配置、凭据和用量历史。

| 平台 | 0.2.0 build | 本次升级路径 |
| --- | --- | --- |
| macOS arm64 | 2026112803 | 下载正式 DMG，覆盖安装到「应用程序」。旧版 Sparkle 通道依赖 Swift/XPC 服务与 worker 的兼容清单，0.2.0 改用新的桌面服务。 |
| Android arm64 | 2026112803 | 使用正式发行 APK 覆盖安装，签名身份与旧版一致。 |
| Windows x64 | 3 | 在 0.1.3 设置中检查更新。Latest 的 `version.json` 提供安装包文件名、对应版本的完整下载地址和 SHA-256，供旧版校验。 |

## 0.1.x 历史通道

macOS 与 Android 从 Flux6 0.1.1 开始支持应用内更新。0.1.x 期间三端 Latest 为 [Flux6 0.1.3](v0.1.3.md)，Windows 单独发布 [0.1.4](v0.1.4.md)，通过对应发布页手动下载安装。

| 平台 | 发行版本 / build | 更新路径 |
| --- | --- | --- |
| macOS arm64 | 0.1.3 / 14 | 启动或手动检查 → 签名清单与 ZIP 验证 → 确认安装并重启 |
| Android arm64 | 0.1.3 / 2026112201 | 关于页手动检查或启动后按偏好检查 → 系统核验 APK 签名并提示安装 |
| Windows x64 | 0.1.4 / 1 | 本次从 0.1.4 发布页下载安装；Latest 的自动更新清单继续保留 0.1.3 |

Windows 0.1.4 不设为 Latest，避免现有 Android 客户端跟随同一入口提示没有对应 APK 的更新。0.1.3 用户直接覆盖安装 0.1.4，继续读取原配置和偏好文件。

从 Windows 0.1.2 升级时，如需迁移主题、公告已读状态或流量历史，请先在旧版导出界面偏好 JSON，再到新版的「数据与维护」中导入。

0.1.0 两端都需先手动安装一次新包，之后才能使用应用内更新。macOS 0.1.1 用户可在菜单或通用设置中手动检查并升级到 build 13。Android 0.1.1 用户需手动覆盖安装 0.1.2 的 APK。

## macOS 通道与密钥

build 13在用户接受首次使用协议后默认每次启动检查一次，无新版时静默结束。在“设置 → 通用”可关闭启动检查。安装前选择“稍后”会继续运行当前版本。

- 公共配置：[update-channel.json](../../apps/macos/Resources/update-channel.json)。构建脚本默认嵌入，也支持 `FREEV6_UPDATE_CHANNEL_FILE` 指定其他通道。
- arm64 地址：`https://raw.githubusercontent.com/study-233/flux6/macos-updates/appcast-arm64.xml`。
- 签名采用 Sparkle 2.9.6 的 Ed25519，清单和 ZIP 均需验签。代码签名继续复用原有本机证书，未进行 Apple 公证。
- 正式更新身份存放在维护者的钥匙串中，导出的私钥和备份保存在仓库外。私有目录权限为 0700，私钥文件权限为 0600。
- 不自动轮换公钥；以后构建必须复用同一私钥，否则旧客户端无法验证新版本。源码只包含公钥。SDK 的 `generate_keys --account dev.freev6.desktop.updates -p` 可读取公钥，`-x <新私有文件>` 可导出已有身份；不得把私钥打印到日志。

生成更新资产使用 `scripts/macos/package-update.py`，传入已完成签名的 App、通道配置和仓库外的私钥文件、版本、build，以及兼容的旧 build 范围。0.1.2 为 build 13，清单兼容范围为 10 至 12。build 10 首次仍需手动安装。清单要求 worker v1、服务 v6、设置 schema v1。

打包时必须传入与 App 一致的 `FREEV6_CODESIGN_IDENTITY`、`FREEV6_CODESIGN_KEYCHAIN`；本机证书另设 `FREEV6_LOCAL_SIGNING=1`，保留主程序的框架约束。把更新 ZIP 解包后作为 `build-dmg.py --from-app` 的输入，以确保 DMG 与更新 ZIP 内是同一签名 App。

## Android 通道与安装

客户端通过 `https://api.github.com/repos/study-233/flux6/releases/latest` 查询正式版本；API 限流或失败时仅接受同一仓库的 HTTPS 最新版本跳转。检查与下载均使用强制验证 TLS 证书的客户端。上游来源链接继续指向 FlClash，更新地址单独定义。

新版直接从 `v<版本>` 的 Release 下载 `Flux6-<版本>-android-arm64.apk`，无需校验文件。已发布的 0.1.1 仍会读取 `SHA256SUMS`，用户首次升级到新流程时需手动覆盖安装一次。

下载完成后由用户确认安装。Android 的 PackageInstaller 将更新限定到已安装的 `dev.freev6.mobile`，并校验 APK 签名。自动检查可在通用设置关闭，手动检查始终可用。

## Windows Tauri x64

Windows 客户端启动后读取本仓库 Latest Release 的 `version.json`，发现更高版本时弹窗。用户可以选择“稍后”或“跳过此版本”。点击“立即更新”后，helper 负责下载和校验 SHA256，Tauri 宿主在启动 NSIS 安装器前再次校验。首次安装及旧 0.5.x 开发版迁移需手动运行安装包。

Windows 发行包与同版本的 macOS、Android 附件共用一个 Release。核对安装包后再上传 `version.json`。本次未发布 Windows 新包时，Latest 沿用最近一次 Windows 正式版的有效清单。详见 [Windows 构建与发布](../../apps/windows/README.md)。

## 后续版本的发布步骤

按[项目发布技能](../../.agents/skills/release/SKILL.md)准备公开附件、确认旧客户端的升级路径并切换更新通道。

## 0.1.1 本地验证结果

两端 Release 安装包已生成，原代码签名证书核对通过。macOS 清单与 ZIP 验签、DMG 只读挂载及拖放副本验证通过，669 个对应源码与包内清单一致。Android APK 的版本、应用 ID、ARM64 架构与原签名核对通过，2716 个对应源码与归档一致。

在独立 QA 身份下，macOS build 11 的测试宿主通过 Sparkle 升级并重启 build 12 候选的 Flutter 副本。Android API 35 ARM64 模拟器用原签名 APK 从 2026111101 覆盖安装到 2026111201，首次安装时间一致。

正式附件与统一校验文件见 [Flux6 0.1.1](https://github.com/study-233/flux6/releases/tag/v0.1.1)，本轮记录见[上游同步与候选重建](../development/repository-maintenance.md#2026-11-12-接入上游修复并重新准备-011)。真实系统服务升级、Android 实体手机及 Apple 公证在本次验证范围之外。
