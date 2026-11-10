# FreeV6 Windows

当前 Windows 客户端仍使用 Web UI、Tauri 窗口与 Go helper。已确定重构方向为 Flutter + Windows 原生宿主，首期保留 Go helper、网络和权限实现；界面风格及页面结构对齐 macOS，保留 Windows 原有功能。

在 Windows 开发环境，从本目录运行 `cargo tauri dev` 或 `cargo tauri build`。Tauri 的构建钩子调用仓库根 `scripts/windows/build-helper.ps1`，生成 Go sidecar 并准备 GeoSite 数据。完整说明见 [Tauri 工程](src-tauri/README.md) 和 [统一开发指南](../../docs/development/README.md)。

重构准备已完成，功能/接口清单、数据迁移、实施阶段与验收要求见 [Windows Flutter 重构实施方案](../../docs/development/windows-flutter-refactor.md)。Flutter 工程和生产入口尚未修改；下列命令仍用于现有 Tauri 客户端。新客户端完成系统功能、数据迁移和安装回归后，再单独删除旧入口。

## 本地验证与发布

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

产物位于 `apps/windows/src-tauri/target/release/bundle/nsis/`。发布前核对 Tauri/Cargo 版本一致、CHANGELOG 对应版本说明、安装升级和应用行为；需要嵌入 helper 版本资源时，先在 `cmd/freev6-helper/` 执行 `go-winres make --in winres/winres.json --arch amd64 --product-version <版本>.0 --file-version <版本>.0`（`go-winres` 固定为 `v0.3.3`），再构建安装包。

推送 `windows-v<版本>` 或历史 `v*` 标签均不会自动构建/发布。后续发布任务使用本地验收过的安装包，计算 SHA256，准备 Release 草稿和 `version.json`，核验后发布。`version.json` 保留 `version`、`tag`、`notes`、`setup`、`download`、`sha256` 字段，下载地址指向本仓库该标签的同名附件，摘要必须与实际安装包一致。不要将本地产物标成 GitHub Actions 构建或附上不存在的构建证明。
