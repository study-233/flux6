# Mac 客户端的数据与发布说明

**本机存储。** FreeV6 将 WARP 凭据保存在当前用户的 macOS 钥匙串。链式代理和备用配置的敏感字段使用钥匙串里的独立密钥加密。设置与流量统计保存在 `~/Library/Application Support/dev.freev6.desktop`，下载缓存和日志分别位于 `~/Library/Caches/dev.freev6.desktop` 和 `~/Library/Logs/dev.freev6.desktop`。

**后台服务。** 界面通过私有管道与业务进程通信，通过 XPC 连接管理员安装的网络服务。服务在 `/Library/Application Support/dev.freev6.desktop` 管理核心及会话恢复记录。断开连接后，服务负责恢复本次会话的 DNS。可以在设置中卸载网络服务，并在 WARP 页单独删除本机凭据。

**启动与网络请求。** 同意协议后，应用会读取维护者的公告。选择自动连接后，应用会在启动时尝试读取现有凭据并连接。钥匙串需要授权时，本次尝试会停止。普通模式连接前会向 `api-ipv6.ip.sb` 查询本机对外 IPv6 地址，用于判断校园网范围。开启登录启动会在当前用户的 `~/Library/LaunchAgents` 添加 FreeV6 登录项，可在“设置 → 通用”中关闭。

**发布来源。** 原项目仓库为 `evansrrr/free-v6`。这个 Mac 客户端的发行仓库为 `study-233/free-v6`。配置了正式通道的版本会在你检查更新时向 GitHub 请求对应架构的签名清单与安装包。

下文保留上游隐私政策全文。其中关于 `state/warp.json`、安装目录、回环 HTTP 接口和卸载器复选框的示例适用于 Windows 客户端。Mac 的存储、进程通信和卸载入口见上面的说明。

---
