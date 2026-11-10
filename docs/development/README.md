# FreeV6 开发与仓库管理

## 平台与目录

本仓库使用单仓库管理，平台目录表达平台差异，共享代码只维护一份。`main` 是唯一长期开发主线。

| 目录 | 职责 | 当前状态 |
| --- | --- | --- |
| `apps/macos/` | Flutter 界面、Swift/AppKit 宿主、XPC 网络服务 | 继续开发 |
| `apps/android/` | 基于 FlClash 的 Flutter、Android VPN 服务、嵌套 Go 核心 | 继续开发 |
| `apps/windows/` | 现有 Web UI、Tauri 窗口与安装包装 | 保留功能；自定义 UI 重构另立任务 |
| `apps/ios/` | 平台说明、待确认事项 | 仅占位 |
| `apps/openwrt/` | 路由器平台说明、待确认事项 | 仅占位 |
| `cmd/`、`internal/`、`mobileapi/` | Go 程序、共享业务、移动端接口 | 共享维护 |
| `shared/` | 协议与跨语言测试夹具 | 共享维护 |
| `assets/branding/`、`third_party/` | 品牌资源、第三方许可与来源索引 | 共享维护 |
| `scripts/` | 各端构建、验证与维护脚本 | 从仓库根目录调用 |
| `build/`、`dist/` | 工具缓存和临时构建、分发产物 | 不进 Git |

业务复用以已有 Go 模块和协议为边界。UI、权限、服务生命周期、系统网络适配由各平台负责。暂不引入跨平台“大一统”框架，也不为 iOS/OpenWrt 添加空工程、依赖或 CI。

## 分支与提交

从最新 `main` 创建短期分支，例如 `feat/android-onboarding`、`fix/macos-reconnect`、`refactor/windows-ui`、`chore/repository-cleanup`。不使用 `codex/` 前缀，不维护长期 `mac`、`android` 等平台开发分支，不额外建立 `develop`。一个分支处理一个可审查目标；完成检查后合入主线并删除已合并的任务分支。

使用 Conventional Commits；目录迁移、删除旧内容和功能修改分开提交。多人或多个工作目录同时开发时，每个 worktree 使用独立任务分支，构建产物也留在对应工作目录。删除分支前确认没有未合并提交和活动 worktree。

`origin` 指向自己的发行仓库；`upstream` 保留原作者来源。上游同步使用 `chore/sync-upstream-日期` 临时分支，检查协议、业务、安全修复及许可证，按需合并或摘取。不要用上游版本覆盖本项目 UI。`macos-updates` 如果用于签名更新清单，是部署数据分支，不作为开发分支；本次不创建或修改远端分支。

## 版本与发布

运行 `python3 scripts/version.py` 查看各端版本。平台独立发布，不为凑齐相同版本号而同步升级。

| 平台 | 版本来源 | 后续标签规则 |
| --- | --- | --- |
| macOS | `apps/macos/Resources/Info.plist` 的版本与 build | `macos-v<版本>-b<build>` |
| Android | `apps/android/pubspec.yaml` 的 `version: 版本+build` | `android-v<版本>-b<build>` |
| Windows | `apps/windows/src-tauri/tauri.conf.json`；Cargo 版本须一致 | `windows-v<版本>` |

Windows Release 工作流兼容历史 `v*` 标签。Mac 和 Android CI 只做验证，不因标签自动上传发行版。本次目录整理不更改产品版本、不推送、不发布。Mac Flutter 子工程的 pubspec 版本不是 Mac 发行版本来源。

Android 构建读取版本源，输出到 `dist/android/<版本>-b<build>/`，包名包含版本及 build。源码包和 APK 分别生成校验文件。Mac 本地应用保持 `dist/macos/FreeV6.app`；DMG/更新包由对应打包脚本生成。已发布版本的产物不可覆盖，新发行应先提升版本或 build。旧本地产物放 `dist/archive/<平台>/`，Git 只保存源码、锁文件和必要的验收结论。

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

`.github/workflows/ci.yml` 检查目录、文档链接、组件来源、版本、清理保护、Windows Web、Linux/Windows Go 以及 Windows Rust。`clients.yml` 增加 Android Go/Flutter/Kotlin/APK 和 Mac Swift/Flutter/App 构建。Android CI 使用测试签名，不读取本机私钥、不作为可覆盖安装的正式发行包。Mac CI 使用 ad-hoc 签名。

Mac job 默认选择 `macos-latest` 并显式检查 arm64 与 Xcode 27+；如果托管镜像不满足，配置仓库变量 `FREEV6_MACOS_RUNNER` 指向符合要求的 runner 标签，不能把跳过或失败视为通过。工具版本固定；升级时同步本地说明、构建入口和 CI。

本地整理完成不表示远端 Actions 已运行。Windows NSIS 实机安装、Mac 服务安装与升级、macOS 14、Android 真机 VPN、校园网络出口等仍需对应环境验收。当前检查不启动实际网络代理、不替换正在运行的应用。阶段结果见 [整理记录](repository-maintenance.md)。
