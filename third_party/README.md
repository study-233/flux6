# 第三方材料

`licenses/` 保存 Mac、Windows 共享的随包许可。平台专属上游源码、许可证与补丁清单随对应平台保存：Android 的说明见 `apps/android/FREEV6.md`，Mac 的说明见 `apps/macos/flutter_ui/vendor/UPSTREAM.json`。Windows Flutter 的原始来源、Mac 移植基线及本地补丁分别保存在 `apps/windows/flutter_ui/vendor/UPSTREAM.json`、`MACOS-SOURCE.json` 和 `WINDOWS-PATCHES.json`。

公共品牌图标位于 `assets/branding/`，从原 Windows 资源目录迁移。原有许可和来源见根 `THIRD-PARTY.txt`。更新组件时同步维护来源、版本、补丁和对应源码包，不把上游派生代码改标为根项目的 MIT 许可。
