<div align="center">
  <img src="assets/branding/icon.svg" alt="Flux6" width="100" height="100" />
  <h1>Flux6</h1>
  <p>WARP 与 IPv6 客户端 · macOS / Android / Windows</p>
  <p>
    <a href="https://github.com/study-233/flux6/releases/latest"><img src="https://img.shields.io/github/v/release/study-233/flux6?logo=github" alt="最新版本" /></a>
    <a href="https://github.com/study-233/flux6/releases"><img src="https://img.shields.io/github/downloads/study-233/flux6/total" alt="发行附件总下载量" /></a>
  </p>

[🌐 官网](https://study-233.github.io/flux6/) · [↓ 下载](https://github.com/study-233/flux6/releases) · [💬 反馈](https://github.com/study-233/flux6/issues) · [📖 开发文档](docs/development/README.md)

</div>

## 界面

<p align="center">
  <a href="docs/compose/audits/2026-11-07-p5-p6/visual/offline-1232.png"><img src="docs/compose/audits/2026-11-07-p5-p6/visual/offline-1232.png" alt="Flux6 macOS 界面" height="360" /></a>
  <a href="docs/images/android-home.jpg"><img src="docs/images/android-home.jpg" alt="Flux6 Android 首页实机截图" height="360" /></a>
</p>

## 安装

### macOS

支持 Apple Silicon，macOS 14 及以上。推荐使用 Homebrew：

```sh
brew tap study-233/tap
brew install --cask study-233/tap/flux6
```

也可下载 [DMG 安装包](https://github.com/study-233/flux6/releases)，将 Flux6 拖入「应用程序」。

### Android

安装 [ARM64 APK](https://github.com/study-233/flux6/releases)，首次启动 0.2.0 并同意后，客户端自动准备 WARP 配置，随后可点击连接。内置接入点需要可用的 IPv6 出口。

### Windows

在[发行页](https://github.com/study-233/flux6/releases)下载以 `windows-amd64-setup.exe` 结尾的安装包。启动时会检查更新，可自行选择是否安装。

## 致谢

感谢上游项目及开发者：

- [evansrrr / FreeV6](https://github.com/evansrrr/free-v6)，以及支持上游项目的仍需妙手、别说了，困、星汉灿烂和匿名赞助者
- [chen08209 / FlClash](https://github.com/chen08209/FlClash)
- [chen08209 / Prism UI](https://github.com/chen08209/prism_ui)
- [MetaCubeX / mihomo](https://github.com/MetaCubeX/mihomo)

## 许可证

[MIT](LICENSE) · [第三方许可说明](third_party/README.md)（官网沿用 GPL-3.0）

## Star History

<a href="https://www.star-history.com/?repos=study-233%2Fflux6&amp;type=date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=study-233%2Fflux6&amp;type=date&amp;theme=dark" />
    <img alt="Flux6 星标数随时间的变化" src="https://api.star-history.com/chart?repos=study-233%2Fflux6&amp;type=date" />
  </picture>
</a>
