# Flux6 Windows

当前 Windows 客户端仍使用 Web UI、Tauri 窗口与 Go helper。已确定重构方向为 Flutter + Windows 原生宿主，首期保留 Go helper、网络和权限实现；界面风格及页面结构对齐 macOS，保留 Windows 原有功能。

在 Windows 开发环境，从本目录运行 `cargo tauri dev` 或 `cargo tauri build`。Tauri 的构建钩子调用仓库根 `scripts/windows/build-helper.ps1`，生成 Go sidecar 并准备 GeoSite 数据。完整说明见 [Tauri 工程](src-tauri/README.md) 和 [统一开发指南](../../docs/development/README.md)。

功能/接口清单、数据迁移、实施阶段与验收要求见 [Windows Flutter 重构实施方案](../../docs/development/windows-flutter-refactor.md)。独立 [Flutter 工程](flutter_ui/DEVELOPMENT.md)已具备预览、真实宿主和候选打包源码；下列命令仍用于现有 Tauri 客户端。用户后续在 Windows 拉取源码编译验收，验证通过后再切换正式入口并单独删除旧代码。

## Flutter 候选验证

准备 Flutter 3.47.6、Visual Studio C++ 桌面开发、Go、Python 和 NSIS，执行 `scripts/windows/check-flutter.ps1` 与 `scripts/windows/build-flutter.ps1`。详细命令、旧版数据迁移和原生待验项目见 [Windows 验收手册](../../docs/development/windows-flutter-acceptance.md)。新客户端构建不依赖 Rust。

## 现有 Tauri 本地验证与发布

正式包由 [Windows 发行工作流](../../.github/workflows/windows-release.yml) 在 GitHub Actions 的 Windows x64 主机构建；也可在 Windows 本地复现。从仓库根目录运行：

```powershell
go test -timeout=180s ./cmd/... ./internal/... ./mobileapi/...
go vet ./cmd/... ./internal/... ./mobileapi/...
node --test scripts/windows/test-web-runtime.mjs
./scripts/windows/build-helper.ps1
cargo check --locked --manifest-path apps/windows/src-tauri/Cargo.toml
cd apps/windows
cargo tauri build
```

产物位于 `apps/windows/src-tauri/target/release/bundle/nsis/`。发布前核对 Tauri/Cargo 版本一致、CHANGELOG 对应版本说明、安装升级和应用行为；需要嵌入 helper 版本资源时，先在 `cmd/freev6-helper/` 执行 `go-winres make --in winres/winres.json --arch amd64 --product-version <版本>.0 --file-version <版本>.0`（`go-winres` 固定为 `v0.3.3`），再构建安装包。

维护者可手动运行工作流，或推送 `release/windows-*` 分支触发构建。工作流核对 Tauri、Cargo 和界面版本，运行 helper 与 Web 回归，在临时目录执行静默安装，输出 NSIS 安装包、对应源码、`Windows-SHA256SUMS` 和 `version.json`。

版本号跟随 Flux6 多端发行序列。首次 Windows 正式版为 0.1.1；旧 0.5.x 开发版按数值判断版本，需要手动迁移。发布时先把安装包、源码和摘要追加到同版本 Release，核实公开安装包的 SHA256，最后上传 `version.json`。客户端启动时读取本仓库 Latest Release 的清单；今后晋升 Latest 时须一并提供 Windows 清单，可继续指向最近一次已发布的 Windows 安装包。
