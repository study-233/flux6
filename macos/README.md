# FreeV6 原生 Mac 客户端

当前处于 P0 技术验证阶段。工程包含 SwiftUI/AppKit 应用雏形、仅支持握手的网络服务和系统探针；界面尚未接入网络服务，不会启用代理或修改 DNS。完整目标及进度见仓库的 macOS 支持计划与开发记录。

## 构建

需要完整 Xcode 和 Go 1.25+。脚本通过 DEVELOPER_DIR 选择 Xcode，不更改系统的 xcode-select。P0 使用 Swift Package 组织可独立测试的模块；后续添加正式 App、daemon 与安装工具的 Xcode targets。

```sh
bash scripts/macos/swift.sh build
bash scripts/macos/swift.sh test
bash scripts/macos/build-app.sh
```

开发应用位于 `dist/macos/FreeV6.app`，使用 ad-hoc 签名。构建缓存位于 `build/`，不会写入应用 bundle。主窗口、菜单、菜单栏状态入口和设置均为原生组件。

## 系统探针

```sh
probe_dir="$(bash scripts/macos/swift.sh build --show-bin-path)"
"$probe_dir/freev6-probe" identity
"$probe_dir/freev6-probe" dns
"$probe_dir/freev6-probe" xpc
"$probe_dir/freev6-probe" xpc-reject
"$probe_dir/freev6-probe" keychain
```

DNS 探针只读。XPC 探针使用同一用户下的匿名 listener，分别验证允许的 CDHash 和错误 CDHash；必须先确认可信连接成功，才能将拒绝测试解释为身份校验有效。受限沙箱可能禁止 Mach IPC，需在正常用户环境运行。此探针不证明 root daemon 的安装、重启和升级已通过。

Keychain 探针只创建、读取并删除一个随机标识的 `dev.freev6.probe` 测试项，不读取已有凭据。当前仅验证单次读写；升级后的访问行为单独验收。

## 独立服务验证

```sh
python3 scripts/macos/probe-service.py
```

在正常登录用户环境运行，不能以 root 运行。脚本构建 Debug 服务和探针，在 `build/service-probes/<UUID>` 内复制并启用 Hardened Runtime，然后注册一个随机名称的用户级 launchd job。验证双向 CDHash、UID 绑定、重启、客户端摘要更换后的重新登记与旧摘要撤销，最后移除该 job。只有可信调用在拒绝测试前后均成功，才记录拒绝通过。结果保存在该目录的 `result.json`。

服务只读取权限受控的登记文件，通过固定 XPC 方法响应版本握手。Release 构建拒绝探针参数和普通用户启动。这里没有 root 安装、网络启停或生产服务升级；用户级重新登记实验不能替代管理员安装验收。

## 原生更新验证

```sh
python3 scripts/macos/probe-update.py --isolated-agent
python3 scripts/macos/probe-update.py --isolated-agent --invalid-signature
```

脚本核验 Sparkle 2.9.6 官方压缩包，使用临时 Ed25519 密钥、随机 bundle ID 和仅监听 `127.0.0.1` 的 appcast。测试只更新独立测试 App，并检查实际版本、重启 PID、主程序 Hardened Runtime 和 entitlement；结果位于 `build/update-probes/<UUID>/result.json`。临时私钥、监听服务器及本次测试的偏好和更新缓存会清理，构建产物与诊断保留。

主测试 App 仅链接系统框架；Sparkle 位于普通用户更新助手中，仅助手关闭 Library Validation。助手不在特权服务的客户端登记中。直接加载方案可用 `--profile hardened --load-only` 复现当前系统的 Team ID 拒绝，预期退出失败；`--profile adhoc` 只用于对照实验，不是主程序的发布配置。

`macos/Probes` 中的 Objective-C 宿主和自动应答 driver 是测试夹具，不随产品打包。实际产品将以 Swift 实现更新协调与原生用户确认界面。实验未覆盖下载 quarantine、macOS 13、Intel 或网络服务事务，完整发布验收仍需逐项完成。

## 核心与配置探针

```sh
go run ./cmd/macos-probe
python3 scripts/macos/probe-runtime.py --check-config build/macos-probes/config/offline-config.json
```

核心资产与摘要锁定在 `internal/mihomo/runtime-assets.json`，来源是对应上游 release。探针校验压缩包摘要、限制解压体积，仅执行版本与配置检查。

配置探针生成合成的 P-256 凭据，不向 Cloudflare 注册，也无法建立真实 WARP 会话。`full-config.json` 保留完整业务配置；`offline-config.json` 移除依赖远端 GeoSite/规则集的配置，用于隔离验证 JSON 和 MASQUE 解析。离线检查成功不能替代完整规则、DNS、TUN 与实际出口验证。
