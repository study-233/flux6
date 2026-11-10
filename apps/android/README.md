# Flux6 Android

本目录是固定版本 FlClash 的 Android 派生工程。当前功能、构建步骤、来源提交和许可证见 [Flux6 Android 说明](FREEV6.md)。仓库统一规则见 [AGENTS.md](../../AGENTS.md)。

从仓库根目录运行 `bash scripts/android/build-apk.sh`。桌面应用入口、上游网站和发布自动化已经移除；本目录不用于构建 Flux6 Mac 或 Windows。

`plugins/`、`services/helper/` 及 `lib/core/desktop/` 中仍被公共 Dart 代码、构建 hooks 和主机测试引用的代码保留。Android 的运行核心由 Gradle 的 gomobile 任务构建，VPN 生命周期由 Android ServiceState 管理。

项目按本目录 GPL-3.0 许可分发，保留依赖各自的许可与来源。后续同步上游时按 [来源说明](FREEV6.md#来源与许可证) 对照固定提交，不能执行旧的子模块或上游发布流程。
