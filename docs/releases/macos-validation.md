# Mac 开发与验收状态

当前 Mac 主界面使用 Flutter，Swift 负责原生窗口、菜单、业务宿主和网络服务，Go worker 提供公共业务。旧 SwiftUI 应用与其专用界面夹具已退役；当前开发入口为 [Mac 指南](../../apps/macos/README.md)。

## 首个公开正式版

2026-11-10，用户确认安装验收已经完成，并明确本次发行不进行 Apple 公证，按首个公开正式版准备。Android 的安装与真机验证也由用户确认完成。本条记录用户实测结论，不代表本轮文档工作重新执行了安装、联网或设备测试；未提供的系统版本、设备型号与逐项日志不作补填。

[首发准备与待验收文案](first-public-release.md) 汇总版本、分发方式与交付清单。当前仍在本地准备，未创建 Release 或发布标签。

## 保留的验证记录

- [Flutter 宿主集成](../compose/audits/2026-11-07-flutter-host/README.md)：独立数据域和真实 worker 的早期集成证据。
- [候选包、升级、界面与性能](../compose/audits/2026-11-07-p5-p6/README.md)：历史候选版的验证边界。
- [启动出口](../compose/audits/2026-11-08-startup-egress/README.md)、[WARP 自动准备](../compose/audits/2026-11-09-auto-warp/README.md)、[节点批量操作](../compose/audits/2026-11-10-node-batch/README.md)、[准备与下载](../compose/audits/2026-11-10-setup-download/README.md)：专项回归记录。
- [本次仓库整理](../development/repository-maintenance.md)：目录迁移、构建与检查结果。

这些历史记录对应各自日期和源码状态，其中“待验收”描述保留为当时的验证边界。当前安装验收状态以上述用户确认记录为准；该确认不扩展为对全部 macOS 版本、网络环境或跨用户场景的逐项覆盖证明。

## 退役材料

早期 SwiftUI 界面、反复迭代的设计方案和逐步开发日志已从活动目录删除；需要复查时从仓库整理 P0 的 Git 基线查阅。当前构建、签名、更新和专项探针命令仍保留在 [Mac 开发手册](../../apps/macos/DEVELOPMENT.md)。
