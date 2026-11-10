# Flutter 安装器

由 `scripts/windows/build-flutter.ps1` 提供 VERSION、REPO、BUNDLE、OUTPUT 和 UNINSTALL_FILES 后调用 NSIS 3。安装器独立实现，不依赖 Tauri 的模板、插件或 hooks。

- x64，管理员安装/运行，当前用户卸载项 `Software\Microsoft\Windows\CurrentVersion\Uninstall\FreeV6`，主程序 `freev6-desktop.exe`，helper `freev6-helper.exe`。
- 读取旧 HKCU 32/64 位卸载项中的 InstallLocation（兼容包裹引号），升级锁定原目录。全新安装默认 `%LOCALAPPDATA%\FreeV6`。检测到 HKLM 系统范围旧安装时停止并提示人工迁移，避免产生第二套身份。
- 升级直接替换程序资源，保留 config/state/runtime 和旧 WebView。此候选不删除旧代码或改动生产 Tauri 构建入口。
- 安装/卸载前只读检查目标目录中的客户端、helper、mihomo 进程。交互模式允许重试；静默更新最多等待约 30 秒加查询耗时，然后失败退出。没有 taskkill，也不借卸载器修改网络。
- 卸载按构建时生成的文件清单删除程序。默认保留应用数据；只有勾选删除数据才删除 config/state/runtime 和该用户的旧 WebView profile。自动启动仅在任务/Run 指向本安装目录时撤销。
- `/S /FREEV6REL` 安装成功后重新启动；外部更新清单格式沿用旧 helper。此处不生成或上传正式 version.json，不执行签名，不发布 Release。

原生验证以 [验收清单](../../../docs/development/windows-flutter-acceptance.md) 为准。实际旧安装身份仍须运行 `inspect-legacy.ps1` 对照；推测的 profile 位置不能当作迁移成功证据。Tauri 的身份字段参考其[官方 NSIS 模板](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-bundler/src/bundle/windows/nsis/installer.nsi)，具体用户安装以实机记录为准。
