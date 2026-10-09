# PVE 首次启动账号配置

首次启动前，在 PVE 虚拟机中：

1. 将操作系统类型设为 Windows，添加 Cloud-Init 配置盘。
2. 在 Cloud-Init 页面将用户设为 `Administrator`，填写登录密码并生成配置盘。
3. 启动虚拟机，通过控制台或 RDP 使用该密码登录。
4. 在虚拟机选项中启用 QEMU Guest Agent。

Cloudbase-Init 从 ConfigDrive 读取密码。项目的账号插件在密码注入后启用内置 Administrator、清除首次改密标志，并在登录验证成功后禁用额外的 Admin 账号。

可通过 `resources/managed-admin-policy.json` 调整额外 Admin 账号的处理策略。
