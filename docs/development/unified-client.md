# Flux6 统一客户端迁移

## 0.2.0 实现

Android arm64、macOS arm64 和 Windows x64 的当前构建入口都使用 `apps/android` 内的 FlClash v0.9.5 派生应用和固定版本的 mihomo。Android 使用 ServiceState，两个桌面端使用 FlClash 的原生运行机制。首次同意后自动准备 WARP 配置并写入本机凭据存储，连接由用户发起。默认接入点需要 IPv6 出口，客户端接受校园内外的可用网络。

升级后从空的应用配置开始。桌面 0.1.x 的 XPC 服务、Windows Go helper、热点与自动启动配置的接管均已结束。升级前应先从原客户端断开连接并退出。以下为 0.1.x 候选项目的历史记录。

目标是让 Windows x64、macOS arm64 和 Android arm64 从同一个 FlClash 派生工程构建。公共页面、状态和 Flux6 业务流程共用一份实现。各端正式入口按平台验收结果分别切换。

## 候选源码与选择依据

| 来源 | 已核实的内容 | 用途 |
| --- | --- | --- |
| Flux6 主线 `dc2d402`、正式标签 `v0.1.2` | 三个独立的正式入口、升级通道和对应源码打包脚本 | 主线用于移植；已发布版用于升级验收 |
| FlClash v0.9.3，`be84736605527034689c95bf27828ff27d912c5e` | Android 和历史 Windows 原型记录了同一上游提交，Prism 固定为 `63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185` | 比较 Android 改动与 Windows 在制改动的共同参照 |
| [Android 导出](../../apps/android/FREEV6.md) | 含 Flutter、Android 服务、嵌套核心及 Flux6 接入；已裁剪桌面 runner | 迁入 Android 的产品功能和原生生命周期 |
| 归档标签 `archive/windows-flclash-prototype-20261115`，提交 `9290f22` | `apps/windows/flclash_ui` 复用相邻 Flutter 工程的 LiveModel 和现有 Go helper，禁用了上游默认核心启动 | 可复用页面映射、夹具和宿主接入经验；切换至上游桌面核心需要单独验证 |
| Windows 开发机在制版本 | 2026-11-20 查询 origin 分支，仅有 `main` 和 `macos-updates`。维护者确认以 GitHub 可见代码为准，开放 PR 搜索结果为空 | 采用固定上游与主线 Android 改动，归档原型用于对照 Windows 能力 |

共同基线由主线 dc2d402 和 FlClash be847366 两个可检出的提交确定。复用 Android 已导入的应用和平台改动，桌面 runner 取自同一上游版本。

### Dart 源码对照

按上游标签检出的 Git 对象逐路径比较 `lib/`。两份导出均保留了上游的 365 个文件。Android 有 344 个文件内容与上游相同、21 个有修改，另有 5 个新增；归档 Windows 原型有 347 个相同、18 个有修改，另有 13 个新增。双方都修改且内容不同的 10 个同名文件中，2 个为 `common/constant.dart` 和 `common/l10n_labels.dart`，另外 8 个为本地化生成文件。迁移时先合并常量、标签和 ARB 源文本，再运行生成器。这个计数仅覆盖已归档的 Windows 原型。

## 功能迁移与验收基准

| 功能 | 当前来源 → 目标 | 第一项可重复的验收 |
| --- | --- | --- |
| WARP 凭据、MASQUE 配置、校园分流 | [Go 业务](../../internal/app)、[移动接口](../../mobileapi) → 统一工程调用现有业务接口 | 使用[共享合成配置](../../shared/fixtures/warp-business-configuration.json)对照 28 个接入点、组名、成员顺序和校园规则；[Android 核心测试](../../apps/android/core/freev6_test.go)逐个解析接入点 |
| 首页、节点页、模式和状态 | 上游公共 Dart 页面、Windows 在制改动、[Mac 节点目录断言](../../apps/macos/Tests/FreeV6DesktopTests/DesktopNodeCatalogTests.swift) → 公共 Flutter 模型和页面 | 同一提交在 Mac 和 Windows 加载同一配置，切换分组时节点名称、顺序一致；Android 同源构建后验证手机布局 |
| Windows 运行能力 | [正式客户端和 Go helper](../../apps/windows/README.md) → 公共状态与 Windows 宿主 | 动态端口、手动固定与自动优选、热点、托盘退出分别验证；每次会话仅有一个核心启动者 |
| Mac 服务与凭据 | [XPC v6](../../shared/protocol/service-v6.md)、[worker v1](../../shared/protocol/worker-v1.md)、钥匙串 → 候选桌面核心或 Mac 适配 | 独立身份验证授权失败、服务退出、路由恢复；旧应用身份升级后复用已有凭据 |
| Android VPN | [ServiceState 与原生服务](../../apps/android/AGENTS.md) → 统一工程 Android 目标 | 真机验证授权撤销、锁屏、Wi-Fi 中断和恢复。桌面准备流程独立于 Android 的 Wi-Fi 前置条件 |
| 旧用户与发行 | [各端更新链路](../releases/in-app-updates.md)、[Windows 数据迁移](windows-flutter-acceptance.md) → 各平台发行入口 | 覆盖升级、迁移中断重试、回退和签名核验；核对流量统计、配置、凭据与历史记录 |

