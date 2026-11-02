# 3duos v0.1.0

- 适配普通 iPhone、iPad 和窄窗口：完整显示机身和控件，避开安全区域。
- 横屏将上屏、下屏控制区并排；Duo 保留上下折叠布局。
- 上下游戏屏分别保持 5:3、4:3 原生比例。
- 游戏库操作改为两行，方便小屏点击；沿用白色 XL 机壳、彩色按键和 3 DUOS 图标。
- GitHub Actions 自动检查布局和 CPU、构建 Release IPA，并生成 SHA-256 校验文件。

## 安装

下载 `3duos-0.1.0-unsigned.ipa`。这是未签名安装包，需使用自己的 Apple ID 和签名工具（如 SideStore、AltStore 或 Sideloadly）签名安装。仓库与构建流程不保存个人开发者证书。

最低系统为 iOS/iPadOS 26；Duo 折叠交互使用 iOS 27.1+。MetalFX 功能需要设备支持相应接口。

游戏文件需自行导出、解密并在应用中 Import，支持 `.3ds`、`.cci`、`.cxi`。当前主要验证游戏为《塞尔达传说：时之笛 3D》。
