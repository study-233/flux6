# Windows Flutter 开发

本工程使用 Flutter 3.47.6，已实现独立预览和真实 `live` 入口。默认入口为独立演示程序 `freev6-windows-preview.exe`，只操作内存合成数据，不启动 helper、不申请管理员权限。正式 Windows 产品仍由上层 Tauri 工程构建。

Mac 上从仓库根执行：

```sh
bash scripts/windows/flutter.sh pub get --offline --enforce-lockfile
bash scripts/windows/flutter.sh analyze --no-pub
bash scripts/windows/flutter.sh test --no-pub
python3 scripts/windows/check-sources.py
node --test scripts/windows/test-legacy-preferences.mjs
```

Windows 上准备 Flutter 3.47.6 和 Visual Studio 的“使用 C++ 的桌面开发”，再从仓库根执行：

```powershell
$env:FREEV6_FLUTTER_SDK = 'C:\tools\flutter'
.\scripts\windows\check-flutter.ps1
```

脚本依次校验固定 SDK、恢复锁定依赖、执行分析与测试、生成 x64 Release 演示包，最后启动自身的隐藏 `--host-probe` 进程验证 Dart/C++ 桥接。探针最多等待 30 秒，超时只结束该测试子进程。产物在 `build/windows/x64/preview/runner/Release/`；手动预览时保留该目录的所有 DLL 和 `data/`。

`--host-probe` 仅验证原生桥接，不表示 helper、权限、安装或网络已经验收。可用 `-SkipBuild` 仅执行 Dart 检查。旧安装兼容信息通过仓库的 `scripts/windows/inspect-legacy.ps1` 只读收集；不读取配置、WARP 私钥或 WebView 存储内容。

视觉组件从 Mac 基线机械复制，原始来源在 `vendor/UPSTREAM.json`，Mac 提交和 SHA256 在 `vendor/MACOS-SOURCE.json`；本端改动登记在 `vendor/WINDOWS-PATCHES.json`。`check-sources.py` 防止未登记修改。Flutter runner 来自 SDK 提交 `5fc346839b5d0eef006ed8404392afb4dfae428d` 的 Windows 模板，保留 `vendor/Flutter-LICENSE`；本地改动包括品牌资源、预览身份及原生桥接。

后续阶段以 [实施方案](../../../docs/development/windows-flutter-refactor.md) 为准。用户将源码推送 GitHub 后，在 Windows 拉取并编译验证；本机结果和 Windows 待验项分开记录。


## 真实客户端候选

`lib/live_main.dart` 对应 `--flavor live`，宿主输出 `freev6-desktop.exe` 并申请管理员权限，调用现有 Go helper。预览入口始终对应 `--flavor preview`，二者协议不匹配会明确报错，不能用预览结果代替真实客户端。

Windows 完整构建：

```powershell
.\scripts\windows\build-flutter.ps1 -MakeNsis 'C:\Program Files (x86)\NSIS\makensis.exe'
```

工具准备、产物、旧版偏好迁移、测试环境和分项验收见 [Windows 验收手册](../../../docs/development/windows-flutter-acceptance.md)。脚本不会启动真实应用或代理；用户在 Windows 完成编译与安装验证。默认生产 Tauri 入口暂时保留，W5 切换需原生验收通过。

`live` 产物位于 `build/windows/x64/live/runner/Release/`。因 Flutter 工具以首个静态 BINARY_NAME 推断调试程序名，默认 `flutter run` 用于预览；真实版本通过上述脚本构建并直接启动产物，不使用 `flutter run --flavor live`。
