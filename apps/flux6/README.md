# Flux6 统一客户端候选

当前入口验证 FlClash 节点分组在三端的显示与切换。源配置来自[共享合成样本](../../shared/fixtures/warp-business-configuration.json)。预览使用原有 GroupTabs、Group、Proxy 和 Prism 主题；打包资源仅提取分组名称及有序成员。阶段与正式功能映射见[迁移记录](../../docs/development/unified-client.md)。

从仓库根运行 `python3 scripts/unified/prepare.py`。脚本在 build 下新建独立 Flutter 工程并打印其绝对路径。它从 [Android 派生工程](../android/FREEV6.md)取受 Git 跟踪的应用、核心、插件、Android runner 和依赖锁，加入本目录的桌面 runner 及预览入口。临时工程与主仓库保持 Go 模块要求的相对位置。编辑公共功能时修改源文件，然后重新组装。

## Mac 与 Android

使用仓库固定的 Flutter 3.47.6、Go 和 Rust 工具链。在 Bash 中先从仓库根加载环境。Mac 需要在解析 Flutter 插件之前选定完整 Xcode，以便生成 SwiftPM 依赖。

```bash
source scripts/android/env.sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export FLUTTER_SWIFT_PACKAGE_MANAGER=true FLUTTER_MACOS_ARM64_ONLY=true
candidate=$(python3 scripts/unified/prepare.py)
cd "$candidate"
flutter pub get --enforce-lockfile
flutter analyze --no-pub --no-fatal-infos
flutter test --no-pub test/unified_node_groups_test.dart
flutter build macos --release --no-pub
flutter build apk --debug --target-platform android-arm64 --no-pub
```

Mac 产物为候选目录中的 `build/macos/Build/Products/Release/Flux6 Preview.app`，标识为 `dev.flux6.unified.preview`。Android 产物为 `build/app/outputs/flutter-apk/app-debug.apk`，标识为 `dev.flux6.unified.preview.dev`。预览采用普通 FlutterActivity，清单移除了 VPN、代理服务和文件提供程序。

## Windows x64

在带 Visual Studio C++ 桌面开发、Flutter 3.47.6、Go 1.27 和 Rust 1.99 的 Windows 开发机上，从仓库根运行：

```powershell
.\scripts\unified\check-windows.ps1
```

脚本组装同一工程、检查依赖锁、执行分析和公共节点页测试，再编译并显示候选 EXE 路径。运行时需要保留对应 Release 目录中的 DLL 和 data。窗口类和二进制名称独立；预览入口加载合成分组。

## 来源和本地适配

macOS 和 Windows runner 来自 [FlClash v0.9.3 的固定提交](https://github.com/chen08209/FlClash/tree/be84736605527034689c95bf27828ff27d912c5e)，保留[上游许可证](LICENSE)。对照时使用相同的平台相对路径。平台发行脚本、Windows 回环设置程序及上游网站均不属于预览打包输入。

- Mac 调整应用标识、窗口与退出行为，移除上游 URL 注册及登录项接入。保留 SwiftPM 插件注册和构建核心的流程。
- Windows 使用独立文件名、窗口类与标题，首帧显示窗口；预览省略代理清理、单实例激活以及核心和 helper 安装步骤。
- Android 只在组装出的工程内使用候选包名和预览清单。正式 APK 构建继续使用原工程。
