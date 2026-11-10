# FreeV6 macOS 客户端源码与第三方告知

macOS Flutter 客户端组合使用 FlClash v0.9.3 和 Prism UI 的 GPLv3 代码。该组合客户端按随附的 GPLv3 条款提供；FreeV6 自有 MIT 源文件及第三方文件保留各自版权声明。独立服务和其他平台构建使用其各自随附的许可。

同一批候选产物包含可解压的 macOS 对应源码 ZIP。解压后进入 FreeV6-source，运行 `bash scripts/macos/build-app.sh`。需要 Xcode、Go 与网络访问以按锁文件取得依赖。首次运行会按 SHA-256 校验固定的 Flutter SDK；如需指定已安装的 Go，设置 `GO_BIN`。Sparkle SDK 的版本和压缩包摘要在 macos/Dependencies/sparkle.json 中。若需自行配置更新通道，使用自己的公钥和签名流程。

应用内 Resources/Notices/macOS-source-sha256.json 与源码包里的同名文件逐字节一致，列有 macOS 源文件、资源、锁文件和构建脚本的 SHA-256。Flutter-component-sources.json 记录复用组件的原提交、原始 Git blob 及修改理由。

- FlClash：be84736605527034689c95bf27828ff27d912c5e。许可全文见 FlClash-LICENSE.txt。来源 https://github.com/chen08209/FlClash 。
- Prism UI：63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185。完整组件源码在 macos/flutter_ui/vendor/prism_ui，详见 PrismUI-LICENSE.txt 和 PrismUI-NOTICE.txt。
- Flutter 3.47.6 / Dart 3.13.5：framework 5fc346839b5d0eef006ed8404392afb4dfae428d，engine 692136cb6582dbfc5af3fb33c2515a069f2f66d0。来源 https://github.com/flutter/flutter 。Flutter-LICENSE.txt 与本次实际编译生成的 Flutter-Package-Notices.txt 包括 Flutter/Dart 依赖及字体告知。
- Go worker 的依赖固定在 go.mod 和 go.sum；Sparkle 和其他组件的声明见 THIRD-PARTY.txt。
