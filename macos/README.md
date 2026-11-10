# FreeV6 原生 Mac 客户端

当前 Mac 版面向 Apple Silicon（M 系列），最低支持目标为 macOS 14。0.5.5（build 4）的首页、节点、配置、日志与独立设置窗口运行 Flutter + FlClash / Prism UI。AppKit 管理窗口、原生菜单与菜单栏入口，Swift 业务层和 Go worker 处理连接准备、WARP 凭据、规则与核心数据。正式宿主通过 XPC v6 接入启停、运行模式、节点和流量读取。[P5/P6 候选版与验收记录](../docs/compose/audits/2026-11-07-p5-p6/README.md)。断开及正常退出会等待网络恢复。已验证普通用户域的隔离网络，系统服务安装、真实校园网络和 macOS 14 仍待实机验收。[服务协议](../shared/protocol/service-v6.md)

本版在 WARP 连接和配置检查时自动注册缺失凭据，已有凭据直接复用；后台自动连接不弹钥匙串窗口。注册成功但保存失败时，设置页可重试保存同一结果。测试包使用持久的本机签名证书，跨版本保持钥匙串识别身份。旧版临时签名迁移到本版时可能仍需一次授权。

此前已修复核心控制接口和 TUN 已创建、规则提供器尚未加载完成时的启动竞态：HTTPS 出口检测在 45 秒内重试暂时性传输失败，并持续核对核心及隧道身份；证书、HTTP 响应和出口路由验证仍须通过。旧版升级需在“设置 → 网络服务”点击“修复网络服务…”以更新服务。

## 构建

请在 Apple Silicon Mac 上使用完整 Xcode 27 或更新版本（含 macOS 27 SDK）及 Go 1.25+。首次打包会准备固定的 Flutter 3.47.6 和 Sparkle；已有 Flutter SDK 可通过 `FREEV6_FLUTTER_SDK` 指定。最低运行目标是 macOS 14。脚本通过 DEVELOPER_DIR 选择 Xcode，不更改系统的 xcode-select。脚本会在 SDK 解压并通过版本检查后删除下载的安装压缩包。

```sh
bash scripts/macos/swift.sh build
bash scripts/macos/swift.sh test
bash scripts/macos/build-app.sh
```

开发应用位于 `dist/macos/FreeV6.app`。`build-app.sh` 默认 Release，构建当前主机架构的服务、Go worker、安装工具与 App，按内部组件到外层顺序使用固定的本机证书 + Hardened Runtime 签名，保留宿主的框架哈希限制及服务的严格运行保护。Go 不在 PATH 时可传 `GO_BIN=/absolute/path/to/go`。构建缓存位于 `build/`；运行配置写入用户 Library，不写应用 bundle。主窗口与设置共用一个会话，界面由 Flutter 绘制。

默认构建会在 `~/Library/Application Support/dev.freev6.build-signing` 保存仅当前用户可读的专用签名钥匙串、随机口令和公钥证书。私钥不进入源码或安装包；请保留这个目录以维持后续构建的身份。仅系统 `codesign` 获准使用签名密钥，脚本不修改系统信任设置。此证书不是 Developer ID，也不提供 Apple 公证。可用 `FREEV6_CODESIGN_IDENTITY` 指定已有正式证书，或显式设为 `-` 生成一次性 ad-hoc 验收包。

安装工具的签名覆盖一个嵌入 Mach-O 的 Info.plist，其中固定当前服务二进制的 SHA256。普通 `swift.sh build` 不嵌入此清单，其安装工具拒绝执行安装；用于安装的工具必须通过 `build-app.sh` 生成。

### 构建可拖放安装的 DMG

在 Apple Silicon Mac 的原生 arm64 普通用户会话运行 `python3 scripts/macos/build-dmg.py`。该命令执行 Release 构建，在 `dist/macos` 输出 `FreeV6_<版本>-preview_arm64.dmg`。挂载后把 FreeV6 拖到 Applications，从“应用程序”打开。镜像内附中文安装说明，App 内附协议、隐私说明、FlClash / Prism UI 和各依赖的许可证、组件清单及对应源文件摘要。

打包脚本只读挂载镜像，在临时目录验证拖放副本的签名、宿主、框架和工具的架构、最低系统、动态库查找路径及安装工具内嵌的服务摘要，随后推出。直接从只读卷或系统转移路径启动时，应用只显示拖放安装指引。安装到可写位置后才进入常规启动流程；安装系统网络服务要求将 App 放在系统的“应用程序”目录。

要复查下载隔离，请用 Safari 下载这次构建的镜像，在普通用户会话运行以下命令。探针核对两份镜像的字节，读取浏览器写入的隔离属性，从只读卷复制 App 到临时目录并检查签名和系统策略。预览版在 macOS 27.0.1 上的实测结果为签名完整、Gatekeeper 拒绝默认运行。首次放行由使用者根据来源和摘要自行决定。[分发验收记录](../docs/compose/spec/macos-development-progress.md#下载隔离安装窗口与系统分发检查) · [Apple 的 Mac 安全打开说明](https://support.apple.com/zh-cn/102445)

```sh
python3 scripts/macos/probe-distribution.py "/path/to/browser-downloaded.dmg" \
  --reference dist/macos/FreeV6_0.5.5-preview_arm64.dmg
```

## 开发与验证

- [Flutter 预览和集成测试宿主](flutter_ui/README.md)：只体验界面或使用隔离会话时，从这里开始。
- [开发与验证手册](DEVELOPMENT.md)：Go worker、资源下载、Keychain、服务安装、会话恢复及专项探针的运行条件和命令。
- [当前候选版验收记录](../docs/compose/audits/2026-11-07-p5-p6/README.md)：安装包校验、升级回退、界面与性能结果。

## Swift 更新助手与发布

正式通道需要签名清单、更新包和独立的发布密钥。生成通道与更新包的命令见[发布手册](DEVELOPMENT.md#swift-更新助手与发布)。
