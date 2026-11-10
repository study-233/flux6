# FreeV6 平台边界

FreeV6 在一个仓库维护 macOS、Android、Windows。iOS、OpenWrt 仅占位；Windows 已完成 [Flutter 重构准备](../development/windows-flutter-refactor.md)，当前产品入口仍为 Tauri。

| 平台 | 源码 | 系统能力所有者 | 当前状态 |
| --- | --- | --- | --- |
| macOS | `apps/macos` | Swift 宿主、XPC 网络服务；Go worker 提供业务 | 持续开发 |
| Android | `apps/android` | Android VPN 服务与 ServiceState；Go 核心 | 持续开发 |
| Windows | `apps/windows` | 当前 Tauri 窗口与 Go helper | 计划以 Flutter/原生宿主替换 Tauri，保留 Go helper 和现有功能 |
| iOS | `apps/ios` | 待验证 | 仅占位 |
| OpenWrt | `apps/openwrt` | 待验证 | 仅占位 |

`internal/` 保存已有 Go 业务与系统适配，`cmd/` 保存程序入口，`mobileapi/` 为 Android 暴露公共配置和 WARP 业务。嵌套的 Android Go 模块单独测试。`shared/` 保存协议和合成样本；它不代表各平台共用同一套网络生命周期。

公共品牌资源位于 `assets/branding/`，公共随包许可位于 `third_party/licenses/`。各端 UI 分别维护。两份 Prism UI 固定同一上游版本，Mac 的侧栏无障碍补丁单独登记，暂不为去重改变构建与分发边界。

Windows Flutter 首期按固定来源适配 Mac 的视觉组件和页面结构，记录来源及本地补丁；不迁移 Mac 的 Swift/XPC/Keychain 实现，不抽取全平台 UI 框架。托盘、窗口、快捷键、安装与权限由 Windows 宿主适配。

Android 为固定版本 FlClash 源码导出，核心和插件来源见 [Android 来源说明](../../apps/android/FREEV6.md)。当前并非 Git 子模块；更新时对照固定提交、应用本地差异并运行相关回归。
