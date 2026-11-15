# Flux6 Homebrew Cask

[Casks/flux6.rb](Casks/flux6.rb) 对应 macOS 0.1.1（build 12），适用于 Apple Silicon、macOS 14 或更新版本。

分发仓库：[study-233/homebrew-tap](https://github.com/study-233/homebrew-tap)。

```sh
brew tap study-233/tap
brew install --cask study-233/tap/flux6
```

每个 Flux6 版本共用一个 `v<版本>` Release。Cask 使用其中的 macOS DMG 和实际摘要。Apple Silicon 的 DMG 使用 `Flux6-<版本>-macos-arm64.dmg`，摘要见同一 Release 的 `SHA256SUMS`。更新时先上传并核验 Release 资产，再更新 Tap。

网络服务由应用原有授权流程管理。卸载前在 Flux6 中断开连接并卸载网络服务。

[发行清单](../../docs/releases/v0.1.1.md)

原 `freev6` Cask 通过 `cask_renames.json` 迁移至 `flux6`。保留既有应用数据与服务标识。
