# FreeV6 平台边界

FreeV6 在一个仓库维护 macOS、Android、Windows。iOS、OpenWrt 仅占位；Windows 自定义 UI 重构是后续独立阶段。

| 平台 | 源码 | 系统能力所有者 | 当前状态 |
| --- | --- | --- | --- |
| macOS | `apps/macos` | Swift 宿主、XPC 网络服务；Go worker 提供业务 | 持续开发 |
| Android | `apps/android` | Android VPN 服务与 ServiceState；Go 核心 | 持续开发 |
| Windows | `apps/windows` | Tauri 窗口与 Go helper | 保留现有功能，后续重构 UI |
| iOS | `apps/ios` | 待验证 | 仅占位 |
| OpenWrt | `apps/openwrt` | 待验证 | 仅占位 |

`internal/` 保存已有 Go 业务与系统适配，`cmd/` 保存程序入口，`mobileapi/` 为 Android 暴露公共配置和 WARP 业务。嵌套的 Android Go 模块单独测试。`shared/` 保存协议和合成样本；它不代表各平台共用同一套网络生命周期。

公共品牌资源位于 `assets/branding/`，公共随包许可位于 `third_party/licenses/`。各端 UI 分别维护。两份 Prism UI 固定同一上游版本，Mac 的侧栏无障碍补丁单独登记，暂不为去重改变构建与分发边界。

Android 为固定版本 FlClash 源码导出，核心和插件来源见 [Android 来源说明](../../apps/android/FREEV6.md)。当前并非 Git 子模块；更新时对照固定提交、应用本地差异并运行相关回归。
