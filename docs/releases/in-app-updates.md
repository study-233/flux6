# 应用内更新

macOS 与 Android 从 Flux6 0.1.1 开始支持应用内更新。首次安装和早期候选升级步骤见[发行说明](v0.1.1.md)。

| 平台 | 发行版本 / build | 更新路径 |
| --- | --- | --- |
| macOS arm64 | 0.1.1 / 12 | 手动检查 → 签名清单与 ZIP 验证 → 确认安装并重启 |
| Android arm64 | 0.1.1 / 2026111201 | 关于页手动检查或启动后按偏好检查 → SHA256 校验 → 系统确认安装 |

0.1.0 两端都需先手动安装一次新包，之后才能使用应用内更新。macOS build 11 可通过应用内更新升至 build 12。Android 按发行标签的版本号检查更新，使用过同版本旧候选的用户需要手动覆盖安装新 APK。

## macOS 通道与密钥

- 公共配置：[update-channel.json](../../apps/macos/Resources/update-channel.json)。构建脚本默认嵌入，也支持 `FREEV6_UPDATE_CHANNEL_FILE` 指定其他通道。
- arm64 地址：`https://raw.githubusercontent.com/study-233/flux6/macos-updates/appcast-arm64.xml`。
- 签名采用 Sparkle 2.9.6 的 Ed25519，清单和 ZIP 均需验签。代码签名继续复用原有本机证书，未进行 Apple 公证。
- 正式更新身份存放在维护者的钥匙串中，导出的私钥和备份保存在仓库外。私有目录权限为 0700，私钥文件权限为 0600。
- 不自动轮换公钥；以后构建必须复用同一私钥，否则旧客户端无法验证新版本。源码只包含公钥。SDK 的 `generate_keys --account dev.freev6.desktop.updates -p` 可读取公钥，`-x <新私有文件>` 可导出已有身份；不得把私钥打印到日志。

生成更新资产使用 `scripts/macos/package-update.py`，传入已完成签名的 App、通道配置和仓库外的私钥文件、版本、build，以及兼容的旧 build 范围。本次发行为 build 12，兼容范围为 10 至 11。build 10 首次仍需手动安装。清单要求 worker v1、服务 v6、设置 schema v1。

打包时必须传入与 App 一致的 `FREEV6_CODESIGN_IDENTITY`、`FREEV6_CODESIGN_KEYCHAIN`；本机证书另设 `FREEV6_LOCAL_SIGNING=1`，保留主程序的框架约束。把更新 ZIP 解包后作为 `build-dmg.py --from-app` 的输入，以确保 DMG 与更新 ZIP 内是同一签名 App。

## Android 通道与安装

客户端通过 `https://api.github.com/repos/study-233/flux6/releases/latest` 查询正式版本；API 限流或失败时仅接受同一仓库的 HTTPS 最新版本跳转。检查与下载均使用强制验证 TLS 证书的客户端。上游来源链接继续指向 FlClash，更新地址单独定义。

发布附件必须命名为 `Flux6-<版本>-android-arm64.apk`，并在同一 Release 的 `SHA256SUMS` 中提供该文件的 SHA256。版本标签为 `v<版本>`。目前只提供 ARM64；不要将未交付架构指向错误的 APK。

安装复用现有 PackageInstaller 流程及 `dev.freev6.mobile` 应用 ID，并继续使用原 Android 签名身份。系统要求用户确认安装，校验失败不会进入安装。自动检查可在通用设置关闭；手动检查不受该偏好限制。下载进度、取消、待安装提示复用现有首页组件。

## 后续版本的发布步骤

1. 复核本地候选、对应源码和校验文件，完成所需的设备安装验收。
2. 为同一版本准备一个 Release，上传 macOS DMG、签名更新 ZIP、签名清单 `appcast-arm64.xml`、两端对应源码、Android APK 和统一的 `SHA256SUMS`。校验文件中的六个文件名须与附件一致。
3. 核对草稿目标提交和七个附件。确认更新 ZIP 文件名中的版本与 build 和签名清单一致，并按本次 `SHA256SUMS` 核对六个附件的摘要。公开后再匿名下载核对。
4. 验证 macOS ZIP 可公开下载后，一次提交部署已经签名的 `appcast-arm64.xml` 到 `macos-updates` 分支。签名后不能格式化或改动清单。
5. 完成正式源检查及升级验收，再同步官网、Homebrew 和发行记录。官网从 GitHub 填入实际 `publishedAt` 和附件数据。复核公开 DMG 的摘要后更新 Tap。

## 本地验证结果

两端 Release 安装包已生成，原代码签名证书核对通过。macOS 清单与 ZIP 验签、DMG 只读挂载及拖放副本验证通过，669 个对应源码与包内清单一致。Android APK 的版本、应用 ID、ARM64 架构与原签名核对通过，2716 个对应源码与归档一致。

在独立 QA 身份下，macOS build 11 的测试宿主通过 Sparkle 升级并重启 build 12 候选的 Flutter 副本。Android API 35 ARM64 模拟器用原签名 APK 从 2026111101 覆盖安装到 2026111201，首次安装时间一致。

正式附件与统一校验文件见 [Flux6 0.1.1](https://github.com/study-233/flux6/releases/tag/v0.1.1)，本轮记录见[上游同步与候选重建](../development/repository-maintenance.md#2026-11-12-接入上游修复并重新准备-011)。真实系统服务升级、Android 实体手机及 Apple 公证在本次验证范围之外。
