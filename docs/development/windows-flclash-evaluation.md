# Windows 路线评估：直接改造 FlClash 与当前 Mac 界面移植

日期：2026-11-10。状态：用户已验收 B 的界面并批准接入现有后端；实现在 [FlClash Windows 客户端](../../apps/windows/flclash_ui/DEVELOPMENT.md)，先做离线验证。生产切换、安装和真实联网尚未授权。以下保留当时的评估依据。

本轮仅阅读本仓库和官方上游源码、发布信息，整理方案。没有启动 FlClash、真实 FreeV6 客户端、helper 或代理，没有安装软件、注册服务、调整自启动或修改系统网络。GitHub 源码查询不涉及代理功能验收。

## 建议

建议先验证路线 B 的离线原型，保留路线 A 作为可回退的已编译基线。原型通过界面验收和适配验证后，再决定是否把 B 作为正式实现。

- **A：继续当前路线。** 以 FreeV6 Mac 端移植的 Flutter/Prism 组件为基础，维护自己的 Windows 页面、应用状态和 C++ 宿主。
- **B：以 FlClash Windows 发布源码为主工程。** 保留其完整主题、导航、页面布局、交互与合适的桌面组件；接入 FreeV6 现有 Dart 后端、Go helper 和 mihomo 控制器，替换上游默认业务及系统操作的接入。

B 的原型应证明可以保留完整应用界面，不能最后又退化为只复制几个卡片。保留 FreeV6 功能也不要求引入 FlClash 的全部额外功能。若原型发现必须重写 FreeV6 网络业务或大面积伪装上游核心接口，应停止扩展 B，并重新评估；不因为已投入原型就强行切换。

当前 UI 的问题不足以证明现有业务架构应被替换。此前自行修改侧栏、配色、控件比例造成的偏差属于实现问题，A 也能修正。B 的主要价值是采用完整产品界面，减少自行拼装和偏离设计的空间。

## 已核实的基线

