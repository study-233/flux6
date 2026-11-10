# 第三方材料

`licenses/` 保存 Mac、Windows 共享的随包许可。平台专属上游源码、许可证与补丁清单随对应平台保存：Android 的说明见 `apps/android/FREEV6.md`，Mac 的说明见 `apps/macos/flutter_ui/vendor/UPSTREAM.json`。Windows Flutter 的原始来源、Mac 移植基线及本地补丁分别保存在 `apps/windows/flutter_ui/vendor/UPSTREAM.json`、`MACOS-SOURCE.json` 和 `WINDOWS-PATCHES.json`。

AI 代理规范和根目录的五个技能借鉴 FlClash；固定提交、文件映射与本地适配见 [代理规范来源](../.agents/UPSTREAM.md)，GPL-3.0 许可原文保存在 [.agents/LICENSE](../.agents/LICENSE)。

公共品牌图标位于 `assets/branding/`，从原 Windows 资源目录迁移。原有许可和来源见根 `THIRD-PARTY.txt`。更新组件时同步维护来源、版本、补丁和对应源码包，不把上游派生代码改标为根项目的 MIT 许可。

`site/` 官网改编自 FlClash 网页，独立沿用 GPL-3.0；上游固定提交、原始文件 Git blob 与本地改动记录见 [网站来源清单](../site/UPSTREAM.json)，完整许可见 [site/LICENSE](../site/LICENSE)。网页不包含 FlClash 的产品截图，改用本仓库品牌及截图资源。
