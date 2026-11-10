# Flux6 0.1.0 发行清单

[官网](https://study-233.github.io/flux6/) · [0.1.0 Release](https://github.com/study-233/flux6/releases/tag/v0.1.0) · [Homebrew Tap](https://github.com/study-233/homebrew-tap)

用户在 2026-11-10 明确要求将项目统一改名为 Flux6，并重新打包、替换已发布的 0.1.0。这是对已发布附件不覆盖规则的一次明确授权例外。原始构建、签名记录和发布元数据保留在本地；历史发布过程见 [维护记录](../development/repository-maintenance.md)。

## 版本与交付物

| 平台 | 版本 / build | 交付物 |
| --- | --- | --- |
| macOS | 0.1.0 / 10 | Apple Silicon DMG、应用 ZIP、对应源码 ZIP |
| Android | 0.1.0 / 2026111006 | ARM64 APK、对应源码 tar.gz |

五个公开附件采用 `Flux6-0.1.0-<平台>` 名称，源码追加 `-source`。本地发行目录保留 build 号，旧 build 9 / 2026111005 产物不覆盖。对外仍共用一个 `v0.1.0` Release；Windows 只同步源代码中的品牌，未包含在本次发行中，iOS/OpenWrt 继续保留占位。

macOS 要求 Apple Silicon 与 macOS 14+；Android 要求 ARM64 与 Android 7.0+。macOS 保持持久本机签名，不进行 Apple 公证；应用内自动更新通道继续关闭。

## 签名和兼容性

- Android 证书 SHA256：`f6cbcb4aa014f1c09785a00342cd5a47f9d8bde90e52a11676c14e7fa9d0bf7c`。
- macOS 证书 SHA256：`d04a87b6c995a867aa0f087c09fc7e55692758d1ea52c85228493dfac03e1e70`。
- 两端均与原 0.1.0 正式版签名一致，私钥和口令位于仓库外，不进入源码或发行附件。
- 保留 `dev.freev6.mobile`、`dev.freev6.desktop`、钥匙串、服务、数据目录及加密缓存命名空间，保证原配置可继续读取。
- macOS 登录项可识别并迁移旧 `FreeV6.app` 路径。手动升级先退出旧应用，安装 Flux6 后重新登记登录启动；确认新应用正常后可移除旧 App。
- Homebrew 使用 [flux6.rb](../../packaging/homebrew/Casks/flux6.rb)；[cask_renames.json](../../packaging/homebrew/cask_renames.json) 将旧 `freev6` 名称映射至 `flux6`。

## 验证

- 两端 Release 构建完成，名称、版本、架构和签名已核对。DMG 经过只读挂载、拖放副本、签名、服务摘要及 ZIP 解压复核。
- macOS 668 个源文件与应用内清单和源码 ZIP 一致；Android 2721 个构建输入在构建前后未改变，并与源码包逐项一致。
- 共享 Go 与 Android 嵌套模块的单元测试、vet 通过。
- Swift 共 199 项测试，177 项通过，22 项按额外夹具条件跳过，0 失败；包含旧登录项迁移的隔离回归。
- Android 静态分析及 19 项本地化、消息键、引导和页面测试通过。macOS Flutter 31 项、Windows Flutter 30 项测试及两者静态分析通过。
- 仓库结构、9 项维护测试、图标、发行地址、128 个 Web 模块及 2 项 Windows 打包工具测试通过。
- 官网完成 320/390/768/1024/1440px 浏览器检查，下载、复制、双语、主题、键盘和无 JavaScript 回退通过，详见 [设计 QA](../../site/design-qa.md)。

检查日志、附件摘要和源码比对记录保存在本地 `build/flux6-release/`。本轮未执行管理员安装、真机覆盖安装、VPN/真实联网或 Windows 原生构建，不将历史用户验收记为新构建的实测结果。

## 官网与发布配置

官网由 [GitHub Actions](../../.github/workflows/pages.yml) 构建 `dist/site/` 并部署至 GitHub Pages。下载元数据使用 [release.json](../../site/release.json) 中逐项核验的大小与摘要；仓库 About 链接到官网。来源与 GPL-3.0 许可见 [网站说明](../../site/README.md)。

精简 Release 正文见 [v0.1.0.md](v0.1.0.md)。发布时先上传新附件并核对远端摘要，再移除旧附件；标签更新为包含本轮源码的主线提交，原标签目标 `232f7b73ec6a3a7a9d120eddd4ad335b52358abf` 留在历史记录。
