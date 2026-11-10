# P6 本地候选验证

测试机为 Apple Silicon，系统版本 macOS 27.0.1，以普通账户运行。基线是从工作区保留并验证签名的 SwiftUI 0.5.2（build 1），升级目标是 Flutter 0.5.3（build 2）。两个版本的正式应用标识均为 `dev.freev6.desktop`。

最终 DMG 的 SHA-256 为 `6fa5f9e51bf0044df510db5ec3bbc344be5f6ff5af9858a115ff7e0f2b3ed56d`。从该映像打开，以及直接从可写位置打开，实测两份应用的 CDHash 均为 `7dcabc5541e7ecda1a929fa599775ff9b8600056`。[拖拽安装窗口实拍](install-guide.jpg) · [首次启动实拍](first-launch.jpg)

## 安装、首次启动与分发

| 实验 | 实际结果 |
|---|---|
| 在只读 DMG 运行正式 App | 看到 450×182 pt 安装窗口。说明用户拖入“应用程序”、推出磁盘映像，再重开。只有“打开‘应用程序’”和“退出”两个按钮。进程没有映射 Dart AOT，没有启动 worker，也没有创建产品数据目录。|
| 在可写位置运行同身份正式 App | 看到 1232×780 pt Flutter 窗口，系统截图识别到“欢迎使用”“用户协议”“隐私政策”“同意”和“退出”，进程已映射 App AOT。保留未同意状态，临时用户目录内仅新增产品运行日志。|
| macOS 分发检查 | 深度签名验证通过。Gatekeeper 处于启用状态，`spctl --assess` 退出码为 3，判定 rejected。Apple 的发行检查列出 Adhoc Signed App 和 Notary Ticket Missing。此处检查的是本机构建的候选。未进行浏览器下载带隔离标记的该版本首次放行，也没有更改系统 Gatekeeper 策略。|
| 安装包内的特权 payload | 正式 Release 验证器接受签名应用与内嵌服务，独立检查服务 SHA-256，拒绝错误摘要、放宽保护的换签客户端和普通用户安装调用，拒绝后仍可验证原始包。|

启动测量用操作系统限制隔离正式偏好、钥匙串、用户服务、外部网络和现有数据目录，通过独立 home 收集产品创建的日志。实拍只捕捉该测试进程的窗口。比对真实产品目录的文件大小和修改时间，测试前后相同。参见[启动实测](startup.json)、[候选与分发验证](candidate.json)。

## 升级与回退

| 实验 | 实际结果 |
|---|---|
| 从本地候选生成签名 ZIP / appcast | 本地生成一次性 Ed25519 密钥，验签两份文件，解包后再次深验签。Runner、Flutter 引擎和 Dart AOT 的 arm64 指令摘要与候选相同。签名元数据要求 build 1→2、worker 协议 1、服务协议 6、设置格式 1。更换公钥后打包流程在创建产物前拒绝。私钥已清理。|
| Sparkle 更新及重新打开 | 从只对回环开放的签名 feed 获取更新，记录“找到、下载、准备、网络处理确认、安装、旧进程退出”。系统观察到安装位置上一个新的 Flutter 进程，并通过 `lsof` 确认映射 FlutterMacOS 与 App 两个框架。旧端是链接产品更新助手的自动化测试宿主，新端是同一发行 Runner/AOT 的独立身份副本。|
| 在同一份旧数据上回退 | 旧版 worker 写入规则、全局模式、六个代理的加密订阅和 31,000 字节上传用量。新版可读取原设置、解密订阅，然后切为直连，累计上传达到 51,000 字节。关闭新版后，在同一临时安装路径换回完整且经签名验证的旧版 App。旧版保持直连、设置修订号 3、六节点订阅及 51,000 字节累计。两版都通过保存的密文刷新了本地订阅。|
| 更新中断与拒绝 | 损坏的 ZIP 签名或未签名 feed 均保留旧版。另一组测试使用真实 XPC 与临时 DNS 存储，连接清理和 DNS 恢复完成后才安装。故意令 DNS 恢复失败时，安装被阻止，保留旧版，修复故障后能重试恢复。|
| 钥匙串身份变化 | 仅使用新建的临时钥匙串以及合成 WARP、备用、链式记录。ad-hoc 签名变化后，三类记录的非交互读取均返回需要授权。未授权时无法静默覆盖旧记录，不相关身份也无法读取。恢复旧签名后，三类原记录均读回成功，临时钥匙串已删除。|

