# Flux6 Windows

当前 Windows 客户端使用原版 Material Web 界面、Tauri 窗口与 Go helper。当前阶段优先在 Windows 本机编译和预览原版，Flutter 重写暂缓。

在 Windows 开发环境，从本目录运行 `cargo tauri dev` 或 `cargo tauri build`。Tauri 的构建钩子调用仓库根 `scripts/windows/build-helper.ps1`，生成 Go sidecar 并准备 GeoSite 数据。完整说明见 [Tauri 工程](src-tauri/README.md) 和 [统一开发指南](../../docs/development/README.md)。

功能/接口清单、数据迁移、实施阶段与验收要求见 [Windows Flutter 重构实施方案](../../docs/development/windows-flutter-refactor.md)。独立 [Flutter 工程](flutter_ui/DEVELOPMENT.md)已具备预览、真实宿主和候选打包源码；下列命令仍用于现有 Tauri 客户端。用户后续在 Windows 拉取源码编译验收，验证通过后再切换正式入口并单独删除旧代码。

## 安装版节点优选

启动时优先使用本机控制端口 9090。如果该端口无法绑定，当前 Windows 安装版会向系统申请可用的回环端口。流量、节点列表、测速和优选会使用后台为本次连接确认的端口。

安装版在「接入点」页提供自动优选和手动固定。点击节点即可固定，重新连接后按当前网络和分组恢复。手动「测下载」可以选择单连接或 4 连接，单节点两种模式均最多 32 MiB、10 秒，4 连接显示合计下载速度。选择连接数后，列表和速度排序显示对应模式的结果。「测延迟」并发测试最多 6 个节点，每节点请求 3 次，显示成功请求的中位数并记录超时次数。

内置 WARP 的 28 个接入点都可参与自动优选。默认由 4 个接入点轮流承接新连接，可在「接入点 → 自动优选」选择 2、4 或 8 个，立即生效。第一次连接时优先分散到不同入口地址，重连会读取当前网络的并发数和测速历史。已有连接继续使用原接入点。页面标出参与分配的节点，手动固定后所有新连接使用所选节点。

helper 在托盘运行时也会按秒观察实际连接的下载字节增量。如果持续传输的连接连续三个样本低于近期速度的 30%，后台会用短下载与另一个接入点复核。确认掉速后优先用测速通过的候选补位；备用也慢时，由正常的在用节点临时分担。约 10 秒后开始复测被移出的节点，仍慢时约每 30 秒再试，恢复后重新分配新连接。每次验证单节点最多下载 1 MiB、用时最多 4 秒。约五分钟另行抽测候选，手动测速可以优先使用测速通道。

链式代理组和校园备用配置继续按单节点优选。helper 按当前网络、分组取最近两小时最多 6 次可比的单连接记录，结合稳定下载速度和成功率比较。候选连续两轮领先超过 20% 才为新连接切换，普通切换冷却 10 分钟。当前节点下载失败时通过另一个 HTTPS 目标复核，确认原节点故障而候选正常可跳过冷却。4 连接测速结果单独保存。

「本机测速历史 → 节点切换记录」显示切换时间、原节点、新节点和原因。安装目录下的 `state/node-quality.json` 按网络和分组分别保留最近 30 天内最多 1200 条测速记录及 1200 条切换记录。

## 原版离线预览

在本目录使用 x64 MSVC 工具链执行以下命令。独立 target 目录可分别保存离线预览和常规构建。

```powershell
$previousTarget = $env:CARGO_TARGET_DIR
$env:CARGO_TARGET_DIR = Join-Path $PWD 'src-tauri/target/preview'
try {
    cargo tauri build --features offline-preview --no-bundle -- --locked
    if ($LASTEXITCODE -ne 0) { throw 'Preview build failed' }
    & "$env:CARGO_TARGET_DIR/release/freev6-desktop.exe"
} finally {
    $env:CARGO_TARGET_DIR = $previousTarget
}
```

标题栏显示“Flux6 · 离线预览”。预览使用独立的 `dev.flux6.windows.offline-preview` 身份、私密 WebView 和内存中的流量、节点、公告。可以浏览仪表盘、接入点、设置和日志，体验模拟启停与选点。关闭窗口直接退出。预览不启动 Go helper、申请管理员权限或修改系统网络。

## Flutter 候选验证

准备 Flutter 3.47.6、Visual Studio C++ 桌面开发、Go、Python 和 NSIS，执行 `scripts/windows/check-flutter.ps1` 与 `scripts/windows/build-flutter.ps1`。详细命令、旧版数据迁移和原生待验项目见 [Windows 验收手册](../../docs/development/windows-flutter-acceptance.md)。新客户端构建不依赖 Rust。

## 现有 Tauri 本地验证与发布

Windows 的 Rust 编译、Go 平台测试与 NSIS 安装包构建在本地 Windows 主机执行，远端只做通用轻量检查。从仓库根目录运行：

```powershell
go test -timeout=180s ./cmd/... ./internal/... ./mobileapi/...
go vet ./cmd/... ./internal/... ./mobileapi/...
node --test scripts/windows/test-web-runtime.mjs
./scripts/windows/build-helper.ps1
cargo check --locked --manifest-path apps/windows/src-tauri/Cargo.toml
cd apps/windows
cargo tauri build
```

产物位于 `apps/windows/src-tauri/target/release/bundle/nsis/`。发布前核对 Tauri/Cargo 版本一致、CHANGELOG 对应版本说明、安装升级和应用行为。两套构建都会校验 `flux6-helper.exe` 的文件描述为 `Flux6 Helper`。更新 helper 版本资源时，先在 `cmd/freev6-helper/` 执行 `go-winres make --in winres/winres.json --arch amd64 --product-version <版本>.0 --file-version <版本>.0`（`go-winres` 固定为 `v0.3.3`），再构建安装包。

推送 `windows-v<版本>` 或历史 `v*` 标签均不会自动构建/发布。后续发布任务使用本地验收过的安装包，计算 SHA256，准备 Release 草稿和 `version.json`，核验后发布。`version.json` 保留 `version`、`tag`、`notes`、`setup`、`download`、`sha256` 字段，下载地址指向本仓库该标签的同名附件，摘要必须与实际安装包一致。不要将本地产物标成 GitHub Actions 构建或附上不存在的构建证明。
