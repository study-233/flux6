# macOS 开发进度

目标：按照 macOS 支持计划完成原生客户端、共用业务、网络服务、DMG、应用更新及验收。开发分支为 `mac`，起点 c528f26。当前整体目标尚未完成。

## 阶段状态

| 阶段 | 状态 | 当前证据与剩余工作 |
| --- | --- | --- |
| P0 技术验证 | 进行中 | 原生构建、当前系统 UI、独立用户级 XPC 服务、只读 DNS、Keychain 单次读写、Darwin 离线配置、隔离更新助手的真实升级/拒签已通过；root 安装/恢复、实际联网、quarantine 分发、凭据升级和最低系统尚未通过 |
| P1 共用业务与协议 | 未完成 | 增加显式平台配置和 JSON 输出；HTTP 业务提取、worker 与 stdio 协议待实现 |
| P2 原生应用骨架 | 未完成 | 可构建应用雏形已有导航、部分菜单/工具栏、状态入口和设置；正式 Xcode targets、完整菜单和真实 worker 握手待完成 |
| P3 原生网络服务 | 未完成 | 已有握手服务、受控登记读取和身份验证；管理员安装/卸载、核心管理与完整协议待实现 |
| P4 TUN 与恢复 | 未开始 | 尚未修改系统 DNS、路由或启动 TUN |
| P5 功能完整与原生体验 | 未开始 | 页面为明确标注的开发状态，连接按钮禁用；无模拟连接成功状态 |
| P6 DMG 与升级 | 未完成 | 已验证隔离应用的更新与错误签名拒绝；产品更新助手、DMG、正式 appcast 和服务升级事务待完成 |
| P7 回归与交付 | 未完成 | 当前 Mac Go 回归已通过；Windows 运行测试、macOS 13、Intel 及实际校园网络待验收 |

## 2026-11-04：首批 P0 验证

- 已创建并切换到 `mac` 分支，原计划随分支保留。
- 当前环境：Apple Silicon、macOS 27.0.1、Xcode 27.2（27B52）、Swift 6.4.2；原生部署目标设置为 macOS 13。这只证明当前系统的构建运行，不证明 macOS 13 实测通过。
- 从 Go 官方版本清单取得并校验 Go 1.25.14，解压至 `/private/tmp/freev6-toolchains/go`，未安装到全局目录。SHA256：`5b26c0b6f308240fca2614fb02f622cfcc8c0cc3b69c78bba4845489a4590259`；依赖与构建缓存位于 `/private/tmp/freev6-go-cache`。
- `bash scripts/macos/swift.sh build` 与 `test` 通过；5 项 XCTest 覆盖握手身份关联、版本拒绝、消息大小/字段校验、DNS 快照缺省与显式配置的区别。
- `bash scripts/macos/build-app.sh` 生成并校验 `dist/macos/FreeV6.app` 的 ad-hoc 签名。
- 实际打开原生 App，检查原生窗口/工具栏与侧栏；⌘2 切换节点页、⌘, 打开设置、⌘W 关闭设置及隐藏主窗口、⌘1 恢复主窗口并回到概览均通过。完整文件菜单、状态栏所有操作、退出后的网络清理尚未验收。
- 系统探针成功读取当前签名身份；DNS 探针只读捕获 5 个网络服务，不在日志输出具体解析器地址。
- 正常用户环境中，允许的 CDHash 完成匿名 XPC 握手，错误 CDHash 被拒绝。沙箱中可信连接也会失败，不能把该环境下的拒绝当作身份校验成功证据。
- Keychain 探针在独立随机测试项上完成创建、读取和删除。尚未验证 ad-hoc 版本变化后的重新授权。
- 上游 v1.19.31 的 Darwin arm64 压缩包通过固定 SHA256 校验；`file` 确认为 arm64 Mach-O，`-v` 输出 v1.19.31 / darwin arm64 / go1.26.8。Intel 资产摘要也已从上游 release 记录，但未做 Intel 真机验证。
- 共用配置增加显式 Darwin 目标：动态 utun、loopback DNS，保留 Windows 默认输出；新增 JSON 序列化和业务等价性测试。
- `cmd/macos-probe` 生成合成凭据的完整/离线配置；真实核心 `-t` 对离线 JSON/MASQUE 配置检查成功。该样本移除了远端规则/GeoSite 依赖，尚不能证明完整业务、DNS 劫持、TUN 或真实 WARP 连接可用。
- Go 基线曾有 3 项非 Windows 假设失败：2 项发现测试写死 Windows 文件名，1 项测试错误假定所有系统能恢复 Windows 快照。现已加入按目标平台命名和对应测试；非 Windows 保留无法恢复的原快照，没有伪造恢复成功。修改后 `go test ./...` 全部通过。

