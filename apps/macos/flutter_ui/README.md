# FreeV6 Flutter for macOS

这是 Mac 正式应用的界面工程，由 Swift/AppKit 管理窗口，通过已有桥接协议接入 Go worker 和 XPC 网络服务。正式入口为 `lib/live_main.dart`；发行版本来自上层 `Resources/Info.plist`，不使用本子工程的演示版版本号。

从仓库根目录构建：

```bash
bash scripts/macos/build-app.sh
```

产物为 `dist/macos/FreeV6.app`。完整工具链、签名、安装与 DMG 步骤见 [Mac 说明](../README.md)。[当前验收索引](../../../docs/releases/macos-validation.md) 区分自动检查与实机验证。

## 保留的开发夹具

- `lib/main.dart` 和 `scripts/macos/build-flutter-preview.sh` 提供演示数据驱动的 UI 预览，用于布局与视觉回归。
- `scripts/macos/build-flutter-host.sh` 提供独立应用身份、数据目录和隔离会话的集成宿主，用于桥接回归；[历史验证步骤](../../../docs/compose/audits/2026-11-07-flutter-host/README.md) 作为证据保留。

这些入口是测试工具，使用独立 bundle ID，不作为另一套正式 UI。旧 SwiftUI 应用入口已移除。

使用 Flutter 3.47.6 在本目录运行 `flutter pub get --enforce-lockfile`、`flutter analyze --no-fatal-infos` 和 `flutter test`。完整 Xcode 与最低运行系统要求与主应用一致。

[组件固定版本、改动清单与许可](vendor/UPSTREAM.md) 记录 FlClash 和 Prism UI 的来源及本地补丁。不要在整理时删除仍被界面使用的组件或许可证。
