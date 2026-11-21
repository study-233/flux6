# Flutter 安装器

由 `scripts/windows/build-flutter.ps1` 提供 VERSION、REPO、BUNDLE、OUTPUT 和 UNINSTALL_FILES 后调用 NSIS 3。安装器独立实现，不依赖 Tauri 的模板、插件或 hooks。

- x64，管理员安装/运行，沿用正式版的当前用户卸载项 `Software\Microsoft\Windows\CurrentVersion\Uninstall\Flux6`，主程序 `freev6-desktop.exe`，helper `flux6-helper.exe`。
- 安装时检查 32/64 位视图中的 `Flux6` 和早期候选的 `FreeV6`，从 InstallLocation 读取原目录（兼容包裹引号）。同目录升级成功后清理旧候选项。两个登记指向不同目录、存在系统范围安装或检测到降级时停止安装。全新安装默认 `%LOCALAPPDATA%\FreeV6`。
- 升级会在新 helper 复制成功后迁移指向本目录旧 helper 的 Run 项并移除旧文件，保留 config/state/runtime 和旧 WebView。此候选不删除旧代码或改动生产 Tauri 构建入口。
- 安装/卸载前只读检查目标目录中的客户端、helper、mihomo 进程。交互模式允许重试；静默更新最多等待约 30 秒加查询耗时，然后失败退出。没有 taskkill，也不借卸载器修改网络。
- 卸载按构建时生成的文件清单删除程序。默认保留应用数据；只有勾选删除数据才删除 config/state/runtime 和该用户的旧 WebView profile。自动启动仅在任务/Run 指向本安装目录时撤销。
- `/S /FREEV6REL` 安装成功后重新启动；外部更新清单格式沿用旧 helper。此处不生成或上传正式 version.json，不执行签名，不发布 Release。

原生验证以 [验收清单](../../../docs/development/windows-flutter-acceptance.md) 为准。实际旧安装身份仍须运行 `inspect-legacy.ps1` 对照；推测的 profile 位置不能当作迁移成功证据。Tauri 的身份字段参考其[官方 NSIS 模板](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-bundler/src/bundle/windows/nsis/installer.nsi)，具体用户安装以实机记录为准。