- Windows amd64 的全部 Go 测试程序交叉编译成功，产物确认为 PE32+ x86-64；这些程序尚未在 Windows 上执行，不能据此声明 Windows 运行回归完成。
- 使用 `otool -l` 检查原生 App 的实际 Mach-O，最低系统标记为 13.0；新的可重复核心探针脚本也完成了摘要校验和离线配置检查。

## 2026-11-05：独立服务与真实更新验证

- 新增独立 Swift 网络服务目标，目前只开放有版本和请求关联的 XPC 握手。生产路径固定；Release 不接受探针参数，普通用户不能直接启动生产服务。
- 安装登记按 UID 绑定客户端 CDHash。登记文件读取采用逐级目录句柄、`openat`、`O_NOFOLLOW`、同一文件句柄的权限/大小检查与有界读取，拒绝可被其他用户写入的目录、符号链接、硬链接和 FIFO，避免路径替换与无界读取。
- Debug 构建和 12 项 XCTest 通过。Release 构建曾在受限环境被 `dsymutil` 权限阻止，在正常用户环境构建通过；Release 的探针参数拒绝与非 root 启动拒绝已实际执行验证。
- `probe-service.py` 使用启用 Hardened Runtime 的独立进程和临时用户级 launchd job。合法握手、错误客户端摘要拒绝、错误服务摘要拒绝、UID 绑定、服务重启、同 identifier 新摘要重新登记与旧摘要撤销全部通过，job 已移除。这里的登记更换只证明身份机制，不等同于管理员重新授权或 root 安装验收。
- Sparkle 2.9.6 官方 tar.xz 摘要为 `52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192`。直接在严格 Hardened Runtime 的 ad-hoc App 内加载框架被 dyld 拒绝，原因是 Team ID 不匹配；普通 ad-hoc 对照应用可以真实升级。
- 据此验证独立更新助手：主程序仅链接系统框架、启用 Hardened Runtime、无放宽权限；仅普通用户助手携带 `disable-library-validation` 并加载 Sparkle。真实更新完成下载、签名验证、安装、N→N+1 和不同 PID 的新版重启，外层 bundle 签名检查通过。
- 错误 Ed25519 签名被 Sparkle 拒绝，原安装版本保持为 1。测试解析结构化底层错误链，不能将任意安装/网络错误当作签名验证成功。
- 更新测试使用随机 bundle ID、临时签名密钥和回环 appcast。测试私钥、服务器、偏好和更新缓存已清理。Objective-C 宿主与自动应答 driver 仅是 P0 夹具；产品的 Swift 更新界面、授权交互和服务事务仍待接入。
- 计划已纳入独立更新助手，同时细化用户要求的原生顶部菜单、窗口工具栏、状态菜单及任务验收；不安排人数或人力工期。

本轮保留的直接证据：

| 验证 | 结果文件 |
| --- | --- |
| 用户级服务和身份轮换 | [service result](/Users/andy/Study/free-v6/build/service-probes/57acdab8-e5b5-45a0-b4af-e1f63c3e79db/result.json) |
| 严格签名主程序 + 独立助手升级 | [update result](/Users/andy/Study/free-v6/build/update-probes/67760da474da44af84f09cdde3148cb6/result.json) |
| 错误签名拒绝，旧版保留 | [rejection result](/Users/andy/Study/free-v6/build/update-probes/89197ae31a63421fbbf9a9d27dc2035f/result.json) |

这些文件是本地忽略的构建产物，可用 README 中的脚本重新生成。当前没有安装 root 服务、修改 DNS/路由或建立真实 TUN；没有通过 macOS 13、Intel、quarantine DMG 或生产网络服务升级验收。

## 下一步

1. 实现受控管理员安装/卸载与升级回退，补齐客户端运行期保护校验，验证 root Mach service 的双向身份和重启。
2. 实现 DNS 事务、受控核心进程和失败恢复，再执行真实 TUN/IPv6/解析器验证。
3. 验证 Keychain 在升级/回退后的访问行为；明确 macOS 13 与 Intel 的测试设备路径。
4. 按已经验证的机制接入产品 Swift 更新助手，并补齐 quarantine 分发与网络服务升级事务。
5. 继续共用 Go 业务提取、原生 worker、完整顶部栏和功能接入；外部设备验收未完成的项目保持未验证，不阻止无依赖工作。

## 可重复验证入口

构建和探针说明见 [macos/README.md](/Users/andy/Study/free-v6/macos/README.md)。Go 测试在受限执行环境中需要允许本机回环服务器；网络依赖下载与真实网络行为分别记录，不能用沙箱失败代替产品失败。
