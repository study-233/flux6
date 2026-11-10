# Windows Flutter 编译与验收

源码已在 Mac 实现；Windows C++、PowerShell、NSIS、安装升级和真实网络尚未在此工作区执行。请在 Windows 上拉取包含 `refactor/windows-flutter` 提交的代码后验证。不要把 Dart 测试通过等同于原生验收。

## 1. 工具与构建

本轮目标为 Windows 10/11 x64。准备 Flutter **3.47.6**、Visual Studio 的“使用 C++ 的桌面开发”（含 Windows SDK/CMake）、Go（go.mod 要求至少 1.25，允许 Go 自动选择所需工具链）、Python 3.10+ 和 NSIS 3。使用普通 PowerShell 执行构建即可，运行正式应用时会申请管理员权限。Flutter 环境见[官方 Windows 设置说明](https://docs.flutter.dev/platform-integration/windows/setup)。不需要 Rust/Tauri 来编译新客户端。

从仓库根目录执行：

```powershell
$env:FREEV6_FLUTTER_SDK = 'C:\tools\flutter'
& "$env:FREEV6_FLUTTER_SDK\bin\flutter.bat" doctor -v
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\check-flutter.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\build-flutter.ps1 -MakeNsis 'C:\Program Files (x86)\NSIS\makensis.exe'
```

`check-flutter.ps1` 执行 Dart 分析/测试、构建独立预览和隐藏宿主探针。探针不启动 helper，且只结束自己超时的测试进程。`build-flutter.ps1` 执行 Flutter/Go 检查、正式 `live` flavor 构建、helper/GeoSite 准备、许可证与对应源码、NSIS 和 SHA256 打包；不启动应用或代理。依赖和 GeoSite 首次准备需要下载。

产物目录为 `dist/windows/0.5.3-flutter/`（版本从现有 Windows 版本源读取），包含安装包、portable ZIP、对应源码 ZIP 和 SHA256SUMS。没有 NSIS 时可加 `-NoInstaller` 先生成 portable ZIP；解压到稳定测试目录，保留全部 DLL 和 data/。不要直接在可清理的 build 缓存中长期使用，运行配置和 WARP 凭据会放在程序旁的 config/state/runtime。

重复构建未发布候选可加 `-Rebuild`；脚本遇到运行数据会停止，不能用此选项删除用户数据。`-SkipChecks` 仅用于排查构建，结果不算完成验收。发布仍须版本升级、签名/发行检查及人工授权，脚本不会自动推送或发布。

## 2. 安装与偏好迁移

1. 在旧版停止连接并从托盘退出，备份原安装目录的 config/state/runtime 到仓库外的私有位置；其中有凭据，不上传 GitHub。
2. 执行 `scripts/windows/inspect-legacy.ps1 -Output <仓库外路径>`，对照旧安装范围、目录、版本和卸载项。该脚本不读取凭据内容。
3. 如需 UI 历史，在包含本次导出入口的旧 Web/Tauri 版本里选择“设置 → 界面偏好备份 → 导出 JSON”。旧发行二进制若没有此入口，需要先构建/安装带该入口的最后一版 Tauri；不能在普通浏览器打开 HTML 来读取已安装 WebView 的 localStorage。
4. JSON 仅包含主题/动态色/纯黑/背景/壁纸、引导、跳过版本、公告已读、流量、季节偏好。原有已发布旧二进制无法被新 Flutter 自动读取；未导出的 UI 历史不会自动出现。旧 WebView profile 保留，可稍后回退导出。
5. 在 Windows 安装候选，再从新界面“设置 → 数据 → 导入界面备份”导入。失败保留原值；成功保存到原安装目录的 `state/flutter-ui.json`，保留 `.bak`。重复导入为覆盖指定偏好，不会累加流量。旧版导出使用格式 v1；Flutter 导出的 v2 另外保留“减少动态效果”，两种格式均可导入。
6. 比较 WARP 注册、链式/备用配置、设置和流量历史，重启后再比较。新客户端不复制或重建 helper 凭据文件。

## 3. 原生功能清单

逐项记录 Windows 版本/架构、源码提交、构建命令、实际结果和必要的脱敏日志。

| 范围 | 验收内容 |
| --- | --- |
| 启动 | UAC 成功/取消，首次/已有配置启动，helper 缺失/提前退出可见错误，重复启动恢复已有窗口 |
| 窗口 | 720×480、常用 DPI 与多屏；最小化/最大化/缩放；关闭隐藏托盘、托盘恢复/退出；Explorer 重启后托盘恢复 |
| F6 | 显示隐藏窗口、占用冲突报错与开关回滚；退出后释放 |
| 自启动 | 设置成功/失败回滚、重登录、静默开/关、Task Manager 禁用；只影响当前安装的任务和 Run 项 |
| 网络 | 缺核心、WARP 注册失败、非教育网 IPv6、离线恢复、启动重试；连接/停止、DNS/热点恢复；失败时不假报已退出 |
| 节点 | 接入/链式分组、中文与斜杠名称、切换失败、6 路测速、测试中停止/切换页签，旧响应不回填 |
| 配置 | 订阅 URL/文件、错误格式、校园绕过列表、备用配置门户与公告门禁、关闭门禁时的行为 |
| 外观 | 系统/浅/深、动态取色、纯黑、壁纸、玻璃、Mica/Acrylic 与 Windows 10 回退、减少动态效果、10/31 季节反馈 |
| 数据 | 流量跨重启、界面 JSON 导出/导入、无效/过大备份拒绝、不携带 helper token、重置设置保留 WARP/UI 历史 |
| 下载更新 | 核心下载错误/重试；更新版本/忽略、SHA256 错误、停止失败阻止安装、安装器无法启动保留窗口、静默成功重启 |
| 安装 | 全新/同版覆盖/旧版升级/拒绝降级，HKCU 32/64 视图，路径带空格和中文；运行时阻止覆盖，不产生重复卸载项 |
| 卸载回退 | 默认保留数据、明确勾选才删除数据、自启撤销；用旧安装包恢复时 helper 数据仍可读取，旧 WebView 偏好仍在 |
| 许可源码 | 包内 NOTICES、Flutter NOTICES、FlClash GPLv3、Prism/Go 许可、源码 ZIP 和清单一致；从源码 ZIP 可重新构建 |

真实联网和网络恢复由使用者在自己的 Windows 验收环境手动执行；仓库自动检查不会改动系统网络，也不会停止用户已有进程。C++ bridge 探针只验证平台通道，不能代替上表。

## 4. 切换条件

本轮保留 Tauri 生产入口、版本源及旧源码。W1–W4 的源码/本机检查与上面的 Windows 待验项目分别记录。待 Windows 编译、系统行为和安装迁移通过后，W5 才切换正式构建/版本检查，并在单独提交中删除旧 Web/Tauri；不要提前发布候选到稳定更新地址。
