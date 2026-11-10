# macOS 开发与验证

[返回构建与安装](README.md)。命令均在仓库根目录运行。普通单元测试不需要安装系统服务；涉及 XPC、Keychain、launchd 或网络恢复的探针请按各节说明准备测试环境与夹具。

## 运行会话恢复验证

`python3 scripts/macos/probe-network-run.py --resources <已校验的服务缓存目录>` 在普通用户的 launchd 域执行启停和中断恢复。缓存目录可取 `probe-service.py` 的产物 `service-data/resources`。测试会创建临时 job，配置 TUN 关闭并使用独立的 DNS 配置库。输出每个场景的结果及证据目录。[会话记录 v3](../../shared/protocol/network-run-v3.md)


## 业务 worker 与配置

App 从 `Contents/Helpers/freev6-worker` 启动当前用户子进程，使用私有 stdin/stdout 帧通信。当前提供代理规则读写、核心和规则数据准备、WARP 注册与业务配置生成，以及本月和累计流量统计。启停及运行节点控制通过系统 XPC 服务。可从“文件 → 导入链式代理配置…”打开系统选择器，或在配置页导入和刷新 HTTP/S 订阅。配置页亦提供备用校园出口，默认出口、链式与备用分别对应 WARP、WARP 再接自有代理、校园节点直接代理。[worker 协议](../../shared/protocol/worker-v1.md)

配置文件：`~/Library/Application Support/dev.freev6.desktop/proxy-preferences.json`。它有独立 schema 和 revision，以原子替换方式写入，拒绝覆盖版本冲突或损坏文件。WARP 凭据保存在 Keychain。订阅地址和节点认证字段使用独立的 Keychain 密钥加密后写入设置文件，节点名称和启用状态保存在公开摘要中。`worker.lock` 防止同一数据目录被多个 worker 同时修改；父进程断开、SIGTERM 或客户端回收后释放锁。

核心缓存：`~/Library/Caches/dev.freev6.desktop/runtime/<archive-sha256>/<archive-name>`。平台资产统一从编译时嵌入的清单选择，压缩包与解压后的二进制均校验固定 SHA256、大小和架构。worker 只保留安装包；App 在服务就绪后的配置检查中交接资源，服务再独立复验与安装，不能把“核心安装包已校验”当作“代理已运行”。主界面与设置共用一个 worker，避免竞争数据目录锁。

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

仪表盘页及设置的“核心与数据”页共用准备状态，提供检查、下载、取消与重试。`geodata.status/prepare` 从编译时清单选择固定提交的三份数据，只有全部校验通过才显示“规则数据已校验”；准备不启动核心。下载与运行时核心共用有界传输、无进展期限和摘要校验。

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

### 原生日志与脱敏诊断

⌘4 打开日志。窗口工具栏与“显示”菜单均可选择级别、暂停及继续显示。暂停期间后台持续记录，恢复后补齐最新事件。右键可复制单条记录。“清空…”确认后清除所有级别的本机应用事件与暂停快照；已导出文件和系统日志不受影响，之后的新事件继续记录。“文件 → 导出日志…”保存当前视图；“文件 → 导出脱敏诊断…”保存版本、架构、组件状态和各来源的最近事件。服务异常时仪表盘也提供诊断入口。

日志来自应用观察到的真实状态变化，使用预定义事件类型。持久化和导出只接受时间与已知事件，避开异常原文、URL、用户名、节点、凭据和原始进程输出。每个来源保留最近 128 条，在用户日志目录的 `journal-v1` 子目录以 0600 文件分开保存。跨进程写入使用文件锁与原子替换。无法使用磁盘时，日志页仍可从内存导出。运行 `bash scripts/macos/swift.sh test --filter DesktopLogsTests` 可验证重启、暂停、筛选导出与不可信文件的处理。

### 备用配置与维护者公告

运行 `python3 scripts/macos/probe-worker.py --refresh-notice` 可用打包后的 worker 在独立测试目录验证公开公告下载与缓存。探针接受维护者当前的开放或关闭决定，仅在结果摘要记录条目数、开关和时间。

