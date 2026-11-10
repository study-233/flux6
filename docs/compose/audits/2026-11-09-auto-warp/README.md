# 0.5.5 自动准备 WARP 与稳定签名

## 行为

- 用户同意协议后，在连接或检查配置时读取已有 WARP 凭据；仅在钥匙串明确返回条目不存在时注册新设备。
- 自动连接沿用相同路径，但读取和保存均禁止弹出钥匙串授权窗口。拒绝授权、钥匙串锁定、内容损坏和版本冲突均不会触发替换注册。
- 连接与设置页共享 `WarpRegistration`。同一宿主中的并发操作不会创建重复设备；保存失败或注册返回后取消操作，仍在当前应用进程保留新结果供重试保存。
- 已有凭据复用，备用配置分支不触发 WARP 注册；原有凭据修订、设置修订、核心和会话校验继续执行。
- 默认构建使用本机持久的自签名证书。钥匙串根据稳定的应用标识及证书识别后续版本。旧 ad-hoc 版本迁移时可能仍需一次授权；没有修改旧条目的访问控制。

## 签名范围

签名材料位于当前用户 `~/Library/Application Support/dev.freev6.build-signing` 的私有目录。专用钥匙串仅允许系统 `codesign` 使用签名私钥；随机口令不经命令行传入。源码和安装包不包含私钥。未修改系统信任，未开放所有应用访问钥匙串；证书不是 Developer ID，也不是 Apple 公证。

本地 Flutter 宿主继续使用内核强制的框架 CDHash 白名单，安装器继续固定宿主程序及限制数据的摘要。XPC 服务注册仍绑定具体版本的 CDHash，不因钥匙串身份稳定而放宽。

## 已通过验证

| 验证 | 结果 |
| --- | --- |
| Swift 全量回归 | 189 项通过，0 失败、0 跳过 |
| 自动注册工作流 | 首次注册、重启复用、拒绝/锁定/损坏不注册、并发拒绝、保存重试、取消保留、网络失败重试、外部变更保护 |
| 正式宿主配置准备 | 真实 Go worker + 本地固定资源，自动注册后设置页共享账户，重复检查不重复注册 |
| 跨版本钥匙串 | 两个不同二进制使用同一证书，无 UI 读取旧条目成功；相同标识的无关签名读取被拒绝 |

测试只使用合成 WARP 凭据和临时钥匙串，没有注册真实 Cloudflare 设备，也没有读取用户的现有 WARP 凭据。没有安装新版应用或改动系统网络服务。

证据：

- `build/account-automation/swift-regression.log`
- `build/account-automation/credential-tests.log`
- `build/account-automation/local-keychain-upgrade.json`
- `build/account-automation/release-0.5.5-build.log`

## 安装包验收

0.5.5（build 4）已完成签名、DMG 只读挂载副本、ZIP 解包副本、安装器服务摘要和源码清单一致性验证。8 个框架加载与篡改拒绝场景、5 个安装器载荷场景均通过。实际签名应用的 Flutter 欢迎窗口及只读镜像安装窗口均通过启动检查；测试沙盒禁止网络、用户钥匙串及现有服务访问，生产数据目录元数据保持不变。启动探针的原始 build 2 断言在本次运行时绑定到 build 4，其余检查保留。

附加证据：`build/account-automation/flutter-signing.json`、`build/account-automation/installer-verification.log`、`build/account-automation/flutter-startup.json`。

```text
856ee486c94d30edf23494be50bafa719ab600c8177d8e50cd2b5bc11d7f30bc  FreeV6_0.5.5-preview_arm64.dmg
52e489ce36b67ff8516331fab8b370ee9e3aaced8e04d73c20b29d1846ce9605  FreeV6_0.5.5_4_arm64.zip
c5e7d9d0674c538255135ecc99a5d69144b9b40f829226e69571b0afaf7904f2  FreeV6_0.5.5_4_source.zip
```
