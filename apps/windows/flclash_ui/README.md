# FreeV6 · FlClash Windows 客户端

用户已确认完整 FlClash Windows UI。此工程通过 path 依赖复用 FreeV6 现有 LiveModel、HelperApi、ControllerApi 和偏好逻辑，通过同一份 C++ HostBridge 接回 Windows 系统功能；不改写 Go 网络业务。

本轮先离线验证，不安装、不启动真实联网。`fixture_main.dart` 运行真实后端代码，所有网络和宿主调用由内存夹具回答；`live_main.dart` 仅编译。原始 UI 演示入口仍保留。

构建、功能映射、入口和验证限制见 [DEVELOPMENT.md](DEVELOPMENT.md)。来源与本地补丁见 [vendor/](vendor/)；本衍生应用包含 GPLv3 组件，根 MIT 许可不替代第三方许可。便携离线验收产物随附匹配源码、许可及校验文件。
