# FreeV6 Windows

当前 Windows 客户端保留 Web UI、Tauri 窗口与 Go helper，后续将单独进行自定义 UI 重构。本次仓库整理不替换 Windows 界面或网络实现。

在 Windows 开发环境，从本目录运行 `cargo tauri dev` 或 `cargo tauri build`。Tauri 的构建钩子调用仓库根 `scripts/windows/build-helper.ps1`，生成 Go sidecar 并准备 GeoSite 数据。完整说明见 [Tauri 工程](src-tauri/README.md) 和 [统一开发指南](../../docs/development/README.md)。

新 UI 重构的顺序为：功能与接口清单、用户指定 UI、逐页接入现有 helper、系统能力与安装回归、删除被替代的旧 UI。该阶段尚未开始。
