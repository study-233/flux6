# Windows 0.1.3 升级与功能验收

本轮以正式 0.1.3 的统一 Flutter 客户端为基线，候选版本为 0.1.4。只覆盖 Windows；共享 Android/macOS 源码不变。功能边界见[当前适配](../../apps/flux6/windows_client/README.md)。以前的 Tauri 迁移、卸载和回退结果保留在[维护记录](repository-maintenance.md)，不重复执行。

## 构建

准备 Flutter 3.47.6、Visual Studio C++ 桌面开发、Windows SDK、Go、Python 和 NSIS。在仓库根运行：

```powershell
$env:FREEV6_FLUTTER_SDK = 'C:\tools\flutter'
.\scripts\windows\build-flutter.ps1 -MakeNsis 'C:\Program Files (x86)\NSIS\makensis.exe'
```

默认组装完整 FlClash Windows 界面，输出 `dist/windows/0.1.4-unified/`。版本取自 `apps/windows/release.json`。构建不会启动真实核心、安装应用或发布；`-SkipChecks` 仅用于复用未失效的本轮检查结果。

仅发布安装版时传入 `-NoPortable`，跳过便携 ZIP；保留正式安装器、对应源码和更新清单。

## 保留的检查

1. 后端和统一工程的依赖锁、分析，以及受影响的 `flutter test`。新增回归集中在累计流量、旧响应丢弃、偏好保存和外部核心适配。
2. Windows helper 网络选项的验证/保存、生成配置字段保留、工作集读取及 `go vet`。共享 Go 未修改时不重复全平台矩阵。
3. Windows x64 live/preview 构建、隔离 preview 的宿主探针、代表性界面检查和对应源码打包验证。
4. 0.1.3 原格式偏好文件升级，核对主题、引导/公告记录、流量历史以及新增布局键保存。

不新增只重复界面常量的测试，不做 0.1.2 迁移、全新安装、卸载或降级矩阵。已通过且未受后续改动影响的结果复用。

## 真实环境验收

在用户指定的 Windows 验收环境执行一次 0.1.3 原目录升级。先停止连接、从托盘退出，备份原目录的 `config/`、`state/`、`runtime/`；备份包含凭据，不上传。覆盖安装后核对 WARP 注册、校园规则、链式配置、节点历史、主题与流量，不需要导出 WebView 偏好。

连接校园网后验证启动/停止、节点固定与恢复自动、延迟/下载测速与取消、链式代理、连接关闭、DNS 诊断、规则和日志。DNS/TUN 修改后重连验证；停止及退出后确认 DNS/热点恢复。连同托盘、F6 和自启动各做一次关键操作即可。

仓库检查使用合成数据和隔离预览，不会覆盖用户安装或改动系统网络。离线测试、文件兼容和原生构建通过不能代替本节；未执行项必须在交付中明确标注。
