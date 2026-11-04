# FreeV6 原生 Mac 客户端

当前处于 P0 技术验证阶段。工程包含 SwiftUI/AppKit 应用雏形和系统探针；界面尚未接入网络服务，不会启用代理或修改 DNS。完整目标及进度见仓库的 macOS 支持计划与开发记录。

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

## 核心与配置探针

```sh
go run ./cmd/macos-probe
python3 scripts/macos/probe-runtime.py --check-config build/macos-probes/config/offline-config.json
```

核心资产与摘要锁定在 `internal/mihomo/runtime-assets.json`，来源是对应上游 release。探针校验压缩包摘要、限制解压体积，仅执行版本与配置检查。

配置探针生成合成的 P-256 凭据，不向 Cloudflare 注册，也无法建立真实 WARP 会话。`full-config.json` 保留完整业务配置；`offline-config.json` 移除依赖远端 GeoSite/规则集的配置，用于隔离验证 JSON 和 MASQUE 解析。离线检查成功不能替代完整规则、DNS、TUN 与实际出口验证。