## 阶段进度

截至 2026-11-22，Windows x64 以 `279eb30` 完成全量打包和源码重建，安装器修复 `356d784` 的原机复验记录已随 `6d6ea22` 拉取。三端候选集中在 `feat/unified-windows-client`，含 Android 和 macOS 公共提交 `65eabc6`。远端 `main` 位于 `dc2d402`，GitHub 最新正式发行仍为 [v0.1.2](https://github.com/study-233/flux6/releases/tag/v0.1.2)。

| 阶段 | 当前结果 |
| --- | --- |
| 1. 基线对齐 | 已核对主线、FlClash v0.9.3、归档 Windows 原型和共享验收样本。 |
| 2. 同源预览 | Mac arm64、Android arm64、Windows x64 均完成本机构建；Windows 预览窗口退出修复已验证。见[三端预览入口](../../apps/flux6/README.md)。 |
| 3. 完整业务候选 | 三端均已构建。Android 和 Mac 使用同一 Dart 入口并复用 FlClash 首页导航与节点分组。Mac 保留原有 WARP 引导、配置、日志和设置页。Windows 从同一 FlClash 源码组装专用 live 入口，首页、节点和设置接入 Windows 模型与 Go helper。三端仍有各自的页面和状态实现。 |
| 4. 原生接入 | Android 17 真机通过锁屏、Wi-Fi 断开自动停服和手动重连。Mac 实机已完成特权服务升级和已有 WARP 凭据读取。Windows x64 的 preview 与 live 已在 Windows 11 完成 Release 构建，离线用例覆盖动态控制端口和旧 helper 的 9090 回退。各端剩余项目见下表。 |
| 5. 升级与回退 | Android 与 Mac 已用已发布 0.1.2 做隔离升级和回退。Windows 11 已从正式 Tauri 0.1.2 自动覆盖升级，在原目录保留数据卸载并回退。修复后卸载登记唯一，旧版主程序散列恢复，独立 Dart 进程能读回四项合成偏好。旧 WebView 界面中的展示仍待核对。 |
| 6. 正式切换 | Android 和 Mac 已从 `6d6ea22` 重新生成 APK、DMG、更新 ZIP 和各自的源码包。两个源码包均在 Git 工作区外重组装通过。Windows 11 x64 已通过[原生打包验收](repository-maintenance.md#2026-11-21-windows-x64-统一候选打包验证)，生成 NSIS 安装包、便携 ZIP 和对应源码，核对了包内文件和散列。Windows 安装与回退已通过。切换正式入口、合入主线和公开更新仍待设备验收后进行。正式分发时应从含安装器修复的同一提交生成整套产物。 |

### 各平台的验证范围

| 平台 | 已有验证 | 发布前待验 |
| --- | --- | --- |
| Android arm64 | API 35 离线模拟器上，旧版、同签名候选和回退后的旧版均能打开，同签名升级和回退都保留合成文件。升级后的界面读回旧版中文偏好，回退后的旧版界面读回日文偏好。53 项服务状态机测试通过，含 VPN 被撤权时的停服行为。Android 17 真机确认升级保留授权、锁屏前后可联网、Wi-Fi 中断自动停服及重连恢复。 | 系统撤权和重新授权按用户选择跳过。 |
| macOS arm64 | 原生隔离会话及实际窗口启退通过。旧版能读回候选写入的设置、6 个加密链式节点和流量账本。临时钥匙串通过升级访问验证。用户域 XPC、签名载荷和隔离 DNS 恢复已验证。签名更新只在测试会话恢复后安装，故障时保留旧版。macOS 27.2.1 实机通过特权服务升级并直接复用旧 WARP 凭据。 | 保留现有代理时提示「不支持网段」，实际连断及路由、DNS 恢复暂缓。钥匙串授权弹窗本机未触发。 |
| Windows x64 | 22 项统一业务与 31 项模型和组件测试通过。原机验证安装器 UAC 同意及取消、卸载取消、自动识别含中文和空格的旧目录、卸载项冲突保护和同目录回退。三个数据目录的样本保留，四项合成偏好读回一致。 | 回退后旧 WebView 界面展示、live 客户端的实际联网、热点及网络恢复。 |

本轮结果见[Android 与 macOS 实机验收](repository-maintenance.md#2026-11-22-android-与-macos-实机验收)和[三端升级与恢复验收进展](repository-maintenance.md#2026-11-22-三端升级与恢复验收进展)。早期验证见 [Android 与 Mac 记录](repository-maintenance.md#2026-11-21-android-与-macos-统一应用)、[Windows 本机记录](repository-maintenance.md#2026-11-21-windows-统一客户端原生接入)、[统一候选打包验证](repository-maintenance.md#2026-11-21-统一候选打包与隔离验收)、[Windows 修复后安装与回退复验](repository-maintenance.md#2026-11-21-本机安装与回退复验)及 [Windows 原生验收清单](windows-flutter-acceptance.md)。
