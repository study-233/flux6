# Mac 开发与验收状态

当前 Mac 主界面使用 Flutter，Swift 负责原生窗口、菜单、业务宿主和网络服务，Go worker 提供公共业务。旧 SwiftUI 应用与其专用界面夹具已退役；当前开发入口为 [Mac 指南](../../apps/macos/README.md)。

## 保留的验证记录

- [Flutter 宿主集成](../compose/audits/2026-11-07-flutter-host/README.md)：独立数据域和真实 worker 的早期集成证据。
- [候选包、升级、界面与性能](../compose/audits/2026-11-07-p5-p6/README.md)：历史候选版的验证边界。
- [启动出口](../compose/audits/2026-11-08-startup-egress/README.md)、[WARP 自动准备](../compose/audits/2026-11-09-auto-warp/README.md)、[节点批量操作](../compose/audits/2026-11-10-node-batch/README.md)、[准备与下载](../compose/audits/2026-11-10-setup-download/README.md)：专项回归记录。
- [本次仓库整理](../development/repository-maintenance.md)：目录迁移、构建与检查结果。

这些记录对应各自日期和源码状态，不等于当前版本的全部功能已重新实测。系统网络服务安装、目标校园实际出口、真实系统 DNS 恢复、最低 macOS 版本和跨用户行为仍需要对应环境验收。

## 退役材料

早期 SwiftUI 界面、反复迭代的设计方案和逐步开发日志已从活动目录删除；需要复查时从仓库整理 P0 的 Git 基线查阅。当前构建、签名、更新和专项探针命令仍保留在 [Mac 开发手册](../../apps/macos/DEVELOPMENT.md)。
