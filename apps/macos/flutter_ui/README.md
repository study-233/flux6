# FreeV6 Flutter for macOS

P5/P6 的正式身份本地验收入口为 [FreeV6.app](../../../dist/macos/FreeV6.app)，版本 0.5.3（build 2）。[安装包、使用步骤和验证记录](../../../docs/compose/audits/2026-11-07-p5-p6/README.md)。从项目根目录运行 `bash scripts/macos/build-app.sh` 构建此版本，运行 `python3 scripts/macos/build-dmg.py` 生成分发包。

P2–P4 的独立验收入口为 [FreeV6 Flutter Integration.app](<../../../build/macos-ui/FreeV6 Flutter Integration.app>)。它将 Flutter 接到 FreeV6 的 Swift 宿主、真实 Go worker 和隔离会话子进程，使用独立数据域。构建命令为 `bash scripts/macos/build-flutter-host.sh`。服务连接流程、独立设置窗口、配置导入、日志操作及旧布局的复测方法见 [P2–P4 验收步骤](../../../docs/compose/audits/2026-11-07-flutter-host/README.md)。

## P1 视觉预览


一个能够在 Mac 上直接打开的 Flutter 界面预览。首页运行固定版本 FlClash 的连接键、速率卡、模式条及 Prism UI 侧栏。连接、速率、用量、延迟和日志全部来自本地演示数据；操作不会设置系统代理、DNS 或启动 FreeV6 服务。

从仓库根目录构建：

```sh
bash scripts/macos/build-flutter-preview.sh
open 'build/macos-ui/FreeV6 Flutter Preview.app'
```

首次构建需要 Xcode、网络和磁盘空间。脚本在 `build/flutter-toolchain/` 准备固定的 Flutter 3.47.6 和包缓存，也可以用 `FREEV6_FLUTTER_SDK` 指定同版本的 SDK。预览的最低部署目标为 macOS 14。本地体验包使用独立标识 `dev.freev6.flutter-preview`，与已有 FreeV6 应用可同时安装。

打开后先看首页，再试这几条路径：

1. 点蓝色花形键断开，点「全局」和「接入节点 → 西区」。上传、下载图标留在原处，无采样显示 `—`。退出并重开，检查离线选择，再点连接键。
2. 点「本月 / 累计」对比总量与分项。右上 `…` 里的「在线零速率」能演示有样本的 `0 B/s`，点「恢复流量」恢复曲线。
3. 通过 `…` 切换「中等窗口」「紧凑窗口」「深色」或「减少动态效果」。收起或展开侧栏，滚动首页，在顶部观察固定的状态或连接操作。⌘1–⌘4 切页。
4. 在「节点」搜索、测速；在「日志」清空演示历史。清空后下一次连接会产生新事件。「配置」只展示演示配置。真实服务和设置窗口尚未接入。

[源码固定版本、改动清单与许可](vendor/UPSTREAM.md) · [完整阶段计划](../../../docs/releases/macos-validation.md)
