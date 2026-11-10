# Flux6 website

官网源码改编自 [FlClash](https://chen08209.github.io/FlClash/zh/)，保留其暖灰配色、排版、动态背景、下载平台切换、双语、主题切换和更新日志搜索。上游版本及本地改动见 [UPSTREAM.json](UPSTREAM.json)；本目录网页沿用 [GPL-3.0](LICENSE)，不改标为根仓库的 MIT 许可。

从仓库根目录运行（Node.js 22+，无需安装依赖）：

```sh
node scripts/site/build.mjs
node scripts/site/preview.mjs --host 127.0.0.1 --port 4173
```

也可在本目录执行 `npm run build` 或 `npm run dev`。构建产物在 `dist/site/`，仅预览服务绑定 loopback；它不会启动客户端、代理或 VPN。修改源文件后重新构建，再刷新页面。`site/index.html` 是构建输入，请不要直接部署此目录。

构建复用仓库已有猫咪品牌图标、macOS 隔离截图和 Android 实机截图，不复制上游产品截图。发布数据在 [release.json](release.json)，安装包文件名、大小与 SHA-256 已按 GitHub `v0.1.0` 公开资产核对；发布新版本时同步更新它及两份更新日志，然后重新构建。浏览器无需请求 GitHub API，未获取到远程数据也不会影响已构建页面。

官网与仓库首页品牌为 Flux6。当前 0.1.0 的应用名称、安装包、Homebrew Cask、包 ID、签名与配置目录仍沿用 FreeV6，页面明确说明该过渡状态。改动不重打包或覆盖已发布资产。

`dist/site/` 可作为 GitHub Pages 或其他静态托管的发布目录，所有资源使用相对路径，支持项目子路径。本轮仅本地实现和验证，没有创建远端站点或更改 Pages 设置。
