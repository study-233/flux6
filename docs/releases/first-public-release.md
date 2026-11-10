# FreeV6 0.1.0 发行清单

macOS 与 Android 0.1.0 已于 2026-11-10 正式发布，Homebrew Tap 与仓库 About 已同步上线。

[FreeV6 0.1.0 Release](https://github.com/study-233/free-v6/releases/tag/v0.1.0) · [Homebrew Tap](https://github.com/study-233/homebrew-tap)

## 已确认范围

- 首发 macOS 与 Android；Windows、iOS、OpenWrt 不在本次发行范围。
- 按公开正式版准备，GitHub Release 使用 `prerelease=false`。
- macOS 推荐 Homebrew Cask，同时提供 DMG；Android 提供 ARM64 APK。
- 用户已确认安装验收和 Android 真机验证完成。本记录采用用户实测结论，本次文档更新没有重新执行这些验证，也不补填未提供的设备、系统版本或测试日志。
- macOS 不进行 Apple 公证，公证不作为本次发行条件。保留现有代码签名和安装包完整性校验；不在 Homebrew 配置中自动关闭 Gatekeeper 或清除隔离属性。
- 本轮发布正式安装包、对应源码、文档与 Homebrew Cask。应用内自动更新通道保持关闭。

## 版本与交付物

按用户要求，两端首个公开版本统一为 `0.1.0`，同版本的各平台附件集中到一个 Release，平台构建号继续递增；以 [版本脚本](../../scripts/version.py) 的结果为准。发布标签指向主线提交 `232f7b73ec6a3a7a9d120eddd4ad335b52358abf`；[发布 PR #6](https://github.com/study-233/free-v6/pull/6) 及合并后的主线 CI 均已通过。

| 平台 | 当前版本 | 发布标签 | 公开交付物 |
| --- | --- | --- | --- |
| macOS | 0.1.0 / build 9 | `v0.1.0` | Apple Silicon DMG、应用 ZIP、完整对应源码 |
| Android | 0.1.0 / build 2026111005 | `v0.1.0` | ARM64 APK、完整对应源码 |

对外版本重置为 `0.1.0`，两端 build 保持递增，正式包与旧测试包分目录保存，打包脚本拒绝覆盖已有同名发行资产。版本、标签和最终源文件均已核对，私钥和口令不进入仓库或源码包。

正式产物的文件名已去掉 `preview`，Android 七种语言的简介、引导与关于页已清理测试版标识，构建显式使用 `APP_ENV=stable`；Mac 随包安装说明已改为正式版内容。开发专用的隔离预览宿主保留原身份，不进入正式 App。

## 发行文件

| 文件 | 下载 |
| --- | --- |
| macOS DMG | [FreeV6-0.1.0-macOS.dmg](https://github.com/study-233/free-v6/releases/download/v0.1.0/FreeV6-0.1.0-macOS.dmg) |
| macOS 应用 ZIP | [FreeV6-0.1.0-macOS.zip](https://github.com/study-233/free-v6/releases/download/v0.1.0/FreeV6-0.1.0-macOS.zip) |
| macOS 对应源码 | [FreeV6-0.1.0-macOS-source.zip](https://github.com/study-233/free-v6/releases/download/v0.1.0/FreeV6-0.1.0-macOS-source.zip) |
| Android APK | [FreeV6-0.1.0-Android.apk](https://github.com/study-233/free-v6/releases/download/v0.1.0/FreeV6-0.1.0-Android.apk) |
| Android 对应源码 | [FreeV6-0.1.0-Android-source.tar.gz](https://github.com/study-233/free-v6/releases/download/v0.1.0/FreeV6-0.1.0-Android-source.tar.gz) |
| Homebrew Cask | [freev6.rb](../../packaging/homebrew/Casks/freev6.rb) |

## macOS 退出修复

0.1.0 保留此前 build 8 的退出修复：遇到不完整服务安装时，重新检查安装后，若仍报告安装文件不完整且本次客户端未持有网络会话，允许正常退出；持有会话时继续要求网络恢复，升级仍要求安装检查通过。四项隔离回归覆盖异常启动退出、已有会话保护、升级保护与重开后发现会话的恢复。

用户截图所示进程来自 `build/macos-release-runner` 内的 Xcode 中间 App，该包缺少正式打包阶段补入的协议文档与助手。请使用本页链接的完整 DMG；旧验收产物原地保留，正式 DMG 与 Cask 均为 `0.1.0 / build 9`。关闭与退出的本轮自动化验证采用隔离测试，没有修改现有系统服务安装或强制停止用户进程。

## 首发签名身份

签名复核发现，文档记载的原签名目录及历史备份在本机未找到，构建器生成了新的签名身份。用户随后明确确认“使用新签名作为首个正式版身份”。本次交付采用该新身份，后续公开版本必须复用。

- Android 签名证书 SHA256：`f6cbcb4aa014f1c09785a00342cd5a47f9d8bde90e52a11676c14e7fa9d0bf7c`。
- Mac 签名证书 SHA256：`d04a87b6c995a867aa0f087c09fc7e55692758d1ea52c85228493dfac03e1e70`。已核对 App 内证书与持久保存的证书一致。
- 两端签名材料均备份在仓库外 `~/Library/Application Support/FreeV6/Development/backups/first-public-20261110/`，目录权限 0700、文件权限 0600。不得将备份随安装包或源码上传。
- Mac 更换签名后，系统可能要求重新授权读取旧钥匙串项目；本次不声称与旧测试签名的钥匙串授权连续。

## README 与截图

[README](../../README.md) 已按发布后的首页准备：品牌、界面、安装、致谢、MIT、Star History。删除开发过程、平台占位表、重复提示及冗长条款；开发说明与完整许可继续保留在原文件中。

首页并列展示 [macOS 窗口截图](../compose/audits/2026-11-07-p5-p6/visual/offline-1232.png)与用户于 2026-11-10 提供的 [Android 首页实机截图](../images/android-home.jpg)，点击可查看原图。macOS 图片来自隔离 QA 应用的离线界面，来源见 [视觉验收记录](../compose/audits/2026-11-07-p5-p6/visual/README.md)；Android 图片原样保存，显示未运行状态。

README 的 Homebrew 命令通过独立 Tap 分发，绑定固定版本的 macOS Release。Star History 指向 `study-233/free-v6`，由第三方服务动态绘制，仓库暂时没有 Star 时不人为填充曲线。

## Homebrew 分发准备

使用 `study-233/homebrew-tap` 仓库，Cask 文件为 `Casks/freev6.rb`，安装名为 `study-233/tap/freev6`。通过自有 Tap 分发，无需以收录 Homebrew 官方仓库为本次发布条件。参考 [Tap 文档](https://docs.brew.sh/Taps) 与 [Cask 文档](https://docs.brew.sh/Cask-Cookbook)。

已准备的 [Cask](../../packaging/homebrew/Casks/freev6.rb) 绑定以下内容：

| 字段 | 要求 |
| --- | --- |
| `version` | `0.1.0,9`，对应正式 Mac App 的版本与 build |
| `sha256` | 最终 DMG 的实际摘要 |
| `url` | 本仓库统一版本标签 `v0.1.0` 下的 DMG |
| `name` / `desc` | `FreeV6` / `IPv6 client for campus networks` |
| `homepage` | `https://github.com/study-233/free-v6` |
| `depends_on` | Apple Silicon、macOS 14 或更新版本 |
| `app` | `FreeV6.app` |

Cask 仅负责安装应用，网络服务由应用原有授权流程管理。通过 Homebrew 更新 Cask 不等于已部署应用内更新通道；后者按 [Mac 更新手册](../../apps/macos/DEVELOPMENT.md#swift-更新助手与发布) 单独配置。

Cask 已通过 Ruby 语法、Homebrew DSL 解析和离线审计；未安装 `homebrew/core`，因此排除了需要该目录的 `token_conflicts` 检查。发布后已确认线上 Cask 与本地一致，并匿名下载固定版本 DMG，摘要与 Cask 一致。未运行 `brew install`、签名公证检查或更改用户安装。

## 仓库 About 文案

仓库发布配置：

- Description：`教育网 IPv6 免流客户端，支持 macOS 与 Android。`
- Website：`https://github.com/study-233/free-v6/releases`
- Topics：`freev6`、`ipv6`、`cernet2`、`warp`、`macos`、`android`、`flutter`

## Release 正文

[FreeV6 0.1.0](v0.1.0.md)

## 发布与验证结果

| 项目 | 状态 |
| --- | --- |
| 首发平台、正式版定位、不公证 | 用户已确认 |
| 安装验收、Android 真机验证 | 用户确认完成 |
| README、About、Release 文案 | 已上线 |
| Android 真机截图 | 用户已提供，已加入 README |
| 正式包命名、应用内版本标识、最终构建和校验 | 已完成 |
| Homebrew Cask 与最终 DMG 绑定 | 已完成，Tap 已上线 |
| 首发新签名及私有备份 | 用户已确认；备份已核验 |
| GitHub Release、远端标签、About | 已发布，统一为一个正式版 Release |
| 应用内更新通道 | 本次不启用 |

本轮 `0.1.0` 版本调整重新完成两端 Release 构建、Android 静态分析、4 项 macOS 退出回归及 7 项维护测试。此前同一业务源码的 Swift 完整回归为 198 项，179 项通过、19 项因额外夹具条件跳过、0 失败；Android 22 项本地化、动态消息键、FreeV6 业务及引导测试通过，本轮未重复这些未受版本元数据影响的完整测试。Mac DMG 通过只读挂载、拖放副本、签名、架构、最低系统、服务摘要和 ZIP 解压复验；APK 通过签名及包元数据核验，版本正确、仅包含 ARM64 原生库、未启用调试。

Mac 668 个源文件与应用内清单和源码 ZIP 逐项一致；Android 2721 个源文件在构建前后未改变，并与源码包逐项一致。所有发行摘要已重新核算。检查报告保存在本地 `build/first-public-release/verification.json`，日志在同目录；本轮未重新做管理员安装、真实 VPN 或设备联网测试。

统一 Release 的 5 个附件的远端大小和摘要均与本地一致；DMG 匿名下载校验通过，APK 公开下载入口返回 HTTP 200。每个版本仅保留一个 Release，当前 `v0.1.0` 设为 Latest；平台 build 保留在本地构建记录与应用元数据中，用于升级判断。启用 Mac 应用内更新时，最后更新签名清单。