在仪表盘页查看或刷新维护者公告，展开会记录已读。普通用户 worker 优先走与 Windows 相同的固定镜像线路，下载失败时显示有效缓存。公告显式开放备用配置后，在配置页填写校园登录页即可派生入口，亦可选择 YAML 或输入自定义获取地址。成功获取会启用这份配置，下次连接无需 WARP 凭据。启用链式时先停用链式，再启用备用；该操作保留另一份配置。仅变更规则会保留两份配置及其启用选择。备用配置的网络刷新可从“连接 → 刷新备用配置”发起。服务未安装时可先进行本机配置检查。

### 验证导入和实际转发

准备好测试 worker、固定核心和规则数据夹具后运行 `python3 scripts/macos/probe-service.py --chain-worker build/macos-worker/freev6-worker --network-run --runtime-fixtures build/macos-probes --geodata-fixtures build/macos-geodata`。探针通过用户域 XPC 和固定核心检查六类节点，并在回环网络测量规则、全局和直连模式的实际 TCP 与 UDP 路径。真实 WARP 首跳在这项测试中由受控的本机 HTTP CONNECT 代理代替。备用配置用独立的合成公告及校园节点，核对无 WARP 路径、组装配置、服务拒绝异常字段、单跳实际转发和测试 DNS 恢复。

## WARP 与 Keychain

仪表盘及设置的 WARP 页提供检查、注册、重新注册、删除本机凭据和保存失败重试。默认由用户主动检查或注册。开启“启动时自动连接”后，启动流程可以无界面读取现有钥匙串条目；需要交互时停止并显示原因。所有文件钥匙串操作共享一条串行队列，静默读取结束后恢复原有交互设置。保存失败保留旧记录和待保存的新结果。

## 首次打开与启动设置

首次打开会显示随包的用户协议与隐私政策，Mac 存储、通信和发行来源说明位于隐私政策开头。应用根据两份文档的实际内容保存本机同意记录。文档变化或缺失时显示主窗口，新的连接、安装与下载命令会等待用户处理。

“设置 → 通用”有三个独立开关，默认均关闭。

