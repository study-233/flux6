# FreeV6 Homebrew Cask

[Casks/freev6.rb](Casks/freev6.rb) 对应 macOS 0.1.0（build 9），适用于 Apple Silicon、macOS 14 或更新版本。

分发仓库：[study-233/homebrew-tap](https://github.com/study-233/homebrew-tap)。

```sh
brew tap study-233/tap
brew install --cask study-233/tap/freev6
```

Cask 使用固定版本的 DMG 和实际摘要。更新时先上传并核验 Release 资产，再更新 Tap。

网络服务由应用原有授权流程管理。卸载前在 FreeV6 中断开连接并卸载网络服务。

[发行清单](../../docs/releases/first-public-release.md)