旧版基线和交付候选均未配置公开的 Sparkle feed 或发行公钥。此次用户测试直接打开候选。临时签名 ZIP 和 appcast 用于本地验证，没有推送到远端。参见[候选实测](candidate.json)、[恢复、签名和钥匙串实验](isolated-system.json)。

## 服务、登录与实网边界

- 在普通用户 Aqua 域注册独立的测试 Mach 服务，验证过客户端/服务双向身份、UID、CDHash、会话所有者、心跳、过期请求、签名轮换与旧登记撤销。真实核心配置校验、回环 TCP 两跳、节点选择与用量采样通过。中断恢复覆盖核心崩溃、协调器重启和 DNS 存储恢复失败。旧版 worker 配合服务升级实验通过 26 项，同一轮基础协议用候选包的真实 worker 复测通过 24 项。两次都已移除临时 launchd 作业。[服务实测](isolated-system.json)
- 登录实验在临时 Library 写入 Aqua 作业，连续两次调用启动器，只启动一个目标进程，收到 `--freev6-login`。作业与条目已删除。真实账户没有注销或切换登录项。[登录实测](isolated-system.json)
- 只读预检显示此机未安装正式服务或 `/Applications/FreeV6.app`，系统已有 HTTP、HTTPS、SOCKS 代理设置。此次未接管系统代理、DNS、路由或 TUN，也未执行系统域服务安装和管理员授权。以上恢复实验均在专用存储或用户域服务内完成。实际联网恢复、更新后正式服务重登记、干净机器首次安装、macOS 14 真机和 Intel 构建仍待对应环境验证。[机器预检](preflight.json)

## 复跑入口

原始 SwiftUI 基线副本位于 `build/p6-release-validation/baseline/FreeV6.app`。以下命令只用于专用测试 Mac 的本地验证，启动实验会临时显示窗口，不同意用户协议。

```sh
python3 scripts/macos/probe-flutter-release.py \
  --candidate dist/macos/FreeV6.app \
  --baseline build/p6-release-validation/baseline/FreeV6.app \
  --output build/p6-release-validation/recheck.json
python3 scripts/macos/probe-flutter-startup.py \
  --candidate dist/macos/FreeV6.app \
  --image dist/macos/FreeV6_0.5.3-preview_arm64.dmg \
  --output build/p6-release-validation/recheck-startup.json
```

## 工件校验与对应源码复建

最终 DMG 经只读挂载、拖拷和验签，应用 ZIP 经过实际解压和深度验签。应用标识为 `dev.freev6.desktop`，版本 0.5.3（build 2），交付签名 CDHash 为 `7dcabc5541e7ecda1a929fa599775ff9b8600056`。三份工件均已对照 SHA-256 重算通过。[工件清单](../../../../../dist/macos/SHA256SUMS) · [候选包记录](final-candidate.json)

源码 ZIP 在独立临时目录解压后，628 个输入逐个通过应用签名所覆盖清单的校验，再实际编译。新应用通过 arm64、最低系统、安装工具内嵌服务摘要、框架签名与八项客户端保护检查。独立复建的 CDHash 为 `cfad22f05b0058ee2b9ed193fa4181d798a29e08`，因此这里只证明源码能构建出可验证的同版本应用，两个二进制的签名摘要不同。[独立复建](source-rebuild.json) · [交付签名保护](client-signing.json) · [复建包签名保护](rebuilt-signing.json)

同次回归通过 22 项 Flutter 测试与 171 项 Swift XCTest，使用固定的 Go worker、Darwin 核心和规则资料，以及专用临时钥匙串，Swift 用例均执行。Dart 静态分析通过。[Flutter 测试日志](../../../../../build/p5-visual/flutter-tests.log) · [Swift 测试日志](../../../../../build/p6-swift-tests.log)