- **登录时打开 Flux6** 要求应用位于 `/Applications/Flux6.app` 或当前用户的 `~/Applications/Flux6.app`。Flux6 写入用户级一次性 LaunchAgent。原生登录助手检查应用进程，已有实例时退出；否则通过 Launch Services 打开同一份 App。设置区分用户意愿、等待下次登录、系统允许和需要批准。安装、移除登录项均由用户显式操作。[Apple 登录项状态](https://developer.apple.com/documentation/servicemanagement/smappservice/statusforlegacyplist(at:))
- **启动时收起主窗口** 在当前文档已确认且菜单栏图标可用时生效；从 Dock 或状态菜单可重开主窗口。
- **启动时自动连接** 每次启动最多尝试一次。先完成服务、配置与更新记录核对，再等待网络可用。自动流程复用已有凭据，确认缺失时自动注册并尝试无弹窗保存，仍执行普通连接路径的校园网络、版本、资源、会话和公告校验。手动操作、退出或升级会撤销尚未提交的自动连接。

`python3 scripts/macos/probe-login.py` 在临时用户目录和一次性 Aqua 任务中检查登录助手，运行两次并核对观察进程的启动、重开事件及清理结果。探针使用一个独立无窗口 App。真实账号的登录项、钥匙串和网络保持独立。上面的 `probe-service.py --network-run` 另验证自动连接流程与普通用户域 XPC、固定核心和隔离 DNS 的联动。

WARP 凭据放在当前用户的文件式 Keychain 中，generic-password 的 service 为 `dev.freev6.desktop.warp`、account 为 `credentials-v1`。WARP、链式代理和备用配置各有独立条目，使用创建应用的默认代码访问控制。[Apple Keychain 访问控制](https://developer.apple.com/documentation/security/access-control-lists) · [代码签名与 Keychain 身份](https://developer.apple.com/library/archive/technotes/tn2206/)

从 0.5.5 起，正式宿主在连接或配置检查时通过共享 `WarpRegistration` 自动补齐缺失凭据，访问失败与条目损坏不触发注册。保存失败保留本次注册结果，设置页可继续保存。后台自动连接对读取和写入均关闭授权 UI。默认本地构建使用 `prepare-local-signing.py` 保存的专用证书，两个不同构建可通过相同的指定要求继续访问钥匙串；`probe-keychain-upgrade.py` 使用临时钥匙串验证此行为及不同签名拒绝。旧 ad-hoc 条目迁移到该身份时仍可能需要一次授权。证书和私钥存储说明见 [构建说明](README.md#构建)。

早期候选在 macOS 27.0.1 的隔离钥匙串实测中，Sparkle 安装到相同位置的 ad-hoc 新版需要重新授权才能读取三项旧数据。回退到原签名版本后可以读回原内容及修订号。WARP 用户可从仪表盘点“检查已保存凭据”；配置页会为已有链式代理或备用配置显示各自的密钥检查按钮。这些操作只读对应条目，用户可以在需要时主动触发系统授权。[升级与回退记录](../../docs/releases/macos-validation.md)

条目以随机 revision 保护替换和删除；损坏内容或版本冲突保留原记录。Go worker 不写 `warp.json`；Windows helper 继续使用原有凭据文件。删除本机记录不等于注销 Cloudflare 设备，取消注册也不能保证服务端没有创建设备。新结果仅保留在内存时，正常退出要求先保存或明确放弃。

独立真实 Keychain 测试：

```sh
FREEV6_TEST_PRIVATE_KEYCHAIN=1 bash scripts/macos/swift.sh test --filter WarpCredentialTests
```

测试创建仅含合成数据的临时钥匙串并清理，不读取登录钥匙串。为了测试文件式 Keychain，测试夹具使用已弃用的 `SecKeychainCreate/Delete` 等隔离 API；产品通过 `SecItem` API 访问条目。未设置开关时该项跳过。Go/Swift 共用合成凭据样本，仅用于验证协议和密钥编码，不能用于实际连接。

## 连接配置准备

保存规则、检查已保存凭据并准备核心/规则数据后，可从仪表盘页、工具栏或“连接”菜单执行“检查连接配置”。该操作按需访问 Keychain，将四项隧道材料经私有管道交给 worker；账户 token 和设备 ID 不参与配置生成。准备时防止替换/删除凭据和保存其他设置，完成前重新核对设置与凭据 revision。

worker 只生成节点、分组、规则、规则提供者和模式。`FreeV6Configuration` 模块校验结构和受限字段，拒绝任意插件、未知协议、外部控制器、绝对提供者路径及循环分组。服务就绪时，App 交接缺少的固定资源并提交配置，服务独立复验、准备私有副本、运行真实核心 `-t`，完成任务与文件清理后返回带 `coreValidated` 的摘要。服务未就绪时只完成本机检查，两种结果在界面中区分。配置检查通过后，可发起连接。WARP 可单独使用，也可作为用户导入节点的接入点。导入支持六类协议的受限字段，大小上限 2 MiB、节点上限 64 个。

UI 仅显示模式、节点/规则数量与版本摘要，不缓存私钥文档。交接期间保持凭据互斥，并在服务完成后重新核对 worker 设置与 Keychain revision。共享的 `warp-business-configuration.json` 含公开合成密钥，供 Go/Swift 等价性和拒绝测试使用。真实集成测试需要同时设置 worker、runtime、geodata 三项夹具变量。`cmd/macos-probe` 验证 Go 侧生成配置；下述独立服务探针通过真实 XPC 调用产品检查方法，验证核心成功确认及会话清理。配置检查会短暂保存私有配置并启动检查任务，但不会启动实际代理或修改系统网络。

## 受控子进程

系统模块的 `OwnedChildProcess` 使用 `posix_spawn` 和专属 `waitid`/`waitpid` 观察者持有子进程。执行文件使用绝对路径、参数独立传递，不经过 shell；环境固定为 PATH/LANG/LC_ALL，关闭其他继承描述符，标准输入输出定向到 `/dev/null`。信号发送和最终回收共用锁，只有观察者能释放 PID；停止先 SIGTERM，超时后 SIGKILL，回收失败不得声明已停止。

安装工具的固定 `launchctl` 调用已接入。该类型只管理当前服务持有的子进程，不接受客户端传来的 PID；产品核心检查及跨服务重启的核心管理采用下述独立 job，DNS 恢复由网络会话协调器负责。固定系统命令需要输出时，通过 `CapturedCommand` 单独接管 stdout，容量和读取时间均有上限，stderr 仍丢弃。

进程专项测试使用独立 C 夹具，验证继承隔离、正常/异常退出、超时、忽略 SIGTERM、并发停止与回收。夹具不进入 App 包。运行：

```sh
bash scripts/macos/build-process-fixture.sh
FREEV6_PROCESS_TEST_BINARY="$PWD/build/macos-process/owned-child" \
FREEV6_RUNTIME_FIXTURES_DIR="$PWD/build/macos-probes" \
FREEV6_GEODATA_FIXTURES_DIR="$PWD/build/macos-geodata" \
  bash scripts/macos/swift.sh test --filter OwnedChildProcessTests
```

运行完整原生回归时也应传入 `FREEV6_PROCESS_TEST_BINARY`，连同已有 worker、资源与独立 Keychain 开关。未设置夹具变量的相关测试会跳过。以上测试不启用真实 TUN 或修改 DNS。

## 核心独立 launchd job

`ManagedCoreJob` 让 launchd 直接持有核心进程，以服务生成的 UUID 派生专属标签。注册 job 不会运行核心；开始前必须另行记录启动意图，停止后先持久化退出结果再移除 job。状态通过手册规定的 `launchctl list` 列读取，未知格式报错；不解析 `print` 诊断文本。SIGTERM/SIGKILL 都发给 job 标识，不向历史 PID 发送信号。核心用固定 `/usr/bin/env -i` 原位执行，显式环境且输出丢弃。

普通用户集成探针使用生产管理模块的 Debug 域适配，验证控制宿主被 SIGKILL 后，新宿主可按任务标识完成停止和清理；另验证忽略 SIGTERM、非零退出、拒绝直接移除运行任务及官方固定核心的 `-t`。需要已有 `build/macos-probes` 和 `build/macos-geodata` 固定资源：

```sh
python3 scripts/macos/probe-core-jobs.py
```

结果位于 `build/core-job-probes/<UUID>/result.json`。测试仅使用公开合成配置，不进行 root 安装或修改网络；配置检查使用检查记录 v2，正常运行使用运行记录 v3。Debug 的任意目录和用户域入口不进入 Release。

`python3 scripts/macos/probe-process-group.py` 是独立对照实验：记录服务宿主退出后，继承同一进程组、忽略 SIGTERM 的子进程是否存活，并清理测试夹具。当前系统已观察到存活，因此 `AbandonProcessGroup=false` 不能单独作为核心生命周期保证。该脚本的通过结果只表示实验完成且夹具清理成功，不能当作产品崩溃恢复通过。

## 私有会话准备与恢复

系统模块已提供 `PreparedSessionStore` 和资源层 `prepareSession`：先持久化准备记录，再创建服务所有的 0700 UUID 目录，复制并复验核心/规则数据，写入 0600 配置并绑定摘要。副本使用独立 inode，更新共享资源不改变已准备的会话。配置和资源在交给启动协调器前再次验证，非所属 UID 不能读取工作目录或取消会话。

全局 `network.lock` 与安装工具共用，防止准备会话与安装/卸载并发。准备阶段使用 [v1](../../shared/protocol/session-preparation-v1.md)，运行核心检查前升级为 [v2](../../shared/protocol/session-check-v2.md)，记录注册、启动意图、任务身份、确认退出与移除。服务启动或下次检查前恢复旧记录；未知状态、任务意外丢失、未知文件或链接会保留并报错。正常代理和 DNS 恢复使用单独的[运行记录 v3](../../shared/protocol/network-run-v3.md)。

普通用户强退与恢复探针（参数指向服务资源探针已生成的固定资源目录）：

```sh
python3 scripts/macos/probe-sessions.py --resources /absolute/path/to/verified/service/resources
```

探针使用公开合成凭据，分别在准备中和准备完成后强制结束临时宿主，验证独占锁、恢复记录保留和新进程重复清理。它只在 `build/` 内创建临时目录，不启动核心或修改网络；结果保存在 `build/session-probes/<UUID>/result.json`。恢复测试入口仅存在于 Debug，不随 Release 暴露。

配置检查强退与故障恢复（资源目录可使用下述服务探针的 `service-data/resources`）：

```sh
python3 scripts/macos/probe-check-recovery.py --resources /absolute/path/to/verified/service/resources
```

该探针以普通用户运行固定核心 `-t`，覆盖九个持久化/副作用边界、任务丢失、未知文件、核心拒绝配置和检查超时，共 13 个场景。结果位于 `build/check-recovery-probes/<UUID>/result.json`，不进行 root 安装、TUN 或 DNS 操作。跨系统重启与最低 macOS 14 尚待真实验收。

## 服务安装与事务

应用需位于 `/Applications`。仪表盘页提供安装/重新登记入口，设置页提供恢复未完成安装与卸载入口，管理员凭据交由 macOS 系统授权窗口处理。安装登记同时绑定用户和 App CDHash，更新后的 App 需要重新登记；其他用户的登记保留。管理员安装、升级及卸载需要分别进行实机验收，不将本地模拟事务测试当作系统级成功。

固定系统路径：

- 服务：`/Library/PrivilegedHelperTools/dev.freev6.network-service`
- 恢复/卸载工具：`/Library/PrivilegedHelperTools/dev.freev6.service-installer`
- launchd：`/Library/LaunchDaemons/dev.freev6.network-service.plist`
- 登记：`/Library/Application Support/dev.freev6.desktop/service-registration.json`
- root 私有事务与暂存：`/Library/Application Support/dev.freev6.desktop/installation`
- root 已验证核心与规则数据：`/Library/Application Support/dev.freev6.desktop/resources`

安装工具先复制并验证客户端代码、服务固定摘要和自身代码身份，再修改固定目标。事务持有安装锁和全局网络锁，持久化旧文件、摘要和提交记录；失败回退，恢复失败保留记录供下次重试。安装工具以自己的 root CDHash 完成安装后的双向 XPC 健康检查。发现 `network-session.json` 时拒绝安装恢复、升级和卸载，以免覆盖待恢复的网络状态。服务健康握手不取得网络锁，避免与尚未提交的安装事务相互等待。

如果只有 launchd plist 缺失，而服务、恢复工具和登记文件仍完整，当前安装器会在处理完已有事务后校验两份已安装代码的签名、运行保护和登记身份，再原子重建固定配置。单独恢复不加载或停止服务；安装、升级及卸载在生成回滚快照前完成这一修复，保证升级失败仍能启动旧服务。已有 plist 不会被这一步覆盖，其他文件缺失或身份校验失败仍拒绝继续。应用内维护操作使用当前 App 随带的安装器，避免旧恢复工具缺少修复逻辑；更新到包含修复的版本后，可从“设置 → 网络服务”执行恢复或修复。

误删应用后，管理员仍可使用固定恢复工具的 `recover` 或 `uninstall` 动作。这里的 `recover` 仅恢复安装事务；网络恢复由会话服务负责。卸载移除 daemon、服务、登记和恢复工具，保留 root 私有暂存及资源目录；完整数据清理归入后续卸载验收。

无需管理员权限的真实签名产物验证：

```sh
python3 scripts/macos/probe-installer.py
```

验证正常 payload、错误服务摘要、放宽运行期保护的客户端拒绝，以及非 root 安装拒绝。文件复制到独立的 `build/installer-probes/<UUID>`，不调用系统级 launchd。事务 XCTest 还覆盖首次安装/升级失败、中断恢复、坏备份、符号链接目标、并发锁、多用户重新登记、幂等卸载及缺失 launchd 配置的受限恢复。

## 系统探针

```sh
probe_dir="$(bash scripts/macos/swift.sh build --show-bin-path)"
"$probe_dir/freev6-probe" identity
"$probe_dir/freev6-probe" dns
"$probe_dir/freev6-probe" dns-targets
"$probe_dir/freev6-probe" xpc
"$probe_dir/freev6-probe" xpc-reject
"$probe_dir/freev6-probe" keychain
```

DNS 探针只读。`dns-targets` 统计可选的活动物理服务，并检查 configd 已发布的 DNS 配置有无使用核心端点。

运行 `FREEV6_RUNTIME_FIXTURES_DIR="$PWD/build/macos-probes" bash scripts/macos/swift.sh test --filter SessionDNSTests` 可验证服务内部 DNS 事务。测试使用独立配置树并模拟系统写锁、提交和发布，其中两个边界由测试宿主实际接收 SIGKILL。固定核心在临时端口回答会话专属查询，TUN 关闭。系统级应用、解析器接管和恢复后联网需要单独验收。

XPC 探针使用同一用户下的匿名 listener，分别验证允许的 CDHash 和错误 CDHash；必须先确认可信连接成功，才能将拒绝测试解释为身份校验有效。受限沙箱可能禁止 Mach IPC，需在正常用户环境运行。此探针不证明 root daemon 的安装、重启和升级已通过。

Keychain 探针只创建、读取并删除一个随机标识的 `dev.freev6.probe` 测试项。升级专项可运行 `python3 scripts/macos/probe-native-update.py --scenario keychain-upgrade`。它使用临时钥匙串、随机测试 App 和回环更新源，分别核对原签名、升级签名、无关签名与原版回退后的访问结果，最后删除临时钥匙串并确认用户搜索列表已恢复。

## 独立服务验证

```sh
python3 scripts/macos/probe-service.py
```

在正常登录用户环境运行，不能以 root 运行。脚本构建 Debug 服务和探针，在 `build/service-probes/<UUID>` 内复制并启用 Hardened Runtime，然后注册一个随机名称的用户级 launchd job。验证双向 CDHash、UID 绑定、重启、客户端摘要更换后的重新登记与旧摘要撤销，最后移除该 job。只有可信调用在拒绝测试前后均成功，才记录拒绝通过。结果保存在该目录的 `result.json`。

服务读取权限受控的登记文件，提供版本握手、资源状态、固定资源安装和实际核心配置检查，运行会话另见 [XPC v6 协议](../../shared/protocol/service-v6.md)。Release 构建拒绝探针参数和普通用户启动。这里没有 root 安装、网络启停或生产服务升级；用户级重新登记实验不能替代管理员安装验收。

使用本地官方文件验证跨进程资源交接：

```sh
python3 scripts/macos/probe-service.py \
  --runtime-fixtures build/macos-probes \
  --geodata-fixtures build/macos-geodata
```

探针使用 App 的交接逻辑安装当前架构核心和三份数据，检查权限、错误摘要不覆盖旧文件、未知资源和未登记客户端被拒绝，并在服务重启后复验资源和清理中断暂存。还检查缺资源与系统字段注入拒绝、纯摘要回复、资源复用及完整服务配置的真实核心 `-t`。目录参数只用于普通用户测试宿主，不属于生产 XPC 协议。文件需先通过前述下载探针准备；没有文件时明确失败，不静默跳过。

仅验证核心的 Unix 控制接口：

```sh
python3 scripts/macos/probe-controller.py --core build/macos-probes/mihomo-darwin-arm64
```

此探针使用普通用户、私有临时目录和空的直连配置，关闭 TUN、DNS、代理及所有 IP listener，验证 100 字节路径、版本接口与正常退出回收。固定核心的 Unix listener 忽略 secret 且 socket 为 0666，生产实现必须依靠预先创建并验证的 root/0700 父目录隔离访问；该探针不证明跨用户隔离或 TUN 运行已经通过。

验证新增的原生受限控制客户端：

```sh
bash scripts/macos/swift.sh build
python3 scripts/macos/probe-controller.py \
  --core build/macos-probes/mihomo-darwin-arm64 \
  --native-client build/macos/out/Products/Debug/freev6-probe
```

该模式增加两个仅含 DIRECT/REJECT 的测试分组，实际验证三种模式、特殊字符分组选择、写后回读、错误对端与非法成员拒绝、REJECT 测速失败、累计流量及有界的流量单次采样。仍不启用 TUN、DNS 或 IP 监听。服务内部契约、响应上限见 [核心控制接口 v1](../../shared/protocol/core-controller-v1.md)；节点、模式与流量操作见 [XPC v6 协议](../../shared/protocol/service-v6.md)。

## 原生更新验证

```sh
python3 scripts/macos/probe-update.py --isolated-agent
python3 scripts/macos/probe-update.py --isolated-agent --invalid-signature
```

脚本核验 Sparkle 2.9.6 官方压缩包，使用临时 Ed25519 密钥、随机 bundle ID 和仅监听 `127.0.0.1` 的 appcast。测试只更新独立测试 App，并检查实际版本、重启 PID、主程序 Hardened Runtime 和 entitlement；结果位于 `build/update-probes/<UUID>/result.json`。临时私钥、监听服务器及本次测试的偏好和更新缓存会清理，构建产物与诊断保留。

主测试 App 仅链接系统框架；Sparkle 位于普通用户更新助手中，仅助手关闭 Library Validation。助手不在特权服务的客户端登记中。直接加载方案可用 `--profile hardened --load-only` 复现当前系统的 Team ID 拒绝，预期退出失败；`--profile adhoc` 只用于对照实验，不是主程序的发布配置。

`apps/macos/Probes` 中的 Objective-C 宿主和自动应答 driver 用于早期验证。当前产品的 Swift 更新助手和发布脚本见下一节。上述实验仍需补充下载 quarantine、macOS 14 及网络服务事务验收。

## Swift 更新助手与发布

Flux6 菜单的“检查更新…”打开原生检查流程。App 使用私有管道启动 bundle 内的普通用户更新助手。助手校验宿主与父进程，从经过代码签名验证的宿主读取通道和公钥。Sparkle 仅嵌入该助手。主 App 保留严格 Hardened Runtime，打包检查确认主可执行文件的依赖与助手的 entitlement 范围。

更新清单和 ZIP 均要求 Ed25519 签名。清单包含构建号范围、架构、worker/服务协议、设置 schema、核心清单摘要和服务摘要。当前路径支持 worker v1、服务 v6、设置 schema v1；其他协议升级需先实现兼容逻辑。助手先验证清单，再由 Sparkle 校验下载和解压。主程序在安装前确认保存草稿与网络恢复，将升级意图写入用户私有目录，然后退出。新版本检查服务状态，按需引导管理员重新登记。自动安装和系统画像上传在通道配置中关闭。[Sparkle 签名设置](https://sparkle-project.org/documentation/customization/)

Sparkle 的 applicationBundle 指向更新助手，安装目标为外层 Flux6。助手收到取消后等待 Sparkle 完成撤销，再通知主程序结束，避免把退出误当作允许安装。开发测试覆盖实际升级、坏包签名、未签名清单、错误架构、取消下载、取消安装与安装许可前主进程消失。

```sh
python3 scripts/macos/probe-native-update.py --scenario upgrade
python3 scripts/macos/probe-native-update.py --scenario cancel
python3 scripts/macos/probe-native-update.py --scenario lost-host
python3 scripts/macos/probe-release-package.py
```

测试宿主使用随机 bundle ID、回环源和一次性密钥。正式打包强制编译生产助手，关闭测试中的自动应答和回环通道。检查结果位于 `build/native-update-probes` 和 `build/release-package-probes`。其中的网络恢复许可由测试宿主模拟，完整系统服务升级仍需真实管理员环境。

要验证已有连接时的升级，请运行以下组合探针。它启动普通用户域的临时 XPC 服务与固定核心，在独立的 DNS 配置库上调用和主应用相同的 `disconnectBeforeUpdate`。签名更新助手等待结果后再安装。恢复失败场景还会核对旧版、运行中的核心和故障解除后的自动清理。两个测试 App 的事件及实际版本记录在服务报告的 `updateProbes` 中。

```sh
python3 scripts/macos/probe-service.py --network-run --update-recovery \
  --chain-worker build/macos-worker/freev6-worker \
  --runtime-fixtures build/macos-probes --geodata-fixtures build/macos-geodata
```

Mac 的发布仓库为 `study-233/flux6`。启用应用内更新时，签名清单放在专用 `macos-updates` 分支根目录，客户端读取该分支对应架构的 `appcast-<架构>.xml`。每个 ZIP 放在固定标签的 Release 下，例如 `v0.1.0`。这样可以在更新清单前先验证 ZIP 已经能匿名下载，同时保留旧版本。同一版本只创建一个 Release，集中放置 macOS、Android 及其他已交付平台的附件；正式版使用 `prerelease=false`，最新正式版本设为 Latest。下载及 Homebrew Cask 均使用固定的 `v<版本>` 标签。Windows 采用本地构建与手动发布，当前不在首发范围。[首发准备](../../docs/releases/first-public-release.md) · [GitHub Release 参数](https://docs.github.com/en/rest/releases/releases#create-a-release)

启用应用内更新需要保管和备份发布私钥，再从对应公钥生成通道 JSON。构建带更新能力的 DMG 时，通过 `FREEV6_UPDATE_CHANNEL_FILE` 指向该文件。首发仅覆盖 arm64；启用通道时另附 arm64 更新 ZIP 与 `appcast-arm64.xml`。未配置通道的构建仍显示通道待配置，不把 DMG 或 Homebrew 的可下载状态当作应用内更新已上线。本次不进行 Apple 公证，通道签名与代码签名校验仍须保留。

```sh
python3 scripts/macos/github_channel.py --public-key-file /secure/path/mac-public-key.txt \
  --output /secure/path/mac-channel.json
python3 scripts/macos/package-update.py \
  --channel /secure/path/mac-channel.json --private-key /secure/path/ed25519-key \
  --output /path/to/new-release-directory \
  --build 2 --version 0.5.3 --minimum-source-build 1 --maximum-source-build 1
```

该工具验证密钥与公钥对应关系、App 签名、架构及载荷，输出完整 ZIP、签名 appcast 和摘要，全部完成后才生成本地输出目录。私钥通过 stdin 交给签名工具。发布时先上传版本化资产并核对公开下载的摘要，再以一次 Git 提交更新对应架构的清单。检查通过后保留上一版 DMG 和发行记录，便于恢复。

## 核心与配置探针

```sh
go run ./cmd/macos-probe
python3 scripts/macos/probe-runtime.py --check-config build/macos-probes/config/offline-config.json
```

核心资产与压缩包摘要锁定在 `internal/mihomo/runtime-assets.json`，来源是对应上游 release。`binarySha256` 从已通过固定压缩包摘要的官方内容计算；生产下载器与探针均校验它。探针限制解压体积，仅执行版本与配置检查。Windows/Intel 资产的摘要和格式校验不等同于相应系统的运行验收。

配置探针生成合成的 P-256 凭据，不向 Cloudflare 注册，也无法建立真实 WARP 会话。`full-config.json` 保留完整业务配置；`offline-config.json` 移除依赖远端 GeoSite/规则集的配置，用于隔离验证 JSON 和 MASQUE 解析。离线检查成功不能替代完整规则、DNS、TUN 与实际出口验证。

## 原生连接、断开和退出

服务准备完成后，从三个顶部入口均可操作本人的会话。普通模式在启动前向 Windows 客户端使用的固定 IPv6 回显地址发起限时查询，并匹配 2001:da8::/32 或 2001:250::/32。已保存的开发者模式跳过此检查。桌面每 5 秒查询一次，主窗口隐藏时继续续期。退出重新确认会话和修订号，恢复失败时留在仪表盘。旧协议的安装需先通过仪表盘重新登记服务。当前菜单中的“已保存配置”表示下次连接将使用的配置。
