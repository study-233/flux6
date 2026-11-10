# FreeV6 小猫图标

默认图标是**奶牛猫**。五款共用猫身、前爪、圆眼睛、W 形嘴和单弧尾巴，保留渐变；身体与尾巴整体呼应数字 6。

| SVG 源文件 | 风格 |
| --- | --- |
| [cow.svg](cow.svg) | 奶牛猫，默认 |
| [orange.svg](orange.svg) | 橘猫 |
| [prism.svg](prism.svg) | 炫彩猫 |
| [four-color.svg](four-color.svg) | 四色猫 |
| [earth.svg](earth.svg) | 地球猫 |

[矢量预览](preview.svg) · [PNG 预览](preview.png) · [图标清单](catalog.json)

SVG 使用 512 × 512 画布和透明背景，包含可访问名称；形状、渐变和花纹均可编辑，没有内嵌位图或外部依赖。PNG、ICO 和原生资源是从 SVG 导出的打包副本。

## 软件内选择

- Mac：设置 → 通用 → 外观 → 应用图标；更新运行时 Dock 图标并保存选择。Finder 和安装包使用默认奶牛猫。
- Android：主题 → 应用图标；更新桌面入口及关于页，选择由系统保存。不同桌面的图标缓存刷新时间可能不同。
- Windows（Tauri）：设置 → 外观 → 应用图标；更新窗口、托盘与侧栏并保存选择。安装程序和快捷方式使用默认奶牛猫。

Android 自适应图标预留圆形遮罩安全区域，主题单色图标和通知图标使用同一猫形的矢量模板。图标切换不触发 VPN 启停。

## 修改和导出

共用几何、配色与默认值位于 [generate-cats.py](../../../scripts/branding/generate-cats.py)。

```sh
python3 scripts/branding/generate-cats.py
npm install --prefix build/branding-tools --no-save sharp@0.35.3
FREEV6_SHARP_MODULE="$PWD/build/branding-tools/node_modules/sharp" node scripts/branding/export-icons.cjs
node --test scripts/branding/test-selection.mjs
```

[导出脚本](../../../scripts/branding/export-icons.cjs) 更新共享品牌资源、Mac 资源目录、Android 启动图标与通知模板、Windows Web 图标和原生 RGBA 数据；如果存在 Windows Flutter Runner，也同步其 ICO。Windows helper 还需要按 Windows 构建说明使用固定版本 `go-winres v0.3.3` 重新生成 `.syso`。

每次修改后复查深浅背景、小尺寸、Android 圆形遮罩和各款透明轮廓。原版图标作者的致谢继续保留在 Android 关于页和第三方记录中。
