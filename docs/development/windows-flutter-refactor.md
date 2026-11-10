# Windows Flutter 重构实施方案

2026-11-10 已确认：Windows 改用 Flutter + Windows 原生宿主，替换 Web UI / Tauri；首期保留 Go helper、现有网络实现和权限机制。界面风格及页面结构对齐当前 macOS 端，保留 Windows 原有功能，不以 Mac 全部功能为首期交付范围。

代码基线为 `81843cb`，Windows 版本为 0.5.3。W0–W4 已具备源码与本机检查；Windows 原生编译、安装和运行仍待验，生产入口保持 Tauri。用户追加确认：先在当前 Mac 完成各阶段源码与本机检查，随后由用户推送 GitHub，在 Windows 拉取、编译和验收；各阶段分别记录源码进度与原生待验项。

## 实施边界

- 保留 `cmd/freev6-helper`、`internal/` 的职责和 HTTP 接口；WARP 凭据、mihomo 生命周期、热点共享、DNS 快照与恢复仍由 Go 处理。
- 首期沿用主程序管理员启动、helper 继承权限的方式，不引入 Windows 常驻服务或改造权限模型。
- 主题、卡片、侧栏与页面组织对齐 Mac；窗口按钮、键盘操作、托盘、自启动、热点和安装流程采用 Windows 适配。
- Mac、Android 保持独立工程。首期按固定来源移植需要的 Flutter 组件，不移动现有 Mac 工程、不抽取全平台 UI 框架。
- 保留旧 UI 和构建入口，待新客户端功能、数据迁移和 Windows 安装验收通过后，再单独删除。机械复制、功能实现和删除分别提交。
- 不修改产品版本、不发布安装包，不触及 iOS 或 OpenWrt。

## 目标结构

以下目录为实施时新增的规划，不表示已经存在：

```text
apps/windows/flutter_ui/
  lib/
    app/                 页面导航、主题和应用状态
    components/          从 Mac 固定版本适配的视觉组件
    features/            仪表盘、节点、配置、日志、设置与引导
    backend/             helper、mihomo 控制器及模型转换
    platform/            原生宿主桥接与界面偏好存储
  windows/runner/        C++ 窗口、托盘、单实例、helper 生命周期
  test/                  合成数据、接口和组件回归
  vendor/                固定组件、许可证、来源及本地补丁记录
scripts/windows/         构建、隔离验证、安装包与升级检查
```

| 层 | 负责内容 | 边界 |
| --- | --- | --- |
| Flutter 页面和组件 | 呈现状态、输入、反馈和导航 | 页面不直接发 HTTP 请求或操作注册表 |
| Dart 应用模型与后端适配 | helper HTTP、mihomo 控制器 HTTP、轮询、命令和错误映射 | 使用可替换 transport；合成数据入口不得连接真实 helper |
| C++ Windows 宿主 | 窗口、托盘、F6、单实例、权限清单、helper 启停、安装器启动 | 提供小范围平台桥接，不照搬 Mac Swift 业务层 |
| 现有 Go helper | 配置持久化、资源准备、WARP、网络启停与恢复 | 保持现有接口及数据目录契约 |

Mac 的 [主题](../../apps/macos/flutter_ui/lib/app_theme.dart)、[仪表盘](../../apps/macos/flutter_ui/lib/dashboard.dart)和组件可作为视觉来源；[LiveModel](../../apps/macos/flutter_ui/lib/live/live_model.dart)依赖 Swift 快照、事件和命令协议，不能直接当作 Windows 后端。Windows 建立自身应用模型，向移植的组件提供所需状态，不用空实现伪装 XPC、Keychain 或服务安装能力。

移植时处理 `TargetPlatform.macOS`、Command 快捷键、Mac 窗口角色和平台文案。首期采用与 Mac 工程相同的 Flutter 3.47.6 固定版本，W1 在 Windows 验证工具链。保留 [FlClash / Prism 来源和本地补丁](../../apps/macos/flutter_ui/vendor/UPSTREAM.md)，并在 Windows 的来源清单中记录移植时的 Mac 提交和文件改动。

