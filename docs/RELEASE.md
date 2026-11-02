# 3duos v0.1.1

- 新增长屏 iPhone、16:9 iPhone、iPad 三张 AI 生成的全白掌机皮肤，沿用 Duo 原有皮肤与外盖。
- 每套皮肤固定屏幕、摇杆、ABXY 与底部按键坐标，整体等比显示，机身内部不动态重排。
- 普通 iPhone 与 iPad 固定竖屏，游戏画面保持原生 LCD 比例。
- GitHub Actions 检查素材坐标、常见尺寸及 CPU，构建 Release IPA，并生成 SHA-256 校验文件。

## 安装

下载 `3duos-0.1.1-unsigned.ipa`，使用自己的 Apple ID 和签名工具（SideStore、AltStore 或 Sideloadly）签名安装。

最低系统为 iOS/iPadOS 26；Duo 折叠交互使用 iOS 27.1+。MetalFX 功能需要设备支持相应接口。

本版完成固定皮肤坐标检查与编译；普通 iPhone、iPad 尚未做真机测试。

游戏文件自行导出、解密后在应用中 Import，支持 `.3ds`、`.cci`、`.cxi`。当前主要验证游戏为《塞尔达传说：时之笛 3D》。
