# macOS 开发进度

目标：按照 macOS 支持计划完成原生客户端、共用业务、网络服务、DMG、应用更新及验收。开发分支为 `mac`，起点 c528f26。当前整体目标尚未完成。

## 阶段状态

| 阶段 | 状态 | 当前证据与剩余工作 |
| --- | --- | --- |
| P0 技术验证 | 进行中 | 原生构建、当前系统 UI、匿名 XPC 身份验证、只读 DNS、Keychain 单次读写、Darwin 核心与离线 JSON/MASQUE 检查已通过；root 安装/恢复、实际联网、更新、凭据升级和最低系统尚未通过 |
| P1 共用业务与协议 | 未完成 | 增加显式平台配置和 JSON 输出；HTTP 业务提取、worker 与 stdio 协议待实现 |
| P2 原生应用骨架 | 未完成 | 可构建应用雏形已有导航、部分菜单/工具栏、状态入口和设置；正式 Xcode targets、完整菜单和真实 worker 握手待完成 |
| P3 原生网络服务 | 未开始 | 尚无可安装的 root daemon |
| P4 TUN 与恢复 | 未开始 | 尚未修改系统 DNS、路由或启动 TUN |
| P5 功能完整与原生体验 | 未开始 | 页面为明确标注的开发状态，连接按钮禁用；无模拟连接成功状态 |
| P6 DMG 与升级 | 未开始 | 目前只有本地 ad-hoc .app，无正式 DMG/appcast |
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

## 下一步

1. 验证 Sparkle 固定版本的加载、ad-hoc/Hardened Runtime 组合和 N→N+1 更新；发布密钥与测试密钥严格分开。
2. 将匿名 XPC 原型推进为固定 Mach service 和可恢复的安装/卸载流程，验证双向身份、重启及客户端升级。
3. 实现 DNS 事务、受控核心进程和失败恢复，再执行真实 TUN/IPv6/解析器验证。
4. 验证 Keychain 在升级/回退后的访问行为；明确 macOS 13 与 Intel 的测试设备路径。
5. P0 的关键路径通过后，继续共用 Go 业务提取、原生 worker 与完整功能接入。

## 可重复验证入口

构建和探针说明见 [macos/README.md](/Users/andy/Study/free-v6/macos/README.md)。Go 测试在受限执行环境中需要允许本机回环服务器；网络依赖下载与真实网络行为分别记录，不能用沙箱失败代替产品失败。
