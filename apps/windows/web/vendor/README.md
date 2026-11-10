# Windows 前端依赖

Tauri 将整个 `apps/windows/web` 打入应用。这里保留浏览器实际加载的 ES 模块；入口为 [material.js](../material.js)，模块名由 [index.html](../index.html) 的 import map 解析。液态玻璃效果由 [app.js](../app.js) 按需导入。

| 组件 | 版本或来源 | 用途 |
| --- | --- | --- |
| Material Web | 2.5.0 | 按钮、图标、分隔线、进度环、筛选标签、下拉框和文本框 |
| Lit、lit-html、lit-element、@lit/reactive-element | 2.8.0、2.8.0、3.3.2、1.6.2 | Material 组件运行时（BSD-3-Clause） |
| tslib | 2.5.3 | 编译生成的辅助函数（0BSD） |
| LiquidGlass | [本地模块与许可证](liquidglass/) | 可选的玻璃背景效果 |

更新依赖时，从相应版本的上游浏览器发行文件复制新增模块及其依赖，保留版权声明和各包的版本信息。无需复制 Node、SSR 或开发版目录。在仓库根目录运行以下检查；缺失导入、无效的静态导出或多余的 vendor 模块都会报错：

```sh
node --experimental-vm-modules scripts/check-web-modules.mjs
python3 scripts/check-icons.py
```
