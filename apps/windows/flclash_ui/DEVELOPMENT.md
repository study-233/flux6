# FlClash Windows 开发与离线验收

2026-11-10 用户验收路线 B 的界面后，要求接完整 FreeV6 现有后端和功能，先做离线验证，不安装、不启动真实联网。UI 沿用已验收的 FlClash/Prism 窗口、导航、仪表盘、节点、配置、日志及设置。

## 三个入口

| 入口 | 后端和宿主 | 使用范围 |
| --- | --- | --- |
| `lib/main.dart` | PreviewModel；预览宿主 | 原 UI 演示入口，要求 FREEV6_OFFLINE=true 和 SAFE_MODE=true |
| `lib/fixture_main.dart` / fixture flavor | **现有 LiveModel、HelperApi、ControllerApi**；内存 Transport/Host/Preferences | 本轮交付的离线功能验收，要求两个离线标志；禁止 HTTP client，原生宿主须为 preview |
| `lib/live_main.dart` / live flavor | 同一个 LiveModel；IoTransport、FilePreferences、现有 WindowsHost/C++ HostBridge | 只编译检查，不由本轮脚本运行；要求 FREEV6_BACKEND=true，拒绝离线或 SAFE_MODE 构建 |

原生产 Tauri 入口和 A 工程继续保留，未切换安装、更新或发行默认入口。真实入口保持现有管理员宿主/helper 权限模型。`scripts/windows/check-flclash-backend.ps1` 不调用安装器、注册自启动或运行真实入口。

## 接入与功能映射

`lib/freev6/session.dart` 负责 FreeV6 ClientModel 与上游 providers/actions 的映射。现有 `../flutter_ui/lib/app/live_model.dart` 及 API、偏好校验器通过 path 依赖复用。两个 Windows runner 共同编译原来的 HostBridge 源码，未复制出第二套 helper 管理代码。Go 网络业务没有改动。

| 功能 | 接入与离线检查 |
| --- | --- |
| 启动/停止、教育网 IPv6、WARP、缺核心和错误提示 | 主按钮调用原 LiveModel 准备及启停；夹具检查 IPv6/核心失败不会到达 start，自动注册和状态反馈 |
| 规则/全局、开发者直连 | 映射原 settings；直连继续受 devMode 限制，保存失败不修改显示状态 |
| 接入点、链式、选择、搜索、排序、测速 | 保留上游完整列表交互；分组切换与选择串行等待后端，分别保留已加载分组，不注入演示节点；批量调用原六路并发实现 |
| 流量曲线、本月/累计与持久化 | 使用原采样、计数和偏好逻辑，保持旧版统计口径 |
| 校园白名单、链式 URL/文件、备用门户和公告门禁 | 原 helper API；输入对话框等待返回，失败保留草稿，门禁关闭启用/导入入口，来源和数量来自模型 |
| 核心下载、重试、WARP 重新注册 | 原下载器/注册器；显示进度与失败，连接中禁用会冲突的操作 |
| 自启、静默、自动运行、F6、热点 | 原设置事务与 C++ 宿主；验证 F6 冲突、保存失败回退及设置保留，离线 Host 不调用系统 |
| 关闭、托盘、退出、单实例、helper 退出 | 原 C++ HostBridge 负责，关闭请求经过原生宿主以保留托盘失败回退；退出事件由 UI 确认，停止/恢复未确认时不退出 |
| 外观、动态取色、纯黑、壁纸、玻璃、原生背景、减少动态效果 | 偏好事务成功后同步 Prism 主题；原宿主处理 DWM 模式及降级，壁纸由内存图片渲染 |
| 偏好迁移/导入/导出、重置、日志 | 原校验器与文件接口；新增日志导出复用原宿主文件选择，测试只读写创建的临时夹具目录 |
| 公告、关于、协议/隐私、反馈、许可证 | 原公告状态与外部打开接口；实际文案/链接和随附 GPL/Prism/包许可可查看 |
| 检查/忽略/下载/校验/更新 | 原更新后端和宿主 update.apply；停止失败阻止安装请求；夹具只记录调用，绝不启动安装器 |
| 自动准备/重试、helper 掉线 | 沿用原 LiveModel 轮询/取消与重试；离线验证掉线禁用连接、凭据刷新后恢复 |
| 万圣节 | 复用原日期判断和问候键；使用 Prism 提示/按钮，普通日期不改变布局 |

上游默认 Bootstrap、RustLib、Go 核心、服务、代理/自启/托盘管理器都不初始化。CoreController 始终注入拒绝调用的适配器；FreeV6 的生命周期仍归现有后端/Go helper 所有。上游额外 profile 修改、仪表盘布局编辑不属于 FreeV6 功能范围，在两个 FreeV6 构建标志下均关闭。离线和 live 的节点/模式展示保持同一 UI。

## 来源和构建

Flutter 固定 3.47.6，Windows 需 VS2022 C++ 桌面开发、Windows SDK、Python。依赖/引擎缓存准备好后，从仓库根执行：

```powershell
$env:FREEV6_FLUTTER_SDK = 'C:\tools\flutter'
.\scripts\windows\check-flclash-backend.ps1
```

脚本离线恢复锁定依赖，检查来源/边界，运行 B 和现有 A 的 analyze/测试，再编译 fixture 和 live。只启动带两个安全标志的 fixture `--host-probe`，检查完成即退出，不启动代理。缺依赖时明确失败，不下载。仅检查 Dart 可加 `-SkipBuild`。

fixture EXE 在 `build/windows/x64/fixture/runner/Release/freev6-flclash-offline.exe`；live 编译结果在 `build/windows/x64/live/runner/Release/freev6-desktop.exe`。保留所有 DLL/data；本轮离线交付不附带 helper、核心或安装器。CMake 的 install 阶段仅复制资源到工作区 Release，不是系统安装。

无符号链接权限时，`prepare-flclash-plugins.ps1` 创建依赖目录的 NTFS junction，不改 Developer Mode、不申请 UAC。

FlClash 固定 `be84736605527034689c95bf27828ff27d912c5e`，Prism 固定 `63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185`。保留 1389 个来源文件，39 处上游修改在 `vendor/FREEV6-PATCHES.json` 登记；第一方接入文件另列。保留完整许可证、来源、锁文件和未启用的核心桥接源码。代码生成只通过 `dart run intl_utils:generate`，未手改生成文件。仅简体中文开放；其他五种非英语语言的新词条暂为英语回退。

## 离线验证和限制

夹具使用真实 FreeV6 Dart 后端，验证实际请求地址、方法、认证、参数、状态和错误处理。Transport 只回答明确列出的合成请求，不创建 socket；Host 不创建进程、不打开浏览器、不改系统；MemoryPreferences 不读写用户配置。文件测试只使用新建临时目录。离线原生入口全局禁止 HttpClient，且仍拒绝调用上游核心。

相关测试覆盖真实 UI 表单失败/重试、分组先切换后选节点、六路测速、认证隔离、F6 回退、准备失败、公告门禁、下载失败、退出/更新停止保护、helper 掉线和偏好/文件操作；保留原明暗/宽窄/放大文字回归和上游相关回归。系统字体仅用于本地截图，不能打包。

本轮不做真实 Go 网络、校园/WARP 连通、DNS/ICS 恢复、系统托盘/F6/自启、安装升级、真实用户迁移、ARM64、读屏或完整上游套件验收。真实入口和共享宿主的源码/编译通过，不能替代这些实机结果。完成阶段与日志见 `docs/development/repository-maintenance.md`。
