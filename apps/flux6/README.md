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

在上述 Mac 候选目录中可以使用合成凭据验证配置准备。测试通过 Rust IPC 启动该次构建的 Go 核心，在临时目录渲染配置，检查 28 个接入点和校园分流规则后关闭核心。

```bash
FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR="$PWD/build/native_assets/macos" \
  flutter test --no-pub test/unified_desktop_profile_test.dart
```

## Android 完整客户端候选

从仓库根运行以下命令可构建包含 WARP 设置页、原生服务和 VPN 权限入口的调试包。它使用独立包名 `dev.flux6.unified.client.dev`，拥有自己的应用数据，使用现有 Android `ServiceState` 管理连接。真机授权与连接另行验收。

```bash
source scripts/android/env.sh
candidate=$(python3 scripts/unified/prepare.py --android-client)
cd "$candidate"
flutter pub get --enforce-lockfile
flutter build apk --debug --target-platform android-arm64 --no-pub
```

## Windows x64

在带 Visual Studio C++ 桌面开发、Flutter 3.47.6、Go 1.27 和 Rust 1.99 的 Windows 开发机上，从仓库根运行：

```powershell
.\scripts\unified\check-windows.ps1 -CheckWindowExit
```

脚本检查依赖锁、执行分析和公共节点页测试，编译 Windows 预览，再通过本机命名管道运行配置准备测试。普通用户缺少符号链接权限时，脚本按 Flutter 插件清单建立目录联接并离线复核锁文件。指定 `-CheckWindowExit` 后会启动独立预览、等待窗口可见、请求关闭并检查进程退出码。全部通过后输出 EXE 路径。运行时需要保留对应 Release 目录中的 DLL 和 data。

## 来源和本地适配

macOS 和 Windows runner 来自 [FlClash v0.9.3 的固定提交](https://github.com/chen08209/FlClash/tree/be84736605527034689c95bf27828ff27d912c5e)，保留[上游许可证](LICENSE)。对照时使用相同的平台相对路径。平台发行脚本、Windows 回环设置程序及上游网站均不属于预览打包输入。

- Mac 调整应用标识、窗口与退出行为，移除上游 URL 注册及登录项接入。保留 SwiftPM 插件注册和构建核心的流程。
- Windows 使用独立文件名、窗口类与标题，首帧显示窗口；预览省略代理清理、单实例激活以及核心和 helper 安装步骤。
- Android 只在组装出的工程内使用候选包名和预览清单。正式 APK 构建继续使用原工程。

## Windows 完整界面候选

在 Windows 工作区根目录运行以下命令，构建带 FlClash 首页、节点页和设置的 x64 候选。Windows 宿主和 Go helper 负责连接。默认控制端口 9090 被占用时，节点、测速和流量请求使用 helper 为当前会话分配的端口。

```powershell
.\scripts\unified\check-windows.ps1 -WindowsClient -CheckWindowExit
```

脚本恢复锁定依赖、生成本地化、运行分析和离线业务回归，然后构建使用合成数据的 preview 并运行隐藏宿主探针。`-CheckWindowExit` 会另外显示该预览并验证关闭后的退出码。最后构建 live 版本，将 `flux6-helper.exe` 和 `GeoSite.dat` 放入同一 Release 目录，并输出 `freev6-desktop.exe` 的位置。Pub 依赖已缓存时可加 `-OfflinePub`。手动验收前将整个 Release 目录复制到专用测试位置，按[原生验收清单](../../docs/development/windows-flutter-acceptance.md)验证安装与网络行为。

从 Windows x64 的仓库根目录执行以下命令可打包统一 live 候选。环境需有 Git、Python、原生构建工具和 NSIS，`-MakeNsis` 可指定编译器路径。

```powershell
.\scripts\windows\build-flutter.ps1 -Unified
```

`dist/windows/<版本>-unified/` 包含 NSIS 安装包、便携 ZIP、对应源码 ZIP 和 `SHA256SUMS`。源码 ZIP 解压后可从 `Flux6-source` 目录执行同一命令。仅打便携包及源码时加 `-NoInstaller`。重建本地候选时加 `-Rebuild`，脚本在全部产物就绪后替换上一套，将上一套保存在本次构建工作目录的 `previous` 下。

Windows 界面适配来自归档提交 `9290f22`。组装时使用当前 Android 导出和已修复的托盘插件，增量合并 ARB。简体中文和英语有对应词条，其他语言沿用归档的英语回退。

## Android 和 macOS 完整客户端

从仓库根执行 `python3 scripts/unified/prepare.py --client` 得到同一个 Flutter 工程。两端从 `lib/main.dart` 启动，Android 使用 FlClash 原有应用、设置引导和 VPN 服务，Mac 主窗口使用同一份 FlClash HomePage 和节点分组控件。Mac 的 WARP 设置、节点测量、配置编辑、日志和独立设置窗口沿用原有宿主页面。Swift/AppKit 负责窗口与菜单，网络操作交给原有 worker 和 XPC 服务。

- Android 隔离包在组装目录运行 `flutter pub get --enforce-lockfile` 和 `flutter build apk --debug --target-platform android-arm64 --no-pub`。包名为 `dev.flux6.unified.client.dev`。
- Mac 隔离包从仓库根运行 `bash scripts/macos/build-flutter-preview.sh --unified-host`。也可把已组装的工程路径作为第二个参数，供两端复用。产物为 `build/macos-ui/Flux6 Unified Integration.app`，标识为 `dev.freev6.flutter-host.unified`。该宿主使用专用目录与隔离会话子进程。`bash scripts/macos/probe-flutter-host.sh --unified` 可验证命令、菜单和重启。
- Android 升级候选使用 `FREEV6_OUTPUT_DIR="$PWD/build/unified-android-upgrade" bash scripts/android/build-apk.sh --unified`。配套源码包使用 `python3 scripts/android/package-source.py --unified --output-dir build/unified-android-upgrade`。
- Mac 升级候选使用 `FREEV6_UNIFIED_CLIENT=1 FREEV6_APP_OUTPUT="$PWD/build/unified-macos-upgrade/Flux6.app" bash scripts/macos/build-app.sh`。构建使用原签名、钥匙串身份、服务标识、worker 和更新助手。源码档案工具从候选的 Info.plist 识别统一构建，核对包内源码清单后输出 ZIP。

升级候选沿用 0.1.2 的版本号，供覆盖安装与回退验收。公开更新另行提升版本并签署清单。
