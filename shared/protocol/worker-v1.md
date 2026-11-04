# Mac 业务 worker 协议 v1

实现：`cmd/freev6-worker`、`internal/worker` 与 `macos/Sources/FreeV6Business`。

worker 是当前用户的子进程，输入输出使用 App 创建的匿名管道。它不监听 HTTP 端口，不接收 shell 命令，也不提供 root 网络控制。退出 App 或关闭 stdin 会取消未完成工作并退出 worker。正常用户数据目录持有独占文件锁，同一目录不允许两个 worker 同时写入；锁随进程退出释放。

## 帧与连接

每帧为 4 字节无符号大端长度，随后为对应字节数的 UTF-8 JSON。长度范围为 1～1,048,576 字节，不含长度头；禁止批处理数组。截断帧、零长度或超限长度关闭连接。stdout 仅输出协议；stderr 为诊断，Swift 客户端持续排空但不直接展示或持久化原文。

请求使用 JSON-RPC 2.0，`id` 必须是非空且不超过 64 字节的字符串；客户端为每次请求生成独立 UUID。方法名最多 128 字节，参数使用对象。无 `id` 的通知不产生回复，未知通知忽略。回复保留原 `id`，恰好包含 `result` 或 `error`。

首个业务调用之前完成握手：

```json
{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{"protocolVersion":1}}
```

握手结果包含 `protocolVersion`、`workerVersion`、`platform`、`architecture`、`capabilities`、`maxFrameBytes`、`maxInFlight`。版本不兼容时不得继续发送业务请求；重复握手拒绝。当前能力仅为 `settings.get`、`settings.patch`。WARP、订阅、下载和配置生成仍待迁移，不在能力列表中宣称可用。

最多同时处理 8 个请求，输出队列最多 16 个回复。Swift 客户端的消息与写入队列也有上限。worker 为每个业务请求设置 30 秒期限；当前 Swift 设置调用在 10 秒无响应时断开连接并回收 worker，重新载入时启动新进程。后续下载方法需要单独定义长任务期限及进度协议。

取消使用通知：

```json
{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":"request-1"}}
```

取消是尽力而为。设置在原子替换前检查取消；替换完成后不能把已写入的数据描述为撤销成功。客户端取消、超时或断线后，未确认的保存结果标为未知，重新载入确认；不能显示“已保存”。迟到回复不得覆盖新的界面状态。

## 设置

`settings.get` 接受空参数对象，返回：

```json
{"schemaVersion":1,"revision":0,"settings":{"mode":"rule","campusCidrs":["edu.cn"],"blacklist":[],"devMode":false}}
```

缺少设置文件时返回上述默认值；损坏文件或未知 schema 拒绝读取和覆盖。持久化文件位于显式 DataDir 下的 `proxy-preferences.json`，普通用户所有、权限 0600；以同目录临时文件、fsync、原子 rename 和目录 fsync 保存。首次保存后 revision 从 0 增为 1，每次成功保存递增。

`settings.patch` 接受：

```json
{"expectedRevision":0,"changes":{"mode":"global","devMode":true}}
```

未发送的设置保持原值，显式空数组清空列表，null、未知字段和错误类型拒绝。可编辑字段仅为 `mode`、`campusCidrs`、`blacklist`、`devMode`；列表最多各 2,048 项，每项最多 1,024 字节，持久化 JSON 总大小最多 256 KiB。域名、CIDR 和模式沿用共享 Go 校验；规范化后的完整快照作为保存结果返回。`expectedRevision` 与当前值不一致时返回冲突，客户端必须载入新值后重新编辑。

Mac 的 patch 契约与 Windows 历史 PUT 契约分开。Windows 继续保持原有基本字段替换、部分字段省略即保留的行为；平台登录项、热点开关和敏感配置来源不通过 Mac 的代理规则方法写入。

## 错误

| code | 含义 |
| --- | --- |
| -32700 | JSON 无法解析 |
| -32600 | 请求结构错误或重复握手 |
| -32601 | 未实现的方法 |
| -32602 | 参数或配置无效 |
| -32603 | 内部错误；不泄露底层诊断 |
| -32001 | 尚未握手 |
| -32002 | 协议版本不兼容 |
| -32003 | 请求 ID 正在执行或达到并发上限 |
| -32004 | 设置版本冲突 |
| -32005 | 配置读写失败，需要重新载入确认状态 |
| -32800 | 请求被取消或超时 |

## 验证

Go 测试覆盖 Windows 字段保留、原生 patch、原子保存和版本冲突、损坏配置保留、握手/方法/参数拒绝、并发、取消、父进程断开和帧限制。Swift 测试覆盖分片帧、截断及同一共享样本。设置样本位于 `shared/fixtures/worker-settings.json`，两端直接读取同一文件。

真实 Swift→Go 测试需要先构建 worker，再给 Swift 测试传入 `FREEV6_WORKER_TEST_BINARY`。它验证并发握手、保存/规范化、冲突拒绝、非法配置拒绝、worker 退出及重启后读取；不注册 WARP，不安装系统服务，不修改 DNS。
