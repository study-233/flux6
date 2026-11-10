# macOS 运行会话记录 v3

`network-session.json` 位于服务数据目录，权限为 0600。服务在准备工作区之前取得与安装程序共用的 `network.lock`，持有到 DNS 恢复、核心退出、任务移除和文件清理完成。v1 用于准备文件，v2 用于配置检查，v3 才允许正常启动核心。

v3 使用 `phase=network` 和 `run` 字段，保留 UID、会话 UUID、配置摘要、策略和业务版本。每次阶段变更递增 `revision`。任务标签由会话 UUID 派生。记录内的组 ID 只用来判断旧服务是否仍存活，停止核心始终通过 launchd 任务。规则缓存文件名来自已校验的配置，只允许其中列出的 `ruleNN.list`。

| 阶段 | 此时允许的副作用 | 中断后的处理 |
| --- | --- | --- |
| capturingDNS | 保存物理主服务的 DNS 基线 | 基线可能尚未生成，确认对应核心任务不存在后清理 |
| registering | 注册 UUID 核心任务 | DNS 基线已就绪，任务可存在或尚未注册，已注册任务应处于停止状态 |
| starting | 启动该任务并等待 controller | 同一次系统启动中必须找到该任务。核心可能已经退出，或已运行且尚未记录 utun |
| applyingDNS | 已确认核心持有的 utun，开始切换 DNS | 从 DNS 子事务恢复，保留其他应用或用户的外部编辑 |
| active | 核心经 controller 确认、系统解析成功且出口检查通过 | 按所有者、UUID 及 revision 受理停止。服务重启后先恢复旧会话 |
| restoringDNS | 已记录停止意图，撤回 DNS 设置 | DNS 恢复失败时保留核心与记录。成功后才能继续回收 |
| stopping | 已恢复 DNS，允许向运行任务发出终止请求 | 查询 launchd 并重试，确认核心退出及记录的 utun 已释放 |
| exited | 已确认退出，或任务已经明确无需启动 | 移除已停止的任务。删除已完成但回执丢失时允许继续 |
| removed | 任务已移除 | 再次确认任务不存在，校验全部待删除条目后清理私有文件，最后删除主记录 |

生产就绪检查通过内核的进程描述符信息读取目标 PID 持有的 utun 控制套接字，记录接口名和索引。系统 Resolver 和会话专属查询验证见 DNS 事务。出口检查使用固定 HTTPS 204 请求，禁用代理和重定向，再查询实际对端地址的路由。退出时等待原接口的名称/索引组合释放。XNU 中 utun 的命名与 socket unit 之间的关系可在[utun 实现](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if_utun.c)和[内核控制套接字信息](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_control.c)中核对。

同一次系统启动中任务意外丢失时，仍先恢复 DNS，并保留记录与配置供后续处理。跨系统重启后旧 job 应已消失，仍须协调磁盘 DNS 记录。授权归属错误、未知文件、损坏的日志或新系统启动中出现同标签任务均中止清理。

普通用户探针通过真实 launchd 宿主与固定核心验证启停、强退重入和文件清理。系统 DNS 改用隔离配置，接口与出口在探针中模拟。root 服务、系统路由与出口必须在授权真机上另行验收。
