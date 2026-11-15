---
name: release
description: 撰写 Flux6 发行说明，准备或发布 GitHub Release。
---

# Flux6 发布

标题用 `Flux6 <版本>`。对照上一正式版，正文用 `- ` 列出用户可见变化，每条一句中文。仅在升级必须手动操作时补一句。省略附件列表、校验值和测试记录。

仅起草时交付文案。实际发布时依次完成以下三步。

1. 用 `python3 scripts/version.py` 核对版本与 build。同一版本共用一个 `v<版本>` 标签和一份 Release，标签指向已验收的源码提交。
2. 上传本次交付平台的安装包、对应源码和必要的更新清单。不上传或链接 `SHA256SUMS`、`*.sha256` 等校验文件。
3. 在草稿核对标签和附件，保留已发布文件。设为 Latest 前核对 Windows 清单。有 macOS 新包时，待更新 ZIP 可下载后部署签名清单。见[更新通道说明](../../../docs/releases/in-app-updates.md)。
