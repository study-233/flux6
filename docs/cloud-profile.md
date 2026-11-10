# 仓库托管的公开备用配置

当前发行仓库是 `study-233/free-v6`，备用配置暂时关闭：`main` 分支根目录的 `notice.json` 中 `cloudProfile` 为 `false`。普通 WARP 模式继续直接连接 Cloudflare。

## 来源与访问路径

客户端根据校园登录页的主机名选择本仓库 `main` 分支 `profiles/` 下的 YAML：

```text
https://raw.githubusercontent.com/study-233/free-v6/main/profiles/<slug>.yaml
```

`slug` 的计算保留既有规则：归一化门户主机名，然后取 `sha256("freev6:campus:v1:" + host)` 的十六进制文本第 7 至 22 位（零基，16 个字符）。例如文档地址 `192.0.2.10` 对应 `68eb7f9411d22cfe.yaml`。

此处不再请求原作者域名或私有 Worker。GitHub 文件是公开资源，没有校园源 IP 门禁；文件名摘要仅用于选择配置，不能隐藏节点或保护凭据。只发布你明确允许所有人读取和使用的节点。

## 发布步骤

1. 在 `profiles/` 中创建对应 `<slug>.yaml`，内容只保留有效的 Clash/mihomo `proxies`。结构参考 [example.yaml](../profiles/example.yaml)，其中示例地址不可用，不能作为真实节点发布。
2. 验证节点可连接、适合公开，然后把该文件提交到本仓库的 `main` 分支。
3. 确认原始文件可匿名下载且 YAML 有效，再把 `notice.json` 的 `cloudProfile` 改为 `true`。
4. 客户端刷新公告、填写校园门户地址、获取备用配置。以后改节点只需更新同一路径的文件。
5. 需要停用时将 `cloudProfile` 改回 `false`；它会阻止新的获取和启动，不会立即终止已经运行的核心。

没有真实节点时，保持开关关闭；本仓库目前仅提供示例，不会伪装成可用服务。

## 本机处理

- 只导入 `proxies`；TUN、DNS、端口、控制器与规则继续由客户端生成。
- 备用配置直接使用下发节点，不叠加 WARP，与链式代理互斥。
- 下载或验证失败保留已有快照，不自动降级到另一种出口。
- 自定义订阅或本地 YAML 导入仍可用，但同样受本发行仓库的备用配置开关控制。
- Windows 的缓存为 `config/cloud-profile-study-233-free-v6.yaml`。旧的 `cloud-profile.yaml` 不再读取。
- macOS 的备用配置密文绑定当前发行方。旧密文保留但不可复用，需要清除或重新导入；WARP 凭据和链式配置不受影响。
- 两个平台的公告缓存也按发行方隔离，旧公告无法开放新的备用配置。

## 相关实现

- `internal/publisher/publisher.go`：仓库、分支与缓存命名。
- `internal/mihomo/endpoint.go`：门户归一化与公开文件路径。
- `internal/notice/`：公告获取与备用配置开关。
- `cmd/freev6-helper/cloudconfig.go`：Windows 获取、保存与清除。
- `internal/worker/cloud.go`：macOS 获取、加密保存及配置交接。

## 上游修复同步（2026-11-10）

备用配置获取使用独立 HTTP/1.1 直连客户端，暂时性超时、连接重置或响应读取中断最多重试一次；调用方取消会停止重试。Windows 的失败详情写入 `state/cloud-config.log`，Mac 保持既有脱敏日志策略，界面不暴露完整入口。

Windows 与 Mac 的备用配置均在 `MATCH` 后追加 `NETWORK,UDP,REJECT`：所选节点不支持 UDP 时拒绝该流量，避免 QUIC 跳过代理后意外直连；支持 UDP 的节点仍正常转发。普通 WARP 模式保持原有规则。
