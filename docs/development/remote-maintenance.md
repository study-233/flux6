# 远端整理记录

执行日期：2026-11-10。范围为 `study-233/free-v6`；上游 `evansrrr/free-v6` 保留原状，本次不创建产品发行版。

## 基线与备份

远端原 `main` 为 `67b030d9bb14444a64023daee4f0ccd71b1c8675`，旧 `codex/own-publisher` 为 `53b8740574def5a433fe688c7088a755ab11cb08`；本地整理基线为 `8bfd84e`。

完整 Git bundle、分支引用与 16 份配置快照保存在仓库外用户 Library 的 `FreeV6/Development/backups/remote-cleanup-20261110T052229Z/`，已通过 `git bundle verify`。备份文件仅当前用户可读，配置快照不包含私钥或 Secret 值。

起始清单：2 个分支、0 个标签、0 个 Release、0 个未关闭 PR、3 条 Actions 记录、4 份缓存共 667181560 字节、0 个构建附件。仓库主页仍为上游网站，Issues 关闭，Wiki 开启，无分支保护。

## 主线整合与分支清理

[PR #1](https://github.com/study-233/free-v6/pull/1) 通过正常 merge commit 合入 `main`，合并提交为 `718383f9b25fc0a422738ee6e958018d57c94482`。两个原远端 tip 与本地整理基线均为新主线祖先，全部提交历史保留。冲突按新平台路径处理，保留较新的 Mac 隐私说明、线上公告及 `cloudProfile: false`。

确认旧 tip 未变化且已合并后，删除远端 `codex/own-publisher`。本次 `chore/remote-cleanup` 由合并自动清理；远端只保留 `main`，本地主线同步且任务分支已删除。iOS、OpenWrt 只保留目录说明，不建立长期平台分支。

## CI 与源码验收

合并候选 `91d61b784b35021d36e3731ffa2ca2fc1ec6ea90` 的 6 项检查全部通过：

| 工作流 | 验证结果 |
| --- | --- |
| [CI](https://github.com/study-233/free-v6/actions/runs/42764741507) | Linux/Windows Go test 与 vet、Windows Rust `cargo check`、Web、图标、发布来源及仓库维护检查通过。 |
| [Mac and Android](https://github.com/study-233/free-v6/actions/runs/42764741493) | Mac Swift/Flutter 测试及 App 构建通过；Android Go/Flutter、ARM64 Release APK、Kotlin 单元测试和对应源码包通过。 |

Mac CI 使用官方 `xcode-27` Apple Silicon 镜像。Swift 会话测试夹具改用用户目录内的独立短路径，避免托管 runner checkout 路径使 Unix socket 超长。产品安全检查保持不变。

Android CI 使用 SDK `platforms;android-37.0`、NDK `28.2.13676358`，显式设置 `ANDROID_NDK_HOME`，避免 runner 预设 NDK 覆盖项目版本。SDK 管理器使用 JDK 21，应用构建使用 JDK 17。开发分支由 PR 触发验证，`main` 推送再次验证，避免同一个开发提交重复触发两套构建。

从远端独立克隆的源码检查通过：目录、文档链接、版本与第三方来源、7 项维护保护测试、45 个图标、126 个 JavaScript 模块及发布来源均正常。临时克隆独立于已有工具缓存。

## 仓库配置与缓存

- 仓库描述改为当前多平台状态，清空上游主页链接，开启 Issues，关闭无内容的 Wiki。
- 开启合并后自动删除任务分支；移除未配置自有站点的 Vercel 文档 Hook 工作流，Windows Release 工作流保留。
- Actions 日志保留 30 天；Android CI 测试 APK 和对应源码附件保留 14 天。CI 使用测试签名，正式签名材料保留在仓库外。
- 删除 3 份过时的基线缓存，以及已合并任务分支/已关闭 PR 的 10 份专属缓存，共 13 份、6400374154 字节（约 5.96 GiB）。保留有效主线 Go 缓存和新主线构建生成的缓存。
- 原 3 条运行记录和本次失败诊断记录保留。远端没有旧 Release 或标签需要删除；本地历史标签保留。

## 主线保护与后续规则

`main-protection` 禁止删除和非快进强推，`no-codex-branches` 禁止创建 `codex/` 前缀分支；没有管理员绕过列表。合并前的必需检查固定为 GitHub Actions 提供的 `web`、`go (ubuntu-latest)`、`go (windows-latest)`、`rust`、`android`、`macos`，并要求分支与主线保持同步。启用必需检查以实际通过的上述检查为依据，最终报告提交同样执行完整主线 CI。

后续从 `main` 创建 `feat/`、`fix/`、`refactor/`、`chore/` 或 `release/` 短期分支；检查通过后合并、删除分支。不同平台由目录和独立版本管理，未来平台通过占位文档管理。

验收边界：Swift 有 9 项环境相关跳过；Windows 已完成 Windows runner 上的 Rust 编译检查，但 NSIS 安装、Mac 服务安装与升级、macOS 14 实机、手机 VPN 与真实校园网络仍需对应环境验收。Windows 自定义 UI、iOS、OpenWrt 未启动实现。
