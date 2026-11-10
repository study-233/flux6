# 0.5.4 启动时序修复与验证

## 原因与修改

离线采集表明：系统代理关闭后，FreeV6 已建立本会话的 utun 并设置 DNS，但首次 HTTPS 请求立即发生 TLS 连接重置，服务随即回滚并停止核心。核心此时仍在加载规则和执行节点健康检查。

固定版本 mihomo v1.19.31 先启动控制接口、DNS 与 TUN，随后加载规则提供器，最后进入 Running。控制接口返回版本和 TUN 存在均不能证明转发已可用。初始化期间的外部 TCP 会被主动关闭。依据：[ApplyConfig 顺序](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/executor/executor.go#L78-L116)、[TCP 状态检查](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/tunnel/tunnel.go#L473-L477)。

本版修改：

- 等待控制接口后，在同一 30 秒预算内等待属于当前核心 PID 的 TUN；进程变化立即失败。
- HTTPS 启动检测使用 45 秒单调时钟预算，仅重试 DNS、连接、超时及连接重置等暂时性传输失败。单次请求最多 8 秒，并受剩余预算限制。
- 每次请求前后及成功返回前重新核对核心 PID、TUN 名称与索引。HTTP 204、TLS 验证、实际响应对端 IP 和对应隧道路由检查均保留。
- 证书错误、无效响应、错误路由和身份变化立即失败；最终失败继续走现有 DNS 恢复、核心停止与会话回收流程。超时错误包含脱敏的 curl 错误码。
- 增加仅 Debug 可用的隔离启动探针。Release 中不提供自定义测试地址或测试 CA。

## 验证结果

| 验证 | 结果 |
| --- | --- |
| 完整 Swift 回归 | 181 项通过，0 失败、0 跳过，含新增 10 项启动检测测试 |
| 固定真实核心延迟规则加载 | 通过；旧单次检测 curl 35 / HTTP 000，新检测依次得到 35、35、0，最终 HTTPS 204 |
| 启动、回滚与崩溃恢复 | 23 个用户域隔离场景全部通过 |

真实核心探针会保持本地规则提供器不返回，确认控制接口和 DNS 已能响应，再执行原先的单次检测和生产 Swift 重试逻辑。收到两次实际 TCP 失败后才释放规则，成功时同一核心仍存活。测试仅使用回环端口、合成配置与临时 TLS CA，无系统代理、DNS、TUN 或现有凭据变更。

本地原始证据：

- `build/http-diagnosis/swift-regression-tests.log`
- `build/http-diagnosis/startup-egress-verification.json`
- `build/http-diagnosis/network-recovery-probes.log`
- `build/network-run-probes/4ee4991b-e471-46e1-998a-7204da4d3322/result.json`

真实校园网络连接仍需使用者安装本版后验收：退出旧版、替换应用，在“设置 → 网络服务”点击“安装网络服务…”或“修复网络服务…”更新后台服务，再关闭其他代理并测试连接；测试完成后恢复用于联系的代理。

## 安装包验证

0.5.4（build 3）Release 已生成。DMG 只读挂载后的拖放副本及应用 ZIP 解包副本均通过签名、架构、最低系统版本、依赖路径与安装器内嵌服务摘要校验；安装器载荷探针也通过可信载荷、错误摘要、放宽签名拒绝和普通用户拒绝特权操作检查。对应源码包通过与已签名应用的源码清单逐字节比对。

未替换 `/Applications/FreeV6.app`，未更新已安装的 root 服务，未改变正在使用的系统代理。

| 文件 | SHA-256 |
| --- | --- |
| `FreeV6_0.5.4-preview_arm64.dmg` | `fbabb3de9e43a00989bdaf49f86d7b78618488c91471cbd1629682db60233edd` |
| `FreeV6_0.5.4_3_arm64.zip` | `0b9074063945491cc0350453228f5f5843f868cffc811cc506c693b252b33599` |
| `FreeV6_0.5.4_3_source.zip` | `f074e5c806522a05f25b80295a4eb5fc0ac91472fee67abf5929a0ea05b306bd` |

额外证据：`build/http-diagnosis/release-0.5.4-build.log`、`build/http-diagnosis/installer-0.5.4-verification.log`。