1. 官方最新稳定发布为 [FlClash v0.9.3](https://github.com/chen08209/FlClash/releases/tag/v0.9.3)，2026-11-04 发布，提供 Windows x64、ARM64 的安装包和 portable ZIP。固定提交为 `be84736605527034689c95bf27828ff27d912c5e`，不是跟随不断变化的 main。
2. FreeV6 当前 `vendor/UPSTREAM.json` 中 FlClash 来源就是该提交；Prism UI 来源 `63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185` 也与该版上游子模块一致。两条路线的差别主要在完整应用、页面和状态接入，不能解释为升级到一套更新的组件。
3. FlClash 的 Windows 和 macOS 共享 Flutter/Prism 应用层，Windows 有自己的 runner、窗口与托盘插件。采用其 Windows 版本并不意味着改用 WinUI/原生 Fluent 控件。[应用层](https://github.com/chen08209/FlClash/blob/v0.9.3/lib/application.dart) · [Windows runner](https://github.com/chen08209/FlClash/blob/v0.9.3/windows/runner/main.cpp)
4. 完整上游还包括自己的 Go 核心、Rust IPC/快捷键等库、Windows helper service、Riverpod 状态、配置数据库及安装升级流程，不是只有视觉组件。[依赖](https://github.com/chen08209/FlClash/blob/v0.9.3/pubspec.yaml) · [核心接口](https://github.com/chen08209/FlClash/blob/v0.9.3/lib/core/interface.dart)
5. A 已有 35 项 Flutter 离线回归、明暗/窄窗口截图检查、Windows x64 预览和 live 编译、helper 与候选包构建记录。安装、托盘、F6、自启动仍未完成系统级验收；模拟开关、桥接探针不能替代。先前产物在 `dist/windows/0.5.3-flutter/` 和 `dist/windows/ui-preview-mac-aligned/`，版本和源码快照应分别识别。

本评估没有在本机编译完整上游、制作 B 原型或运行上游发行二进制。可行性结论来自源码结构；复用效果、完整依赖可用性和工期仍须原型核实。用户已告知桌面解锁；本轮按新请求评估路线，没有继续原生 UI 操作。

## 两条路线的区别

| 项目 | A：继续当前路线 | B：直接改造 FlClash Windows |
| --- | --- | --- |
| 界面与交互 | 已复用组件；页面、设置、工具栏和状态交互由 FreeV6 自己组合维护 | 从完整主题、导航、页面与交互起步；FreeV6 专用页面按上游组件规范补充 |
| 与原版 FlClash 的一致性 | 需要逐页对照；当前目标原本是 FreeV6 Mac 界面 | 初始一致性更高；接入业务后仍需截图和交互回归，不能保证自动保持 |
| FreeV6 业务复用 | 现有 Dart 模型、Go helper 和 C++ 桥接可继续使用 | Go 业务可保留；Dart 状态需映射到上游 providers/actions；原生桥接需整合 |
| 核心与权限 | 已实现主程序管理员启动、helper 继承权限及现有 mihomo 生命周期 | 必须绕开上游默认核心、IPC 和 helper service；首期仍保留 FreeV6 权限模型 |
| Windows 桌面能力 | 当前宿主已有源码和编译结果，但系统行为待验 | 上游有现成窗口/托盘组件；F6、自启动、退出恢复和单实例须按 FreeV6 契约适配、重新验收 |
| 构建链 | Flutter、MSVC、Go、Python、NSIS 已完成本机准备 | 完整上游另用 Rust、MinGW-w64、Inno Setup；采用现有 helper/NSIS 后能省多少需验证 |
| 依赖与维护 | 应用依赖少；自行维护 UI 和固定组件的更新 | 引入更多应用依赖；可跟进整套上游 UI，但业务接入处与生成代码增加合并成本 |
| 已有验证可复用性 | 当前检查直接适用；未验系统项继续补齐 | Go 业务测试和协议夹具可复用；Flutter 接入、runner、系统集成、安装需重新验证 |
| 主要风险 | 自行组装造成视觉或行为偏差；系统验收尚未闭环 | 默认后台行为未切干净；双核心/双系统操作；状态语义和数据目录不一致 |
| 适合目标 | 尽快交付兼容现有 FreeV6 的 Windows 客户端 | 明确希望以 FlClash Windows 完整体验为界面基线，并接受额外接入工作 |

上游[构建说明](https://github.com/chen08209/FlClash/blob/v0.9.3/README.md#build-from-source)和[构建 hooks](https://github.com/chen08209/FlClash/blob/v0.9.3/plugins/setup/setup_hooks/lib/src/build.dart)确认了额外工具和产物。不能把未经验证的裁剪计作已经节省的依赖，也不应为首期需要之外的功能盲目补齐全部上游运行栈。

## 功能保留映射

以下是两条路线都必须满足的契约。A 多数已接入，但系统结果待验；B 的说明是改造计划，不是已实现声明。更完整的原有清单仍见 [Windows Flutter 重构方案](windows-flutter-refactor.md#功能迁移清单)。

| FreeV6 现有功能 | A 的接入 | B 必须怎样保留 |
| --- | --- | --- |
| WARP 注册/重新注册、教育网 IPv6 检查、自动准备 | `LiveModel` + helper | 复用现有准备及启动流程；主按钮调用该流程，不能直连 FlClash 的启动 action |
| 规则/全局模式、开发者直连 | 现有设置与模式组件 | 上游模式 UI 映射现有设置；直连仍受开发者模式控制，不默认开放 |
| 节点与链式分组、切换、延迟、排序、最多 6 路延迟测试 | helper + mihomo 控制器及 Dart 状态 | 将控制器结果转换为上游显示模型；保留中文/斜杠名称、失败回退和旧响应丢弃 |
| 流量曲线、本月/累计统计和历史 | 现有采样与偏好持久化 | 复用现有计数及持久化口径，接到上游卡片；不能用上游本次进程流量替换全部历史 |
| 校园网绕过列表、链式 URL/文件导入 | helper 的设置及 chain API | 保留专用配置页，以其原有 API 导入/清除；不交给上游通用 profile 编辑器重写 |
| 备用配置门户、启用/清除、公告门禁 | cloud/notice API | 保留来源、门禁和错误提示；不能因为上游允许导入 profile 而绕过门禁 |
| 核心检测、下载进度与重试 | runtime API | 保留 FreeV6 核心版本和下载器，不随上游启动 hooks 自动替换核心 |
| 自动运行、启动重试、联网恢复、helper 断线反馈 | 现有 `LiveModel` | 复用重试、状态和取消逻辑；切断上游的另一套启动/恢复任务 |
| 热点共享、DNS/ICS 快照与恢复、失败反馈 | Go helper 和 `internal/network` | 全部继续由 FreeV6 管理；UI 只显示及提交设置，不并行启用上游系统代理/TUN 操作 |
| F6 显示窗口、占用报错与开关回退 | 现有 C++ `RegisterHotKey` | 单键 F6 单独接现有实现或适配上游注册层；只保留一个注册者 |
| 自启动、静默、Task Manager 禁用 | helper 计划任务 + Run 标记 + StartupApproved | 保留现有协议与 `--autostart` 参数；关闭上游默认自启动写入，避免重复启动 |
| 窗口、托盘、单实例、退出前停止及停止失败不退出 | 当前 C++ 宿主和 Dart 退出流程 | 整合窗口/托盘事件；退出始终先走 FreeV6 停止流程，不能只关上游核心后退出 |
| 主题、动态色、纯黑、壁纸、玻璃、Mica/Acrylic、减少动态效果 | 当前偏好和原生背景接口 | 映射到上游主题；保留背景选项与 Win10 回退，未能支持的能力明确列为缺口 |
| 公告已读、更新忽略/进度/校验/安装 | 当前 notice/update API + 原生安装器启动 | 保留 FreeV6 版本源、下载校验、停止失败阻止安装；关闭上游更新通道 |
| 界面备份、旧 Web 迁移、重置、引导、季节外观 | 现有偏好校验/存储及页面 | 复用现有格式和迁移器；保留缺核心/注册失败提示及本地日期触发，不重新导出凭据 |
| 安装升级、卸载保留数据、许可和对应源码 | 现有 NSIS 与源码快照脚本 | 首期保留 FreeV6 程序名、安装身份、目录、升级和卸载契约，适配新 Flutter 产物 |

FreeV6 的 WARP、链式、备用配置及网络快照可直接从 `cmd/freev6-helper/main.go`、`chain.go`、`cloudconfig.go` 和 `internal/network/` 核实。现有 Dart 后端入口是 `apps/windows/flutter_ui/lib/backend/api.dart` 与 `lib/app/live_model.dart`，原生接口是 `lib/platform/windows_host.dart` 和 `windows/runner/host_bridge.cpp`。

## 会影响改造量的具体差异

### 核心接口可替换，但不是简单替换 HTTP 地址

上游有 `CoreHandlerInterface`，`CoreController.scoped` 和 `coreHandlerProvider` 提供注入入口，因此存在可试验的适配边界。[Controller](https://github.com/chen08209/FlClash/blob/v0.9.3/lib/core/controller.dart) · [Provider](https://github.com/chen08209/FlClash/blob/v0.9.3/lib/providers/core.dart)

但是，节点 action 依赖上游 profile 的 selectedMap，配置 action 会构建/下发上游配置，事件与状态也使用其模型。FreeV6 则通过有鉴权的 helper API 管理业务，通过 mihomo HTTP 控制器选点、测延迟和取流量。原型必须实证模型和命令转换，不能给未支持的 Core 方法返回空值来假装兼容。[节点 action](https://github.com/chen08209/FlClash/blob/v0.9.3/lib/providers/actions/proxies.dart) · [配置 action](https://github.com/chen08209/FlClash/blob/v0.9.3/lib/providers/actions/setup.dart)

### F6、自启动和权限不可直接套用

- 上游 `HotKeyActionExt.toHotKeySpec()` 会排除 `modifiers.isEmpty`，所以 FreeV6 的单键 F6 不能直接作为现成配置迁入。[快捷键源码](https://github.com/chen08209/FlClash/blob/v0.9.3/lib/manager/hotkey_manager.dart#L30-L42)
- 上游自启动由 `launch_at_startup` 控制；FreeV6 是高权限登录计划任务、Run 标记及 Task Manager 禁用状态配合，直接用上游开关会改变行为。[上游自启动](https://github.com/chen08209/FlClash/blob/v0.9.3/lib/common/launch.dart) · 本仓库 `cmd/freev6-helper/autostart.go`。
- 上游 Windows 的 TUN 授权走 `FlClashHelperService`；FreeV6 当前是主程序管理员启动、自己的 helper 继承权限。首期继续后者，不同时引入常驻服务和权限模型重构。[上游授权](https://github.com/chen08209/FlClash/blob/v0.9.3/lib/common/system.dart#L213-L219) · [上游 Windows service](https://github.com/chen08209/FlClash/blob/v0.9.3/services/helper/src/service/windows.rs)

### 默认启动及持久化要先隔离

上游 bootstrap 会自动更新 profile、检查应用更新、同步自启动并启动其核心；应用层还会定时更新资源。`SAFE_MODE` 不能单独证明这些流程都已离线。B 的第一次可执行预览必须使用单独入口、内存数据、替换后的任务调度和拒绝外部请求的 transport，不运行原版启动流程来试错。[启动流程](https://github.com/chen08209/FlClash/blob/v0.9.3/lib/bootstrap.dart#L150-L177) · [应用任务](https://github.com/chen08209/FlClash/blob/v0.9.3/lib/application.dart)

上游用应用支持目录和 `database.sqlite`；FreeV6 用现有安装根目录下的 `config/state/runtime` 及已实现的界面偏好文件。B 保留 FreeV6 凭据和业务数据位置，视图缓存可独立存放；不把 WARP 或运行密钥写进上游 profile 数据库。[上游路径](https://github.com/chen08209/FlClash/blob/v0.9.3/lib/common/path.dart)

### 安装器与更新不能直接换标识

上游 Inno 模板包含按进程名终止程序、卸载自己的 helper service 和清理系统代理的流程；与 FreeV6 现有身份及停止恢复契约不同。B 首期使用现有 NSIS，不执行这些上游安装逻辑，也不影响用户独立安装的 FlClash。[上游模板](https://github.com/chen08209/FlClash/blob/v0.9.3/windows/packaging/exe/inno_setup.iss#L58-L80)

## 建议实施步骤和通过条件

以下为待批准的实施方案，本轮不执行。优先级始终为先审阅 UI，再进行安装和系统行为验收。

| 阶段 | 做什么 | 可以进入下一步的证据 |
| --- | --- | --- |
| B0：离线可行性原型 | 固定 v0.9.3 及子模块；隔离初始化和后台任务；保留完整导航/主题；接入合成状态及少量 FreeV6 命令夹具 | 无上游核心/service 进程、无真实网络请求；仪表盘、节点、配置、日志、设置可导航；主按钮、选点、设置写入可追踪到夹具；列出实际改动边界和依赖 |
| B1：UI 验收 | 展示真实 Windows 原生窗口；检查明暗、720×480、宽窗口、200% DPI、中文长名称/空/错误/忙碌/大列表及键盘操作 | 用户确认整体界面；页面没有临时混搭主题；截图来自可见应用，不以锁屏或单纯渲染替代原生观察 |
| B2：FreeV6 业务接入 | 复用现有 helper/controller 适配、凭据和偏好迁移，完成上表所有入口 | 合成数据和回环夹具覆盖成功、失败、取消、旧响应、门禁和恢复错误；无缺失功能、无两个组件写同一状态 |
| B3：系统功能与交付 | UI 验收后，使用受控离线夹具验证窗口/托盘/F6/自启动、安装升级和源码包 | 每项有原生证据；任务/Run/托盘/快捷键各只有一个拥有者；保持旧数据、卸载回退与校验有效 |
| 联网阶段：单独待办 | 实际教育网 IPv6、WARP、连接/停止、ICS/DNS 与恢复 | 只有用户以后明确授权后才进行；此前一律不能宣称联网验收通过 |

B0 必须先证明完整页面能够与默认核心、自动更新及系统代理操作隔离。若只能运行静态图片、必须启动上游核心才能打开主要页面，或需要重写 FreeV6 网络层才能继续，则未通过；带回具体依赖和新估算，不继续扩大迁移。

候选目录建议 `apps/windows/flclash_ui/`，与 `apps/windows/flutter_ui/` 分开。经路线决定后才创建；保留旧 Tauri 生产入口及 A 的源码/已核实产物。分阶段使用 `feat/`、`refactor/` 短期分支，机械引入、业务接入、生产切换和删除分开，不在本轮改默认构建或版本源。

## 工作量估算

以下是单名熟悉 Flutter/Windows 的开发者的有效人日区间，不是已验证排期，也不是 Codex 的运行时间承诺；不含等待用户验收、签名发布、依赖下载等待或真实校园网验证。静态评估仍有较大不确定性，B0 后重新估算。

| 工作包 | A | B |
| --- | --- | --- |
| 界面核对/原型与 UI 验收准备 | 1–2 | 1–2（B0）+ 1–2（完整界面适配） |
| 业务与状态接入回归 | 0.5–1.5 | 3–5 |
| Windows 系统、旧数据、安装升级验收及修复 | 1.5–3.5 | 2–4 |
| 离线完整回归、许可与交付整理 | 0.5–1 | 1–2 |
| 合计，按区间取整 | 约 4–8 人日 | 约 8–15 人日；B0 包含在内 |

B 的区间按能够隔离业务边界、复用现有 helper 和安装流程的推荐范围估算。若保留完整 FlClash Core/Rust service 并把 FreeV6 业务搬进去，已超出上述估算，需另立方案。不能把 UI 原型的完成时间当成全部 FreeV6 功能交付时间。A 已完成的检查可以降低后续工作，但尚未通过的系统项不能按零工作量计入。

## 维护、许可与未解决事项

- 保留上游 GPLv3 许可、第三方许可、原始提交和本地补丁记录，随二进制交付匹配源码；不删除作者版权信息。[上游 LICENSE](https://github.com/chen08209/FlClash/blob/v0.9.3/LICENSE)
- B 的 UI 更新可以从完整上游变更中合并，但 providers/actions、数据库假设和生命周期的冲突仍需维护；不能承诺比 A 更省维护。
- 尚待 B0 核实：需要启用的上游 provider 数量、Rust 能力是否确有运行依赖、工具链可裁剪范围、现有 C++ 桥接与上游窗口/托盘插件的边界，以及大列表与 DPI 的实际效果。
- B 的功能范围以 FreeV6 现有行为为准；FlClash 额外的任意配置编辑、脚本、WebDAV、DNS/连接高级页面和服务检测不默认纳入。未接入的额外功能不展示可点击的假入口；不得借此减少 FreeV6 既有功能。
- 本轮不切换路线、不修改应用源码、不启动真实联网。下一次实施应先读本方案与上游开发指引，完成 B0 后报告实际结果，再决定后续阶段。
