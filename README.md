<div align="center">
<img alt="logo" height="100" width="100" src="src-tauri/icons/128x128.png" />
<h2> FreeV6 </h2>
<p> 教育网通用 IPv6 免流客户端 </p>

[下载](https://github.com/study-233/free-v6/releases) | [使用说明](#简要说明) | [公告维护](docs/notice.md) | [备用配置](docs/cloud-profile.md)

<br />

<a href="https://github.com/study-233/free-v6/stargazers">
<img alt="Stargazers" src="https://img.shields.io/github/stars/study-233/free-v6?style=for-the-badge&logo=github&color=f4dbd6&logoColor=D9E0EE&labelColor=302D41"></a>
<a href="https://github.com/study-233/free-v6/releases/latest">
<img alt="Releases" src="https://img.shields.io/github/release/study-233/free-v6.svg?style=for-the-badge&logo=semantic-release&color=f5bde6&logoColor=D9E0EE&labelColor=302D41"/></a>
<a href="https://github.com/study-233/free-v6/blob/main/LICENSE">
<img alt="License" src="https://img.shields.io/github/license/study-233/free-v6?style=for-the-badge&logo=conventionalcommits&color=ee99a0&logoColor=D9E0EE&labelColor=302D41"></a>
<a href="https://github.com/study-233/free-v6/issues">
<img alt="Issues" src="https://img.shields.io/github/issues/study-233/free-v6?style=for-the-badge&color=a6da95"></a>
</div>

<br />

## 简要说明

本发行版由 `study-233` 维护。公告、备用配置和更新入口均由 [本仓库](https://github.com/study-233/free-v6) 管理；原始版权与第三方声明继续保留。

**备用节点目前关闭。** 普通 WARP 注册和连接继续直接使用 Cloudflare；未来公开节点放在 [profiles](profiles/) 中。

| 平台 | 状态 | 开发入口 |
| --- | --- | --- |
| Windows 11 x64 | 桌面客户端 | [Tauri 构建说明](src-tauri/README.md) |
| macOS 14+，Apple Silicon | 本地预览版；最低系统和真实校园网络仍待实机验收 | [Mac 构建与安装](macos/README.md) |

以下使用说明针对 Windows。macOS 预览版的安装步骤和已验证范围见上表。

首次运行需要下载核心（~21MB），点击“启动免流”并按照提示点击“下载”，程序会自动完成下载安装。再次点击“启动免流”即可

启动免流后可以在“接入点”页进行延迟测试，更换延迟较低的接入点

设置中“绕过校园网/白名单”可以添加排除免流的网段和域名，例如校园网登录页所在的网段 `202.204.0.0/16`，添加后即可在免流时访问该页面

*退出软件或开关机时会尽量恢复网络状态，但仍建议手动关闭免流，避免下次开机后校园网认证异常。*

bug、问题和建议欢迎提 [issue](https://github.com/study-233/free-v6/issues)，再点点 **star** 喵

## 项目结构

- [web](web/) 是 Windows 界面，[src-tauri](src-tauri/) 负责窗口、托盘和安装包。
- [macos](macos/) 包含 Flutter 界面、Swift 宿主、网络服务及测试；[scripts/macos](scripts/macos/) 提供构建和验收命令。
- [cmd](cmd/) 是 Go 程序入口，[internal](internal/) 是业务与网络实现，[shared](shared/) 保存跨语言协议及测试样本。

## 免责声明

本软件仅供学习和研究使用，请勿用于任何非法用途。使用本软件产生的一切后果由用户自行承担。

- 开发者不对本软件适用性、稳定性作任何明示或暗示的保证，亦不对任何直接、间接、特殊、偶然或后果性损害承担责任
- 部分功能依赖第三方 API 与服务，使用者须自行确保其使用符合相关法律法规及服务协议
- 用户应在遵守校园网及相关网络工具使用条款和规定的前提下使用本软件，开发者不对用户违规使用的行为及其后果负责
- 因使用本软件而导致的账号被限制、设备被隔离或其他损失，开发者不承担任何责任

完整条款见 [用户协议与免责声明](docs/agreement.md) 与 [隐私政策](docs/privacy.md)。使用本软件即表示你已充分理解并同意上述全部条款。

## 许可证

本项目采用 [MIT](LICENSE) 许可，第三方组件见 [THIRD-PARTY.txt](THIRD-PARTY.txt)。[Windows 随包许可](src-tauri/LICENSES/) 安装在程序的 `LICENSES/` 目录。

## 发布维护

- 公告：修改 `main` 分支的 [notice.json](notice.json)，参见 [公告发布指南](docs/notice.md)。
- 备用节点：当前关闭，未来按 [公开配置说明](docs/cloud-profile.md) 发布；仓库不包含原作者的节点。
- Windows 更新：在本仓库推送 `v*` 标签，由 Release 工作流生成草稿、安装包和 `version.json`；核验后发布。
- macOS 更新：使用本仓库 `macos-updates` 分支的签名清单，发布工具与签名步骤见 [Mac 开发说明](macos/DEVELOPMENT.md)。未配置签名通道的构建不会自动获得更新能力。

基于原项目作者 `evansrrr` 的 FreeV6；完整版权声明见 [LICENSE](LICENSE)。
