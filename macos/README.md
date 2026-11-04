# FreeV6 原生 Mac 客户端

当前推进 P0 技术验证、P1 共用业务与 P2 原生应用。工程包含 SwiftUI/AppKit 应用、普通用户 Go worker、仅支持握手的网络服务、安装工具和系统探针。原生页面已接入设置读写、核心准备和 WARP 注册/钥匙串存储；真实 Cloudflare 注册尚待实测。连接功能仍禁用，不会启用代理或修改 DNS。完整目标及进度见仓库的 macOS 支持计划与开发记录。

## 构建

需要完整 Xcode 和 Go 1.25+。脚本通过 DEVELOPER_DIR 选择 Xcode，不更改系统的 xcode-select。P0 使用 Swift Package 组织可独立测试的模块；后续添加正式 App、daemon 与安装工具的 Xcode targets。

```sh
bash scripts/macos/swift.sh build
bash scripts/macos/swift.sh test
bash scripts/macos/build-app.sh
```

开发应用位于 `dist/macos/FreeV6.app`。`build-app.sh` 默认 Release，构建当前主机架构的服务、Go worker、安装工具与 App，按内部组件到外层顺序使用 ad-hoc + Hardened Runtime 签名，不给特权客户端添加 entitlement。Go 不在 PATH 时可传 `GO_BIN=/absolute/path/to/go`。构建缓存位于 `build/`；运行配置写入用户 Library，不写应用 bundle。主窗口、菜单、菜单栏状态入口和设置均为原生组件。

安装工具的签名覆盖一个嵌入 Mach-O 的 Info.plist，其中固定当前服务二进制的 SHA256。普通 `swift.sh build` 不嵌入此清单，其安装工具拒绝执行安装；用于安装的工具必须通过 `build-app.sh` 生成。

## 原生顶部栏与窗口

应用菜单、页面工具栏与右上角状态菜单共用 `FreeV6Desktop` 的命令可用性规则及 `AppModel` 的执行入口。执行前重新检查状态，服务握手成功或核心缓存可用均不会启用尚未实现的 TUN 连接。配置保存（⌘S）和重新载入只在主窗口配置页或设置的代理规则页获得焦点时启用；编辑菜单保留系统焦点行为。

⌘1–⌘4 打开主窗口并切换页面；主窗口关闭后隐藏，Dock 或状态菜单可恢复窗口。应用保存上次页面，并交给 AppKit 保存窗口位置与尺寸。macOS 14+ 的状态菜单使用原生 `SettingsLink`，macOS 13 保留系统设置窗口入口。帮助菜单提供本地使用说明。

退出统一经过应用代理：配置读写或服务操作期间等待；存在草稿时可保存、取消或放弃；下载取消后等待 worker 回收再退出。该流程当前仅覆盖用户级业务进程，真正的网络停止与 DNS 恢复仍待 P4 接入。完整的菜单/窗口/确认框操作及最低系统表现需要实机验收，不能用命令模型测试替代。

