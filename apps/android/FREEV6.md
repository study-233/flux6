# Flux6 Android 0.2.0

Android ARM64 客户端基于 FlClash v0.9.5。首次启动同意设备注册后，应用自动准备 WARP 配置。配置就绪后可手动连接并授予 Android VPN 权限。离线或注册失败时，可在仪表盘打开用量入口重试。再次生成配置也可从配置页的添加菜单进入。

首次启动 0.2.0 会清空旧配置、账户凭据、偏好和流量历史。清理中断时下次继续，完成后保留新数据。Android Keystore 保护凭据，核心使用的 YAML 包含隧道密钥，保存在应用私有目录；手动导出此配置会包含密钥。

仪表盘显示本月用量，点击可查看本次连接、本月和累计的上下行统计。设置中的「仅统计代理流量」也适用于历史读数。这里显示本机核心的字节数；实际套餐用量由网络提供方计算。

配置准备适用于 Wi-Fi、蜂窝及其他可用网络。默认配置包含 28 个 IPv6 MASQUE 接入点，连接这些接入点需要底层网络能访问 IPv6。连接生命周期由 Android ServiceState 管理。

## 构建与验证

使用 Flutter 3.50.1、Go 1.27 和 Gradle 声明的 Android NDK。在仓库根目录使用 Bash 运行以下命令。签名身份保存在仓库外，见[开发与签名说明](../../docs/development/README.md)。

```bash
bash scripts/android/build-apk.sh
source scripts/android/env.sh
(cd apps/android/core && go test -timeout=180s ./... && go vet ./...)
(cd apps/android && flutter pub get --enforce-lockfile && flutter analyze --no-pub)
(cd apps/android && flutter test --no-pub test/common/freev6_test.dart test/common/warp_setup_test.dart test/common/release_reset_test.dart test/core/ test/views/dashboard/)
(cd apps/android/android && ./gradlew :app:testDebugUnitTest :service:testDebugUnitTest -Ptarget-platform=android-arm64)
```

版本和构建号取自 [pubspec.yaml](pubspec.yaml)。APK 写入 `dist/android/<版本>-b<build>/Flux6-<版本>-android-arm64.apk`。在相同提交运行 `python3 scripts/android/package-source.py` 生成对应源码。

## 来源与许可证

| 组件 | 来源固定版本 |
| --- | --- |
| FlClash | `chen08209/FlClash` · `deba70d80d2af509171f9c6465de9d14719f0399` |
| Prism UI | `chen08209/prism_ui` · `cae9a43572bddb9b20b9350ef7fde3f434a758c7` |
| Clash.Meta | `chen08209/Clash.Meta` · `fea29264f541cba170bb8b7dda84697aa1dbcc3b` |

Flux6 Android 是修改后的 FlClash 版本，由 Flux6 维护。Android 派生应用按本目录的 GPL-3.0 `LICENSE` 分发；保留上游作者、资源、各组件原有许可证和致谢。根目录 Flux6 原有代码保留根目录 MIT 许可，不将 FlClash 改标为 MIT。APK 分发时一并提供该版本完整对应源码和构建脚本；本地测试签名私钥不属于源码包。
