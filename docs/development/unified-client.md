# Flux6 统一客户端迁移

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

1. 基线对齐完成。主线、固定上游、归档原型和验收样本均已核对。
2. 三端同源预览验证完成。[预览构建入口](../../apps/flux6/README.md)已提供三个目标，共用原有 Dart 模型、GroupTabs 和合成分组。Mac arm64、Android arm64 和 Windows x64 本机构建均通过。Windows 节点分组测试、首屏显示和关闭窗口均已通过，详见[退出修复与验证记录](repository-maintenance.md#2026-11-20-windows-托盘插件退出修复)。
3. Android 与 macOS 已提供[同一 Flutter 入口的完整候选](../../apps/flux6/README.md)。Mac 与 Android 共用 FlClash 首页导航和分组控件。Android 使用原有 WARP 引导，Mac 通过原生宿主准备配置、选点、连接、读取状态和断开，主窗口及独立设置窗口共用原生会话。Windows 完整业务接入已交接到 `feat/unified-windows-client`。
4. Android 的 VPN 服务与 ServiceState、Mac 的 AppKit、钥匙串、原 Go worker、XPC 服务和签名更新助手均保留在升级构建中。Mac 隔离宿主完成操作、过期请求、退出恢复与重启验证。Android 运营网络下的 VPN 撤权、锁屏与网络恢复，以及 Mac 真机授权和真实路由恢复仍需设备验收。
5. Android 已在专用 API 35 模拟器上用正式 0.1.2 完成同签名覆盖和回退，核对启动和合成数据保留。Mac 已用正式 0.1.2 的包和新候选在隔离目录验证原有设置、加密链式配置、流量账本的双向兼容以及已签名包回退。
6. 两端提供可选的原身份签名构建和对应源码打包路径。真实联网和升级验收完成后再启用正式构建及公开更新入口。
