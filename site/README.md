# Flux6 website

官网源码改编自 [FlClash](https://chen08209.github.io/FlClash/zh/)，保留其暖灰配色、排版、动态背景、下载平台切换、双语、主题切换和更新日志搜索。上游版本及本地改动见 [UPSTREAM.json](UPSTREAM.json)；本目录网页沿用 [GPL-3.0](LICENSE)，不改标为根仓库的 MIT 许可。

从仓库根目录运行（Node.js 22+，无需安装依赖）：

```sh
node scripts/site/build.mjs
node scripts/site/preview.mjs --host 127.0.0.1 --port 4173
```

也可在本目录执行 `npm run build` 或 `npm run dev`。构建产物在 `dist/site/`，仅预览服务绑定 loopback；它不会启动客户端、代理或 VPN。修改源文件后重新构建，再刷新页面。`site/index.html` 是构建输入，请不要直接部署此目录。

构建复用仓库已有猫咪品牌图标、0.2.0 桌面及 Android 仪表盘的示例数据截图，不复制上游产品截图。发布数据在 [release.json](release.json)，安装包文件名、大小与摘要来自对应 GitHub Release 的公开附件元数据；发布新版本时同步更新它及两份更新日志，然后重新构建。浏览器无需请求 GitHub API，未获取到远程数据也不会影响已构建页面。

官网、客户端与安装包统一使用 Flux6。0.2.0 首次运行会清空 0.1.x 配置、凭据和用量历史。

GitHub Pages 由 [pages.yml](../.github/workflows/pages.yml) 构建 `dist/site/` 并部署，所有资源使用相对路径，支持项目子路径。站点地址为 https://study-233.github.io/flux6/，仓库 About 使用同一地址。
