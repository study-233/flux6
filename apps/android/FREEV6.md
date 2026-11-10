# Flux6 Android

基于 FlClash 的 Android 客户端，复用其 Flutter 页面、Android VPN 服务、节点测速和 mihomo 核心。此目录基于固定版本源码导出，已移除不用的桌面 Runner、上游网站和发布工具，保留公共 Dart 代码所需的插件和核心。Flux6 接口放在根目录 `mobileapi/`，直接复用 `internal/app` 和 `internal/warp` 的配置与注册逻辑。

首个公开正式版为 0.1.0。用户已于 2026-11-10 确认安装验收与 Android 真机验证完成；本次更新记录该结论，不重复执行真机测试。版本、打包与发布状态见 [首发准备](../../docs/releases/first-public-release.md)。

## 0.1.0 首发范围

- 独立引导准备 WARP：首次注册、后续复用；自动生成 28 个 IPv6 MASQUE 接入点。
- 校园直连域名／CIDR 输入，保留 Flux6 默认分流及规则提供器。
- 使用 FlClash 原有连接开关、VPN 授权、流量统计、节点选择和测速。
- Android Keystore AES-GCM 加密存储 WARP 账户；禁止系统备份。生成的代理配置包含运行所需的隧道私钥，保存在应用私有目录。手动导出配置会包含该私钥。
- 准备配置要求 Wi-Fi 上有非链路本地 IPv6 地址和 IPv6 默认路由，允许路由器通过 ULA（fd…/fc…）进行转发／NAT6；VPN 出站套接字绑定 Wi-Fi，Wi-Fi 断开后通过原有 ServiceState 停止。
- 独立应用 ID `dev.freev6.mobile`，不会覆盖 FlClash。关闭上游自动更新，后续版本手动安装 APK 更新。

尚未接入 Flux6 桌面端的链式代理、云同步及完整诊断界面；iOS 不在这一版范围内。

## 安装与回归

将 ARM64 APK 传到 Android 手机，允许文件管理器安装应用。连接具有 IPv6 出口的 Wi-Fi 后，打开 Flux6，按首次引导检查网络并准备配置，然后回到首页点击连接并同意 Android VPN 授权。已有配置的升级用户直接进入首页；校园直连域名／CIDR 可在「工具 → Flux6 设置」中展开编辑。

版本与 build 以 [pubspec.yaml](pubspec.yaml) 为准。当前构建脚本输出 `dist/android/<版本>-b<build>/Flux6-<版本>-b<build>-arm64.apk`；发行交付清单见 [首发清单](../../docs/releases/first-public-release.md#版本与交付物)。

后续版本的回归项目：首次启动与授权、准备配置、节点测速、IPv4/IPv6 网站访问、校园站点直连、切换节点、锁屏后连接、断开 Wi-Fi 后停止、再次启动是否复用账户。首次正式版的用户实测结论见上文。

## 首次引导与首页

首次无配置启动时显示欢迎页，随后依次检查 Wi-Fi、准备配置、回到首页连接。可选择「稍后设置」，以后从工具页继续。完成或退出引导后保存已展示状态；已有配置的用户升级时直接跳过，不读取或重建 WARP 账户。首页不再插入设置和诊断卡片。

「工具 → Flux6」提供独立设置和网络检测入口。校园分流默认收起；已有校园条目会自动展开。地址和探测细节默认收起，未确认出口时会在摘要提示。主按钮与滚动内容分开布局并避让系统安全区和键盘。Android Release 界面与关于页均不显示测试版标识；关于页保留手动更新提示。

## IPv6 排查

早期测试版仅接受 2000::/3 地址，误拒绝通过 ULA 和路由器转发访问 IPv6 的网络。当前不再要求手机本身持有公网地址；没有 Wi-Fi、没有可用地址、没有默认路由会分别提示。「工具 → 网络检测」显示本机 IPv6 地址，并使用 Android Network.socketFactory 将 TCP 探测绑定到同一个 Wi-Fi，访问 2001:da8:d800::1043 和 2606:4700:4700::1111 的 443 端口，每个最多 2.5 秒。探测不使用 DNS、应用代理或蜂窝回退。

TCP 探测只是诊断，不是 WARP UDP/QUIC 的连通性结论；全部探测失败也不会阻止已有 IPv6 地址和路由的网络准备 WARP。实际使用仍须连接后测速。

## 构建

已固定 Flutter 3.47.6、Go 1.27.0、Rust 1.99.0、Android NDK 28.2.13676358，其他依赖见各 lock 文件。Android SDK 平台和构建工具由 Gradle 配置声明。

在仓库根目录运行 `bash scripts/android/build-apk.sh`。`scripts/android/env.sh` 使用已有的工具缓存；其他机器可把 Flutter、Go、Rust 放在 PATH，并用 `FREEV6_FLUTTER_SDK`、`FREEV6_ANDROID_SDK`、`FREEV6_JAVA_HOME` 指定本机路径。首次构建会下载依赖。`apps/android/core/go.mod` 的 `replace ../../..` 要求保留平台目录与根模块、`internal/`、`mobileapi/` 的相对位置。`python3 scripts/android/package-source.py` 将必要源文件打入对应版本源码包。

脚本在仓库外私有目录创建或复用既有签名，旧 `build/mobile-signing/` 身份会先校验再迁移。macOS 默认目录为 `~/Library/Application Support/FreeV6/Development/android-signing/`，Linux 使用 XDG 数据目录。请备份该身份以便覆盖安装后续版本；不要提交或随源码分发私钥。也可设置 `FREEV6_KEYSTORE`、`FREEV6_STORE_PASSWORD`、`FREEV6_KEY_ALIAS`、`FREEV6_KEY_PASSWORD` 使用自己的签名。[签名和缓存规则](../../docs/development/README.md#签名和缓存)

验证命令（在仓库根目录使用 Bash）：

```bash
source scripts/android/env.sh
go test -timeout=180s ./cmd/... ./internal/... ./mobileapi/...
(cd apps/android/core && go test -timeout=180s ./... && go vet ./...)
(cd apps/android && flutter analyze --no-fatal-infos)
(cd apps/android && flutter test test/common/freev6_test.dart test/core/ test/l10n/localization_contract_test.dart test/widgets/freev6_setup_test.dart)
(cd apps/android/android && ./gradlew :app:testDebugUnitTest :service:testDebugUnitTest -Ptarget-platform=android-arm64)
```

## 来源与许可证

| 组件 | 来源固定版本 |
| --- | --- |
| FlClash | `chen08209/FlClash` · `be84736605527034689c95bf27828ff27d912c5e` |
| Prism UI | `chen08209/prism_ui` · `63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185` |
| Clash.Meta | `chen08209/Clash.Meta` · `024245dc72bc92f48237f865119afe0cd53ac9e6` |

Flux6 Android 是修改后的 FlClash 版本，由 Flux6 维护。Android 派生应用按本目录的 GPL-3.0 `LICENSE` 分发；保留上游作者、资源、各组件原有许可证和致谢。根目录 Flux6 原有代码保留根目录 MIT 许可，不将 FlClash 改标为 MIT。APK 分发时一并提供该版本完整对应源码和构建脚本；本地测试签名私钥不属于源码包。
