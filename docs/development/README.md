# Flux6 开发与仓库管理

## 平台与目录

本仓库使用单仓库管理，平台目录表达平台差异，共享代码只维护一份。`main` 是唯一长期开发主线。

| 目录 | 职责 | 当前状态 |
| --- | --- | --- |
| `apps/macos/` | Flutter 界面、Swift/AppKit 宿主、XPC 网络服务 | 继续开发 |
| `apps/android/` | 基于 FlClash 的 Flutter、Android VPN 服务、嵌套 Go 核心 | 继续开发 |
| `apps/windows/` | 当前 Web/Tauri 与独立 Flutter 迁移工程 | [Flutter 重构实施中](windows-flutter-refactor.md)，保留 Go helper；原生验证随后在 Windows 执行 |
| `apps/ios/` | 平台说明、待确认事项 | 仅占位 |
| `apps/openwrt/` | 路由器平台说明、待确认事项 | 仅占位 |
| `cmd/`、`internal/`、`mobileapi/` | Go 程序、共享业务、移动端接口 | 共享维护 |
| `shared/` | 协议与跨语言测试夹具 | 共享维护 |
| `assets/branding/`、`third_party/` | 品牌资源、第三方许可与来源索引 | 共享维护 |
| `site/`、`scripts/site/` | Flux6 官网源码及无依赖静态构建/预览工具 | [本地预览说明](../../site/README.md) |
| `scripts/` | 各端构建、验证与维护脚本 | 从仓库根目录调用 |
| `build/`、`dist/` | 工具缓存和临时构建、分发产物 | 不进 Git |

业务复用以已有 Go 模块和协议为边界。UI、权限、服务生命周期、系统网络适配由各平台负责。暂不引入跨平台“大一统”框架，也不为 iOS/OpenWrt 添加空工程、依赖或 CI。

## 分支与提交

从最新 `main` 创建短期分支，例如 `feat/android-onboarding`、`fix/macos-reconnect`、`refactor/windows-ui`、`chore/repository-cleanup`。不使用 `codex/` 前缀，不维护长期 `mac`、`android` 等平台开发分支，不额外建立 `develop`。一个分支处理一个可审查目标；完成检查后合入主线并删除已合并的任务分支。

远端 `main` 禁止删除和强推，合并要求轻量 `checks` 检查通过并与主线同步。仓库规则禁止新建 `codex/` 分支，合并后自动删除任务分支。

使用 Conventional Commits；目录迁移、删除旧内容和功能修改分开提交。多人或多个工作目录同时开发时，每个 worktree 使用独立任务分支，构建产物也留在对应工作目录。删除分支前确认没有未合并提交和活动 worktree。

`origin` 指向自己的发行仓库；`upstream` 保留原作者来源。上游同步使用 `chore/sync-upstream-日期` 临时分支，检查协议、业务、安全修复及许可证，按需合并或摘取。不要用上游版本覆盖本项目 UI。`macos-updates` 如果用于签名更新清单，是部署数据分支，不作为开发分支；仅在启用对应部署功能时创建。

## 版本与发布

运行 `python3 scripts/version.py` 查看各端版本。每个软件版本只创建一个 `v<版本>` 标签和一个 Release，集中提供该版本的各平台附件；平台内部 build 继续独立递增。

macOS 与 Android 的首个公开正式版为 [0.1.0](../releases/first-public-release.md)。用户已确认安装验收和 Android 真机验证完成；本次 macOS 发行不进行 Apple 公证。用户已于 2026-11-10 明确授权发布。

| 平台 | 版本来源 | 后续标签规则 |
| --- | --- | --- |
| macOS | `apps/macos/Resources/Info.plist` 的版本与 build | `v<版本>` |
| Android | `apps/android/pubspec.yaml` 的 `version: 版本+build` | `v<版本>` |
| Windows | `apps/windows/src-tauri/tauri.conf.json`；Cargo 版本须一致 | `v<版本>` |

各平台均在本地构建和验收，推送标签不会自动打包或上传发行版。历史平台标签保留用于追溯，不再为同一版本创建多个平台 Release。仓库整理不更改产品版本，不自动触发产品发行。Mac Flutter 子工程的 pubspec 版本不是 Mac 发行版本来源。

Android 构建读取版本源，输出到 `dist/android/<版本>-b<build>/`，包名包含版本及 build。源码包和 APK 分别生成校验文件。Mac 本地应用保持 `dist/macos/Flux6.app`；DMG/更新包由对应打包脚本生成。已发布版本的产物不可覆盖，新发行应先提升版本或 build。旧本地产物确认不再用于回归或回滚后删除，不再默认长期堆放在 `dist/archive/`；保留的安装包必须配对保存对应源码和校验文件。Git 只保存源码、锁文件和必要的验收结论。

## 签名和缓存

Android 默认签名位于 macOS 的 `~/Library/Application Support/FreeV6/Development/android-signing/`；Linux 位于 `${XDG_DATA_HOME:-~/.local/share}/FreeV6/Development/android-signing/`。构建器复用原有身份；目录不完整或迁移冲突时停止，不自动轮换密钥。可用 `FREEV6_SIGNING_DIR` 指定其他仓库外目录，或通过 `FREEV6_KEYSTORE` 与对应口令环境变量指定现有签名。