`FreeV6DesktopTests` 覆盖焦点、能力及重复操作限制；`WorkerClientTests` 另验证正在下载时关闭管道、拒绝待处理请求并等待子进程退出。两者包含在 `swift.sh test` 中。菜单与焦点实现参考 [Apple 原生菜单说明](https://developer.apple.com/documentation/swiftui/building-and-customizing-the-menu-bar-with-swiftui)，设置入口参考 [SettingsLink](https://developer.apple.com/documentation/swiftui/settingslink)。

## 业务 worker 与配置

App 从 `Contents/Helpers/freev6-worker` 启动当前用户子进程，使用私有 stdin/stdout 帧通信。当前提供代理规则读写、固定平台核心安装包、GeoSite/GeoIP 数据准备及 WARP 注册；协议见 [worker-v1.md](../shared/protocol/worker-v1.md)。订阅、配置生成和网络控制尚未接入这些页面。

配置文件：`~/Library/Application Support/dev.freev6.desktop/proxy-preferences.json`。它有独立 schema 和 revision，以原子替换方式写入，拒绝覆盖版本冲突或损坏文件。当前不会向该文件写入 WARP 凭据或订阅 URL。`worker.lock` 防止同一数据目录被多个 worker 同时修改；父进程断开、SIGTERM 或客户端回收后释放锁。

核心缓存：`~/Library/Caches/dev.freev6.desktop/runtime/<archive-sha256>/<archive-name>`。平台资产统一从编译时嵌入的清单选择，压缩包与解压后的二进制均校验固定 SHA256、大小和架构。Mac 当前只保留安装包；网络服务接入时还要独立复验并安装，不能把“核心安装包已校验”当作“代理已运行”。主界面与设置共用一个 worker，避免竞争数据目录锁。

以下命令完成 Go 业务/协议竞态测试、真实 Swift→Go 集成测试，以及独立 worker 进程探针：

```sh
bash scripts/macos/test-worker.sh
```

仅验证打包后的 worker：

```sh
python3 scripts/macos/probe-worker.py
```

探针使用 `build/worker-probes/<UUID>` 中的独立测试目录，验证分片握手、保存、版本冲突、核心方法参数限制、重复 worker 拒绝、父进程 EOF、SIGTERM、输出背压和坏帧。加 `--download-runtime` 会通过正式镜像下载原生核心，并记录进度和最终摘要。所有测试子进程在结束时回收，结果写入该目录的 `result.json`。不读取个人凭据，不安装网络服务。

普通 `swift.sh test` 在未传 `FREEV6_WORKER_TEST_BINARY` 时跳过真实 Go 集成项；官方核心测试还需要 `FREEV6_RUNTIME_FIXTURES_DIR` 指向包含清单中官方 ZIP/gzip 的目录。该变量也用于 Go 的真实资产验证；测试仍独立核验所有摘要，不信任目录中的文件名。不得把跳过视为集成通过。

## GeoSite 与 GeoIP 数据

概览页及设置的“核心与数据”页共用准备状态，提供检查、下载、取消与重试。`geodata.status/prepare` 从编译时清单选择固定提交的三份数据，只有全部校验通过才显示“规则数据已校验”；准备不启动核心。下载与运行时核心共用有界传输、无进展期限和摘要校验。

缓存位于 `~/Library/Caches/dev.freev6.desktop/geodata/<revision>/`。可选种子只从显式 `Contents/Resources/Geodata/<revision>/` 读取；不再猜测可执行文件父目录，也不向 bundle 写入。当前构建通过首次准备下载数据，未将数据二进制加入应用包。上游仓库的声明许可证和输入数据来源见 [meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)；分发数据时需同步核对对应来源材料，不能直接沿用原先的 Apache-2.0 标注。

验证命令：

```sh
python3 scripts/macos/probe-worker.py --prepare-geodata
go run ./cmd/macos-probe --out build/macos-probes/config
python3 scripts/macos/probe-runtime.py \
  --check-config build/macos-probes/config/full-config.json \
  --geodata-dir /absolute/path/to/verified/geodata
```

第一次探针将数据留在其输出的结果目录下 `main-cache/geodata/<revision>`，可作为后两个命令的数据目录。设置 `FREEV6_GEODATA_FIXTURES_DIR` 为该目录，可运行 Go 官方摘要测试和 Swift→Go 种子、缓存损坏修复、重启验证。完整 `-t` 保留 GeoSite、DNS 策略和规则提供者定义，不代表提供者下载、实际 DNS 接管或 TUN 流量通过；这些仍由网络阶段验收。

## WARP 与 Keychain

概览及设置的 WARP 页提供检查、注册、重新注册、删除本机凭据和保存失败重试。启动时不自动读取私钥；点击检查或注册后，Security API 在独立串行队列执行，授权交由系统窗口处理。保存失败保留旧记录和待保存的新结果，不自动创建第二个 WARP 设备。

凭据放在当前用户的文件式 Keychain 中，generic-password 的 service 为 `dev.freev6.desktop.warp`、account 为 `credentials-v1`。使用创建应用的默认代码访问控制，不增加共享访问组、不允许所有应用读取、不添加 Apple 签名 entitlement。Data Protection Keychain 的共享访问组和签名配置不在此无 Developer ID 首版中使用；ad-hoc 更新后的再次授权仍需实测。[Apple Keychain 访问控制](https://developer.apple.com/documentation/security/access-control-lists)、[代码签名与 Keychain 身份](https://developer.apple.com/library/archive/technotes/tn2206/)

条目以随机 revision 保护替换和删除；损坏内容或版本冲突保留原记录。Go worker 不写 `warp.json`；Windows helper 继续使用原有凭据文件。删除本机记录不等于注销 Cloudflare 设备，取消注册也不能保证服务端没有创建设备。新结果仅保留在内存时，正常退出要求先保存或明确放弃。

独立真实 Keychain 测试：

```sh
FREEV6_TEST_PRIVATE_KEYCHAIN=1 bash scripts/macos/swift.sh test --filter WarpCredentialTests
```

测试创建仅含合成数据的临时钥匙串并清理，不读取登录钥匙串。为了测试文件式 Keychain，测试夹具使用已弃用的 `SecKeychainCreate/Delete` 等隔离 API；产品通过 `SecItem` API 访问条目。未设置开关时该项跳过。Go/Swift 共用合成凭据样本，仅用于验证协议和密钥编码，不能用于实际连接。

## 服务安装与事务

应用需位于 `/Applications`。概览页提供安装/重新登记入口，设置页提供恢复未完成安装与卸载入口，管理员凭据交由 macOS 系统授权窗口处理。安装登记同时绑定用户和 App CDHash，更新后的 App 需要重新登记；其他用户的登记保留。当前 root 实机安装流程仍待验收，不将本地模拟事务测试当作系统级成功。

固定系统路径：

- 服务：`/Library/PrivilegedHelperTools/dev.freev6.network-service`
- 恢复/卸载工具：`/Library/PrivilegedHelperTools/dev.freev6.service-installer`
- launchd：`/Library/LaunchDaemons/dev.freev6.network-service.plist`
- 登记：`/Library/Application Support/dev.freev6.desktop/service-registration.json`
- root 私有事务与暂存：`/Library/Application Support/dev.freev6.desktop/installation`

安装工具先复制并验证客户端代码、服务固定摘要和自身代码身份，再修改固定目标。事务持有独占锁，持久化旧文件、摘要和提交记录；失败回退，恢复失败保留记录供下次重试。安装工具以自己的 root CDHash 完成安装后的双向 XPC 健康检查。发现 `network-session.json` 时暂时拒绝升级/卸载，P4 将以明确的网络恢复接口替换这一保护。

误删应用后，管理员仍可使用固定恢复工具的 `recover` 或 `uninstall` 动作。这里的 `recover` 仅恢复安装事务；TUN/DNS 恢复尚未实现。卸载移除 daemon、服务、登记和恢复工具，保留 root 私有暂存目录；完整数据清理归入后续卸载验收。

无需管理员权限的真实签名产物验证：

```sh
python3 scripts/macos/probe-installer.py
```

验证正常 payload、错误服务摘要、放宽运行期保护的客户端拒绝，以及非 root 安装拒绝。文件复制到独立的 `build/installer-probes/<UUID>`，不调用系统级 launchd。事务 XCTest 还覆盖首次安装/升级失败、中断恢复、坏备份、符号链接目标、并发锁、多用户重新登记和幂等卸载。

## 系统探针

```sh
probe_dir="$(bash scripts/macos/swift.sh build --show-bin-path)"
"$probe_dir/freev6-probe" identity
"$probe_dir/freev6-probe" dns
"$probe_dir/freev6-probe" xpc
"$probe_dir/freev6-probe" xpc-reject
"$probe_dir/freev6-probe" keychain
```

DNS 探针只读。XPC 探针使用同一用户下的匿名 listener，分别验证允许的 CDHash 和错误 CDHash；必须先确认可信连接成功，才能将拒绝测试解释为身份校验有效。受限沙箱可能禁止 Mach IPC，需在正常用户环境运行。此探针不证明 root daemon 的安装、重启和升级已通过。

Keychain 探针只创建、读取并删除一个随机标识的 `dev.freev6.probe` 测试项，不读取已有凭据。当前仅验证单次读写；升级后的访问行为单独验收。

## 独立服务验证

```sh
python3 scripts/macos/probe-service.py
```

在正常登录用户环境运行，不能以 root 运行。脚本构建 Debug 服务和探针，在 `build/service-probes/<UUID>` 内复制并启用 Hardened Runtime，然后注册一个随机名称的用户级 launchd job。验证双向 CDHash、UID 绑定、重启、客户端摘要更换后的重新登记与旧摘要撤销，最后移除该 job。只有可信调用在拒绝测试前后均成功，才记录拒绝通过。结果保存在该目录的 `result.json`。

服务只读取权限受控的登记文件，通过固定 XPC 方法响应版本握手。Release 构建拒绝探针参数和普通用户启动。这里没有 root 安装、网络启停或生产服务升级；用户级重新登记实验不能替代管理员安装验收。

## 原生更新验证

```sh
python3 scripts/macos/probe-update.py --isolated-agent
python3 scripts/macos/probe-update.py --isolated-agent --invalid-signature
```

脚本核验 Sparkle 2.9.6 官方压缩包，使用临时 Ed25519 密钥、随机 bundle ID 和仅监听 `127.0.0.1` 的 appcast。测试只更新独立测试 App，并检查实际版本、重启 PID、主程序 Hardened Runtime 和 entitlement；结果位于 `build/update-probes/<UUID>/result.json`。临时私钥、监听服务器及本次测试的偏好和更新缓存会清理，构建产物与诊断保留。

主测试 App 仅链接系统框架；Sparkle 位于普通用户更新助手中，仅助手关闭 Library Validation。助手不在特权服务的客户端登记中。直接加载方案可用 `--profile hardened --load-only` 复现当前系统的 Team ID 拒绝，预期退出失败；`--profile adhoc` 只用于对照实验，不是主程序的发布配置。

`macos/Probes` 中的 Objective-C 宿主和自动应答 driver 是测试夹具，不随产品打包。实际产品将以 Swift 实现更新协调与原生用户确认界面。实验未覆盖下载 quarantine、macOS 13、Intel 或网络服务事务，完整发布验收仍需逐项完成。

## 核心与配置探针

```sh
go run ./cmd/macos-probe
python3 scripts/macos/probe-runtime.py --check-config build/macos-probes/config/offline-config.json
```

核心资产与压缩包摘要锁定在 `internal/mihomo/runtime-assets.json`，来源是对应上游 release。`binarySha256` 从已通过固定压缩包摘要的官方内容计算；生产下载器与探针均校验它。探针限制解压体积，仅执行版本与配置检查。Windows/Intel 资产的摘要和格式校验不等同于相应系统的运行验收。

配置探针生成合成的 P-256 凭据，不向 Cloudflare 注册，也无法建立真实 WARP 会话。`full-config.json` 保留完整业务配置；`offline-config.json` 移除依赖远端 GeoSite/规则集的配置，用于隔离验证 JSON 和 MASQUE 解析。离线检查成功不能替代完整规则、DNS、TUN 与实际出口验证。
