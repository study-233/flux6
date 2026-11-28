# Windows FlClash 界面适配

当前正式 Windows 客户端以 0.1.3 的统一 Flutter 工程为基线。`scripts/unified/prepare.py --windows-client` 从固定的 Android/FlClash 源码组装独立工程，再应用本目录的 `flclash.patch`、Windows 页面和本地化词条；不会修改 Android 或 macOS 的源文件。

导航保留仪表盘、节点、免流配置、连接、DNS、日志和设置。仪表盘、节点卡片、过滤、排序、连接详情和日志控件复用上游组件。WARP、校园直连列表、链式代理、备用配置、F6、托盘、自启动和热点共享由 Windows 专用页面操作现有宿主/helper。脚本、MITM 和独立普通代理不在本次范围内。

`core_adapter.dart` 提供外部核心的连接查询/关闭、DNS 缓存、流量、内存和出口诊断；核心启停只能经 `LiveModel` → Windows helper。节点固定、自动优选、并发接入点、下载测速和测速历史使用 helper 的会话及网络身份。延迟测试最多六路并发，每节点三次取中位数，失败单独标记；下载测试可取消并丢弃旧会话结果。

自动优选与具体节点共用原有卡片网格，勾选表示当前策略；点击具体节点固定，点击自动优选恢复自动。工具栏的测速入口分为优选策略、下载测速和历史记录。并发接入点仅在自动模式下可调；等待 helper 确认期间禁止重复切换，旧轮询不能覆盖已确认的选择。启动等待页使用同一套主题组件，后台连接失败时提供重试。

状态卡复用原有出口 IP、刷新、隐藏 IP 和质量详情；服务状态复用原卡片、检测、排序和显示管理。Windows helper 的 `POST /api/v1/diagnostics/probe` 仅接受固定诊断类型及服务名称，通过当前运行配置的 Mixed 端口检测，不直连回退；停止连接会取消探测，旧路由结果不再显示。服务判定取自固定 Android 源码，来源及适配记录见 [PROBE_SOURCES.md](../../../cmd/freev6-helper/PROBE_SOURCES.md)。预览使用合成结果。实时站点和出口质量依赖外部服务，隔离测试不验证这些服务的可用性。

DNS 页面记录用户主动发起的 A/AAAA 诊断查询，不是所有应用的被动 DNS 记录。最近请求来自活动连接采样，可能看不到两个采样点之间已经结束的短连接；累计流量使用核心的总计数，不受这项限制。内存总量使用 Windows 进程工作集，核心堆用量另行读取。

## 数据与配置

- 只验证 **0.1.3 → 0.1.4**：继续读取原安装目录的 `state/flutter-ui.json` v1，以及既有 `config/`、`state/`、`runtime/`；不重新注册 WARP，不转换已有链式配置或测速历史。
- 新增的 `flclash-app-settings`、`flclash-proxy-style` 作为原偏好文件中的可选键保存，旧文件缺少这些键时使用默认值。退出和导出前完成待写入的布局设置。
- 端口、DNS/TUN 选项写入 `config/network-options.json`，保存后重新连接生效；只覆盖 Windows 生成配置中的允许字段，保留 WARP、路由及 DNS 接管必需配置。
- 设置中的端口弹窗可修改 Mixed、独立 HTTP、SOCKS 和 DNS。HTTP/SOCKS 的 0 表示关闭；非零端口须为 1–65535、互不重复且不占用控制端口 9090。启动前检查 TCP/UDP 占用，控制器保留原有动态分配机制。Windows 不提供 Linux 专用的 Redir/TProxy 端口。
- helper 新接口 `GET/PUT /api/v1/network-options` 沿用本地鉴权。字段为 `mixedPort`、`httpPort`、`socksPort`、`dnsPort`、`nameservers`、`dnsMode`、`tunStack`、`tunMtu`、`logLevel`；非法值或保存失败保留原配置。

共享源文件不等于功能已完全统一。Windows 的 WARP/校园配置与宿主控制仍由适配层实现；独立系统代理和 TUN 开关未开放，连接仍由免流流程整体控制。局域网卡片目前使用流量统计替代，通用配置管理仍以免流配置为范围。脚本、MITM 和独立普通代理沿用已确认的排除范围，不将这些差异标记为已对齐。

## 构建与检查

版本来源为 `apps/windows/release.json`。从仓库根运行 `scripts/windows/build-flutter.ps1`，默认构建本工程并输出安装包、便携包、对应源码与更新元数据，不自动安装或发布。旧独立 Flutter 工程仍供宿主和后端库使用，旧 Web/Tauri 源码保留。

本轮检查仅包含受影响的 Dart 分析、后端/升级回归、统一页面回归、Windows helper 的定向测试及 vet、原生构建、隔离预览和源码打包检查。真实联网与安装覆盖的界限见[验收说明](../../../docs/development/windows-flutter-acceptance.md)。