Mac 本机签名保持 `~/Library/Application Support/dev.freev6.build-signing/`，正式证书可由 `FREEV6_CODESIGN_IDENTITY` 指定。本机签名不是 Apple 公证。两个平台的身份备份都在仓库外 `~/Library/Application Support/FreeV6/Development/backups/repo-baseline-20261110/`，不要随源码或产物分发。

缓存分级清理：

```bash
python3 scripts/maintenance/clean.py --help
python3 scripts/maintenance/clean.py --group temporary
python3 scripts/maintenance/clean.py --group compile
python3 scripts/maintenance/clean.py --group temporary --apply
```

默认只预览；`--apply` 才删除。工具检查允许清单、签名文件、符号链接和文件占用。`toolchains` 组需要后续重新下载 SDK，通常保留。清理前停止自己的构建任务，不使用无差别的 `git clean -fdx`，签名及用户运行配置不属于可删缓存。

## 日常检查

以下从仓库根目录运行。Go 范围显式列出，避免 `go test ./...` 扫进本机 `build/` 下的 SDK 示例。嵌套 Android Go 模块必须独立验证。

```bash
python3 scripts/maintenance/check-repository.py
python3 scripts/maintenance/test_maintenance.py
python3 scripts/check-icons.py
python3 scripts/check-publisher.py
node --experimental-vm-modules scripts/check-web-modules.mjs
go test -timeout=180s ./cmd/... ./internal/... ./mobileapi/...
go vet ./cmd/... ./internal/... ./mobileapi/...
```

Android 使用 Bash；现有工具缓存由 `scripts/android/env.sh` 发现，也支持 `FREEV6_FLUTTER_SDK`、`FREEV6_ANDROID_SDK`、`FREEV6_JAVA_HOME` 及 PATH 中的工具。固定版本和完整操作见 [Android 说明](../../apps/android/FREEV6.md)。

```bash
bash scripts/android/build-apk.sh
python3 scripts/android/package-source.py
```

Mac 必须使用 Apple Silicon、完整 Xcode 27+（包含 macOS SDK），最低运行目标仍是 macOS 14；固定 Flutter 版本为 3.47.6。详见 [Mac 构建说明](../../apps/macos/README.md) 和 [业务与服务验证](../../apps/macos/DEVELOPMENT.md)。

```bash
bash scripts/macos/swift.sh test
bash scripts/macos/build-app.sh
```

Windows 构建在 Windows 主机完成，详见 [Windows 入口](../../apps/windows/README.md)。

## CI 与验收边界

远端只保留 `.github/workflows/ci.yml` 的一个 Ubuntu `checks` 任务，5 分钟超时。同一分支的新提交取消过时运行；任务分支由 PR 触发，合入 `main` 后再做轻量检查。

| 检查 | 远端执行条件 |
| --- | --- |
| 目录、文档链接、版本、第三方来源、源码包输入跟踪 | 每次执行 |
| 7 项维护保护测试、图标、发布来源、Web 模块引用 | 每次执行 |
| 共享 Go test/vet | `cmd/`、`internal/`、`mobileapi/`、根 Go 依赖或 CI 配置变化；手动运行时也执行 |

只改文档、UI 或平台文件时不安装 Go 工具链、不跑 Go 编译；共享业务变更才增加 Go 验证。使用单一稳定的 `checks` 门禁，避免按路径跳过整个工作流使合并永远等待。

Mac Swift/Flutter/App、Android 嵌套 Go/Flutter/Kotlin/APK/源码包、Windows Go/Rust/NSIS 均在对应本地环境按改动范围执行。已删除远端客户端工作流和 Windows 标签自动打包工作流，不安装 Flutter、Xcode、Android SDK/NDK 或 Rust 工具链，不上传新的 CI 安装包。Android 本地完整命令见 [构建说明](../../apps/android/FREEV6.md)，Mac 见 [开发说明](../../apps/macos/DEVELOPMENT.md)，Windows 见 [本地验证与发布](../../apps/windows/README.md)。

远端 `checks` 通过仅表示轻量门禁通过；平台改动的 PR 应记录对应本地测试与构建结果。正式发布前仍要完成所涉及平台的打包、签名与安装验收。Actions 日志保留 30 天，已有 Android CI 附件按原 14 天周期到期；不再持续生成这些附件。未接入自有文档站前不保留 Vercel 发布 Hook。

完整跨平台远端验证曾在整理 PR 中通过，详见 [远端整理记录](remote-maintenance.md)，当前日常策略以本节为准。2026-11-10 用户确认 Mac/Android 安装验收及 Android 真机验证完成，记录见 [首发准备](../releases/first-public-release.md)；历史 CI 与隔离测试的覆盖范围不因该确认而改变。Windows 原生安装及其他未明确覆盖的系统、升级和网络场景仍按各平台验收记录管理。当前仓库检查不启动实际网络代理、不替换正在运行的应用。
