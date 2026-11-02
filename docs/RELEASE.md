# 3duos v0.1.2

- 调整 IPA 打包：使用标准 ZIP，直接在本地文件头记录 CRC 和大小，去掉 macOS 附加元数据。
- 发布前检查 ZIP 完整性、Payload 主应用、Info.plist、iOS 可执行文件和本地文件头。
- 沿用 v0.1.1 的四套固定比例机身素材与游戏核心。

## 安装

在本页 Assets 下载 `3duos-0.1.2-unsigned.ipa`，保存到「文件」，再导入签名工具。安装包需使用自己的 Apple ID 或证书签名。

对应 `.sha256` 文件可核对下载完整性。不要将 Release 网页另存为 `.ipa`。

最低系统为 iOS/iPadOS 26；Duo 折叠交互使用 iOS 27.1+。游戏文件自行导入，支持解密的 `.3ds`、`.cci`、`.cxi`。
