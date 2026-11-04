# macOS 核心控制接口 v1（服务内部）

此契约描述 Swift 网络服务与固定 mihomo 核心之间的控制操作，不新增 XPC 方法，也不改变现有 XPC v4。当前实现为 `CoreController` 与 `UnixControllerTransport`；运行会话协调器尚待接入，界面连接按钮仍不据此启用。

## 身份与生命周期

- 生产入口只接受服务所有的私有会话目录和 `ManagedCoreJob`。目录末段必须匹配该 job 的会话 UUID；调用者需持有会话锁，串行处理写操作、停止和恢复。
- 只连接会话目录下固定的 `c.sock`，不接受客户端提供的 URL、路径、HTTP 方法、请求头或请求体。父目录要求 0700 类权限且无 allow ACL；重新打开路径并比较 inode/device，拒绝替换后的目录。
- 用 `fstatat(..., AT_SYMLINK_NOFOLLOW)` 检查 socket 类型与所有者，拒绝符号链接和普通文件。固定核心会把 socket 设置为 0666，访问隔离依赖私有父目录。
- 每次连接从当前 launchd job 查询 PID，再用 `getpeereid` 和 `LOCAL_PEERPID` 核对实际对端 UID/PID；连接后、响应完成后再次确认当前 job。这里的 PID 只用于核对身份，从不作为历史进程的信号目标。
- 每次请求独立持有 socket，设置非阻塞、close-on-exec 与 `SO_NOSIGPIPE`，任何退出路径关闭描述符。失败不会删除会话记录、停止 job 或修改 DNS。

## 受限操作

| Swift 操作 | 固定核心接口 | 返回与约束 |
| --- | --- | --- |
| `waitUntilReady` / `version` | GET `/version` | 版本必须等于从资源清单生成的固定版本；仅 socket 尚未出现或连接被拒绝时重试；就绪不代表 TUN、DNS 或外网已验收 |
| `mode` | GET `/configs` | 仅返回 rule/global/direct；其他配置字段不外传 |
| `setMode` | PATCH `/configs` | 请求体只有 mode，确认 204 后重新读取模式；不允许更新监听、TUN、路径等系统配置 |
| `proxies` | GET `/proxies` | 仅解码名称、类型、成员、当前选择；最多 1024 项，名称不超过 128 UTF-8 字节且无控制字符 |
| `select` | GET / PUT / GET `/proxies/{group}` | 先验证分组类型与成员，再提交 name 并回读；允许 Selector/URLTest/Fallback；未知成员不产生写请求 |
| `measureDelay` | GET `/proxies/{name}`，GET `/proxies/{name}/delay` | 先确认节点；测速地址固定为 `http://www.gstatic.com/generate_204`，核心 timeout 为 5000 ms；503 返回不可用，504 返回测速超时，成功延迟限制为 1～65535 ms |
| `trafficTotals` | GET `/connections` | 只返回 uploadTotal/downloadTotal 无符号计数，不返回连接地址、进程和链路明细 |
| `trafficSample` | GET `/traffic` | 读取一行流量速率与累计计数后关闭；单行最多 4096 字节，读取本身不留下后台任务 |

名称按 UTF-8 字节进行 URL 编码；中文、空格、斜杠、百分号及问号均由真实核心探针验证。上游 HTTP 接口与数据格式以 [v1.19.31 proxies.go](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/route/proxies.go)、[configs.go](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/route/configs.go)、[server.go](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/route/server.go) 为依据，升级核心需重新验证兼容性。

## 传输与错误

使用 HTTP/1.0、`Connection: close` 与 identity 编码，普通 JSON 响应读取至 EOF。响应头上限 16 KiB、普通正文上限 1 MiB；拒绝重复头、折叠头、压缩/分块编码、非法状态行、截断或多余正文。`/traffic` 的成功响应按换行分隔读取第一条 JSON，不等待持续流结束；未完成一行即断开视为错误。

普通请求的 socket 期限为 3 秒，测速为 7 秒；就绪等待默认 12 秒、可设上限 30 秒。launchd 状态查询另受其命令期限约束，因此这些 socket 期限不是整个复合操作的总耗时保证。返回错误只包含固定说明和 HTTP 状态码，不透出核心错误正文、解码上下文或凭据。

写入超时、连接中断或回读不一致时，结果为未确认，不能推断核心没有执行写入。后续会话协调器必须重新读取权威状态，再决定展示或重试；未确认结果不得提前改变界面模式、节点勾选或保存为已经生效。

## 验证边界

`CoreControllerTests` 使用实际 Unix socket 验证身份、路径替换、权限、HTTP 分片/截断/超限、期限、写后回读、固定测速目标与流量行读取。普通用户集成入口：

```sh
bash scripts/macos/swift.sh build
python3 scripts/macos/probe-controller.py \
  --core build/macos-probes/mihomo-darwin-arm64 \
  --native-client build/macos/out/Products/Debug/freev6-probe
```

集成探针关闭 TUN、DNS、代理端口和所有 IP listener，仅用 DIRECT/REJECT 测试分组；测速只对 REJECT 执行，不访问测速站点。探针还核对 100 字节 socket 路径、无 IP socket、进程正常退出与回收，输出 `build/controller-probes/<UUID>/result.json`。可选路径和 PID 的普通用户探针入口只在 Debug 存在。

此轮不证明 root 会话授权、跨用户隔离、真实代理流量、运行中配置持久化、连续流量订阅或日志订阅已经完成；这些仍需运行会话协议和后续实测。
