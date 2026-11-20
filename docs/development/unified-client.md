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
2. 公共工程进行中。[预览构建入口](../../apps/flux6/README.md)已提供三个目标，共用原有 Dart 模型、GroupTabs 和合成分组。Mac arm64、Android arm64 和 Windows x64 本机构建均通过。Windows 节点分组测试和首屏显示通过，关闭预览窗口时连续两次异常退出，详见 [Windows x64 验证记录](repository-maintenance.md#2026-11-20-统一预览-windows-x64-验证)。
3. 公共业务进行中。Android 完整候选已连同现有 WARP 设置页和 VPN 服务构建。Mac 已用合成凭据通过桌面 IPC 启动真实核心、生成配置、验证接入点与分流规则并停止核心。Windows 同项测试随验证脚本提供。桌面用户从设置页选点、连接、查看状态与断开的完整流程，以及失败重试和过期结果处理仍待接入和验收。
4. 平台能力。将现有服务、权限、菜单或托盘、更新及平台特有功能逐项接入并验收。
5. 数据迁移。使用各平台已发布版本执行覆盖升级、重复导入和回退。
6. 正式切换。按平台验收结果调整构建和更新入口，核对签名、对应源码和更新清单，随后单独清理旧工程。