Flutter 的 Windows 工程使用可定制的 C++ runner，可通过平台通道连接 Dart；采用该官方宿主方式承接现有 Tauri 系统功能。[Windows 宿主说明](https://docs.flutter.dev/platform-integration/windows/building) · [平台通道](https://docs.flutter.dev/platform-integration/platform-channels)

## 功能迁移清单

下表为实现与验收范围；对应源码已接入，Windows 实机结果按[验收手册](windows-flutter-acceptance.md)记录。Mac 中没有的 Windows 功能仍保留入口；Mac 中有而当前 Windows 没有的能力不自动扩展为首期需求。

| 新入口 | 必须保留的 Windows 行为 | 当前依据 |
| --- | --- | --- |
| 仪表盘 | 启停、进行中状态、错误反馈、规则/全局/开发者直连模式 | `startProxyFlow`、`setMode`、`pollStatus` |
| 仪表盘流量 | 速率曲线、本次/本月/累计统计和重启后的历史 | `pollTraffic`、`trafficStats`；保持现有统计口径 |
| 节点 | 接入点/链式分组、选择节点、延迟测试、排序、启动后自动测速 | `fetchProxies`、`switchProxy`、`runDelayTest` |
| 配置 | 校园网白名单编辑、链式代理 URL/文件导入、启用与清除 | `wireSettingsEvents`、`chainProxy` |
| 配置 | 备用配置门户、启用/清除、来源摘要、公告门禁和失败提示 | `cloudConfig`、`cloudReady` |
| 设置及首次准备 | 核心检测、下载进度、失败重试、WARP 注册/重新注册及自动注册 | `/runtime/*`、`/warp/register`、`maybeAutoRegisterWarp` |
| 设置通用 | 开机自启、静默启动、自动运行、F6、重置设置和失败回退 | `persistSettings`、`hotkey_set`、`resetSettings` |
| 设置网络 | 移动热点共享、当前共享状态、断开后下次启动生效提示 | `hotspotShare`、`reportHotspotResult`、`pollStatus` |
| 设置外观 | 系统/明/暗主题、动态取色、纯黑、壁纸、默认/亚克力/云母背景、玻璃效果 | `loadAppearancePrefs`、`loadBackgroundPrefs`、`set_background` |
| 日志 | 现有操作记录、错误提示和 helper 异常诊断 | `addLog`、`renderLogs`、宿主 `helper.log`；不承诺 Mac 的全部日志能力 |
| 公告和关于 | 已读状态、公告详情、说明/反馈/仓库/许可入口 | `checkNotice`、`openExternal`、关于设置 |
| 更新 | 自动检查、版本忽略、下载进度、摘要校验、安装及重启 | `/update/*`、`update_apply` |
| 引导 | 首次欢迎、老用户识别、缺核心和网络条件提示、注册失败重试 | `guideSeen`、`detectPublicIPv6`、现有弹窗 |
| 窗口与托盘 | 拖动/缩放/最大化、关闭到托盘、显示主窗、退出选择 | Tauri 窗口命令及 `handleTrayQuit` |
| 自动行为 | 自动启动重试、联网恢复重试、helper 断线反馈、单实例 | `autoRun`、宿主启动逻辑 |
| 季节外观 | 10 月 31 日本地日期触发的装饰、一次问候和点击反馈 | `halloween.js`；用合成日期验证，视觉适配新主题 |

“保留功能”包括现有外观选项，但不要求复刻旧 Material Web 的组件形状。背景能力不支持时按现有降级规则反馈实际生效模式。若新渲染器无法达到该能力，应保留为未完成项，不在迁移中静默移除。

## 接口基线

### helper HTTP

地址为 `http://127.0.0.1:<本次启动端口>/api/v1`。原生宿主产生本次启动的 bearer token，通过 `FREEV6_API_TOKEN` 传给 helper；`FREEV6_API_PORT` 指定端口，`FREEV6_ROOT` 指定运行根目录。无有效 token 时仍拒绝请求。历史端口 13335 仅是现有回退约定，不应在新界面中写成固定连接地址。

| 路径 | 方法 | 用途与返回要点 |
| --- | --- | --- |
| `/status` | GET | helper 状态、管理员状态、proxy、warp、settings、hotspot、controllerSecret |
| `/runtime` | GET | 核心存在性、平台与架构 |
| `/appearance` | GET | 系统动态取色来源 |
| `/runtime/download` | POST | 启动后台核心下载 |
| `/runtime/download/progress` | GET | 下载状态、字节计数、版本、结果与错误 |
| `/settings` | GET / PUT | 直接返回设置对象；不要假定包装为 `{settings: ...}` |
| `/settings/reset` | POST | 重置设置、撤销自启、移除链式/备用配置；不是清空全部用户数据 |
| `/proxy/start` | POST | 输入 `mode`、`campusCidrs`、`devMode`，其余从已保存配置读取 |
| `/proxy/stop` | POST | 停止与恢复；处理 HTTP 错误及成功响应中的 `restoreSkipped` |
| `/warp/register` | POST | 输入注册名称，保留 `freev6-windows` 默认值；凭据留在 helper |
| `/update/latest` | GET | 发行版本和下载信息 |
| `/update/download` | PUT | 输入 `url`、`sha256`，由 helper 下载校验 |
| `/update/progress` | GET | 下载状态、完成路径与错误 |
| `/notice` | GET | 公告、缓存及备用配置门禁 |
| `/chain-proxy` | GET / PUT / DELETE | 摘要；URL/内容导入；清除 |
| `/cloud-config` | GET / PUT / DELETE | 摘要及门禁；门户/来源导入；清除 |

接口事实以 [helper 主入口](../../cmd/freev6-helper/main.go)、[链式代理](../../cmd/freev6-helper/chain.go)、[备用配置](../../cmd/freev6-helper/cloudconfig.go)和[更新处理](../../cmd/freev6-helper/update.go)为准。W1 用合成响应补齐 Dart 解码样本，包括非统一返回结构和机器可读 `code`；不抓取真实配置或凭据作为夹具。

### mihomo 控制器和外部检测

旧前端并非所有操作都走 helper；以下请求目前直接访问 `http://127.0.0.1:9090`，鉴权使用 `/status` 返回的 `controllerSecret`，与 helper token 分开。首期把它们集中在 Windows Dart 后端适配中，保持现有控制路径。

| 接口 | 方法 | 行为 |
| --- | --- | --- |
| `/connections` | GET | 流量采样，保留现有累计方式 |
| `/proxies` | GET | 获取分组与节点 |
| `/proxies/<分组>` | PUT | `{name: 节点名}`；分组和节点按当前 UTF-8 名称处理 |
| `/proxies/<节点>/delay` | GET | 现有 5 秒超时、检测地址及最多 6 个并发任务 |

接入分组 `♻️ 自动选择` 和链式分组 `🔗 链式代理` 与 Go 配置生成一致。生产前端还有公网 IPv6 检测和网络恢复触发逻辑；迁移时保留，自动测试一律注入 transport、时钟和网络事件，不访问真实端点。

### 原生宿主

| 现有职责 | 新宿主必须承接的契约 |
| --- | --- |
| `get_api_token`、`get_helper_port` | 启动参数由宿主管理；Dart 获取同一实例的连接信息 |
| `window_minimize`、`window_toggle_maximize`、`window_maximized`、`window_start_dragging` | Windows 标题栏、命中区域和窗口状态同步 |
| `window_close`、`window_show` | 关闭隐藏到托盘；托盘/F6 能恢复主窗 |
| `app_quit`、托盘退出 | 运行中显示取消/停止并退出；停止失败时继续显示错误；未运行时直接退出 |
| `hotkey_set` | 原生线程接收 F6；冲突/超时返回失败，界面恢复原设置 |
| `set_background` | 返回实际应用的背景，处理降级和明暗切换 |
| `update_apply` | 承接 helper 校验完成的安装包、原有静默参数、退出和重新启动流程 |
| helper 监督 | 生成 token、传入环境变量、观察子进程退出、记录有界诊断；关闭本实例拥有的 helper |
| 单实例与自启动 | 与旧程序互斥；尊重任务管理器的禁用状态及 `--autostart`、静默设置 |

当前运行中的退出弹窗仅提供“取消”和“停止并退出”，须等待 `/proxy/stop` 成功；`quitDirectly` 用于未运行的退出路径，不是运行中的用户选项。迁移不能把杀掉 helper 当作已恢复系统网络。[当前宿主](../../apps/windows/src-tauri/src/main.rs)和[前端流程](../../apps/windows/web/app.js)是行为基线。

应用状态模型需要区分连接中、运行中、停止中、helper 离线和失败，保留设置写入序号与启停操作序号的竞态保护；停止后迟到的状态、流量和测速结果不能恢复旧界面。初始轮询基线为状态 3 秒、流量 1 秒、节点 5 秒；隐藏到托盘不能意外取消自动运行和退出响应。

## 数据与安装兼容

### 安装身份及 helper 数据

首期保持 `freev6-desktop.exe`、`freev6-helper.exe`、安装根目录和现有 helper 数据布局。自启动代码直接拼接主程序文件名；改名会破坏任务调度。新旧主程序沿用 `Local\freev6-desktop-single-instance` 的互斥名称，避免同时管理同一份网络状态。

保留根目录下的 `config/`、`state/` 和 `runtime/`，包括设置、WARP 凭据、链式/备用配置、控制器 secret、网络快照和 PID。新 Flutter 偏好文件使用单独命名，不覆盖 helper 文件。开发及演示使用独立身份与合成数据目录，真实运行配置不进入仓库或可清理的构建缓存。

Flutter 不会自动继承 Tauri NSIS 模板。后续独立安装脚本需核对原有应用身份 `dev.freev6.desktop`、实际卸载登记、安装路径、协议页、自启动任务、文件占用处理及“删除应用数据”的选择。迁移 [NSIS hooks](../../apps/windows/src-tauri/nsis-hooks.nsh)时必须处理它对 Tauri 模板变量和插件的依赖，不能直接复制即视为可用。

保留 `version.json` 字段、发行仓库、下载验证和 `/S /FREEV6REL` 更新链路。切换发行入口时同步更新 `scripts/version.py`、仓库检查、许可打包和源码清单；在切换前仍以 Tauri/Cargo 0.5.3 为当前版本来源，新工程不能私自形成第二套产品版本。

### WebView 本地数据

以下数据在 `localStorage`，不在 helper 的 `settings.json` 中。必须有迁移实现和升级验证，不能仅保存 helper 目录就声称用户数据完整。

| 键 | 迁移内容 |
| --- | --- |
| `freev6-traffic-stats` | 累计与按月上下行计数，保留历史且幂等导入 |
| `freev6-theme`、`freev6-dynamic-color`、`freev6-pure-black` | 明暗偏好、动态取色和纯黑 |
| `freev6-bg-mode`、`freev6-webgl-glass`、`freev6-wallpaper` | 背景模式、玻璃开关和壁纸内容 |
| `freev6-guide-done` | 首次引导完成标记 |
| `freev6-skip-version` | 忽略版本 |
| `freev6-notice-read` | 已读公告 ID |
| `freev6-halloween-force`、`freev6-halloween-greeted` | 季节效果调试值与问候日期 |

W1 先在 Windows 合成用户配置中定位旧 WebView profile、origin 与存储，验证一次性兼容读取或旧 UI 导出再导入的路径；不直接假设 Flutter 偏好插件能读取 WebView 数据。若采用 WebView 兼容读取，只读取允许清单，不执行会自动连接和注册的旧 `app.js`。导入使用版本标记和原子写入，成功后不重复累加流量，不删除旧数据；失败可重试并给出反馈。若必须要求用户先运行过渡版本或手动导出，在正式切换方案中单独明确这一用户步骤。

此迁移路线尚未在 Windows 验证，是发行切换前必须关闭的事项，不阻止先做合成数据界面。

## 分阶段实施与完成条件

| 阶段 | 交付 | 完成条件 |
| --- | --- | --- |
| W0 准备 | 已确认范围、功能/接口清单、数据和安装约束、验证边界 | 本方案和旧前端基线检查完成；本次交付 |
| W1 工程与兼容性验证 | 独立 Flutter Windows 工程、固定依赖、演示入口、宿主最小桥接、来源记录；验证旧存储迁移及 NSIS 身份 | Mac 上 Dart analyze/test 通过；Windows runner 编译；确定数据读取方式和安装兼容路线 |
| W2 界面 | Mac 风格侧栏、仪表盘、节点、配置、日志、设置；Windows 特有选项 | 通过合成状态的组件/视觉检查，所有功能有明确入口和行为；演示不联网 |
| W3 接口与宿主 | 接入 helper/控制器、轮询、启动/退出、托盘、F6、自启动和外观 | 隔离接口测试覆盖故障与竞态；Windows 原生宿主测试通过 |
| W4 数据与安装 | 偏好迁移、独立 NSIS、旧版升级/回退、更新链路、许可和源码打包 | 在 Windows 隔离安装目录验证数据、身份和文件兼容；运行功能另做人工验收 |
| W5 切换与清理 | 正式构建指向 Flutter，版本读取和检查同步；单独提交删除旧 Web/Tauri | 功能矩阵逐项通过、升级与原生验收记录齐全；先切换再删除 |

按用户追加的交付安排，先在 Mac 连续完成 W1–W4 源码并逐阶段汇报；Windows 编译与系统验证由用户后续集中执行，其待验状态不能计作通过。W5 的正式入口切换和旧代码删除仍以原生验收通过为条件。默认预览使用独立身份；live 候选保留生产身份，用于用户在 Windows 手动验证升级。Mac 本机不替换用户安装。每阶段将结果与未验证项记入 [仓库维护记录](repository-maintenance.md)。

## 验证安排

### 本次准备的基线

可在当前 Mac 工作区运行以下无真实联网检查：

```sh
python3 scripts/maintenance/check-repository.py
node --test scripts/windows/test-web-runtime.mjs
node --experimental-vm-modules scripts/check-web-modules.mjs
node --check apps/windows/web/app.js
git diff --check
```

现有 4 项前端测试覆盖动态端口与 bearer、浏览器/旧壳回退、token 更新后仅重试一次、停止后的迟到状态。它们是传输与竞态基线，不表示所有页面、安装或系统功能已验证。本阶段仅变更开发文档，未执行 Flutter、Rust、Go 构建或 Windows 安装验收。

### 实施阶段的隔离测试

- Dart：响应解码、鉴权重试、失败回退、设置保存/轮询交错、停止后迟到结果、自动注册和自动启动次数限制、缺核心、下载失败、门禁和热点状态。
- UI：断开/连接/准备中/失败、空节点/多节点/导入失败、长中文和特殊字符、明暗主题、缩放和键盘操作；Mac 布局对齐与 Windows 标题栏分别检查。
- 数据：旧偏好缺失、损坏、壁纸大小边界、重复导入、流量历史保持、导入中断后恢复。只用合成数据。
- 原生：helper 用无网络子进程夹具；托盘/单实例/快捷键使用测试身份，文件与安装器使用隔离夹具，不结束用户进程、不注册正式自启动任务。
- 如确需修改共享 Go，再执行根源码和受影响平台检查，含 Android 嵌套 Go 模块；不能只验证 Windows Flutter。

### Windows 配合验收

W1 记录用户电脑的系统版本、CPU 架构和工具链；首期沿用当前 x64 发行目标，不额外承诺 ARM64。Windows 10/11 具体系统和显示缩放覆盖在结果中逐项注明。

| 类别 | 验收内容 |
| --- | --- |
| 构建 | 固定 Flutter、C++ runner、helper、NSIS 均成功；版本与许可材料一致 |
| 窗口 | DPI/缩放、多显示器、拖动/最大化、关闭到托盘、F6 与占用失败 |
| 启动 | 管理员启动及取消、静默/自启、任务管理器禁用、重复启动、helper 缺失/退出 |
| 数据与安装 | 0.5.3 升级、新装、含空格/中文路径、旧偏好迁移、回退、卸载保留/清理选择 |
| 运行功能 | 用户配合单独执行连接、切换节点、热点共享、停止和网络恢复、自动重试 |
| 更新 | 下载失败、摘要不符、启动安装器失败、静默安装重启、旧进程释放 |

仓库自动检查不启动真实网络、不触碰用户的当前连接和进程。真实网络、热点和安装验收由 Windows 环境单独执行并记录；Mac 上的静态或交叉编译结果不能替代它们。


## 本轮源码交付

W1：独立 Flutter 工程、固定 SDK/锁文件/来源记录；W2：Mac 风格页面与 Windows 功能入口；W3：真实接口、原生宿主、状态与错误流程；W4：偏好导出/导入、独立 NSIS、构建和许可/源码配对。实现和本机测试结果见[维护记录](repository-maintenance.md)，Windows 执行步骤见[验收手册](windows-flutter-acceptance.md)。

UI 偏好迁移采用显式导出/导入，不猜测或直接解析 WebView LevelDB。已发布旧二进制没有导出入口时，需要带导出入口的旧 Tauri 构建；也可先保留原 profile，完成网络数据兼容验收后再迁移 UI 历史。此限制不得表述为自动迁移已完成。W5 未执行，旧实现尚未删除。
