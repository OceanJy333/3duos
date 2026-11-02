# 3duos v0.1.2

- 调整 IPA 打包：使用标准 ZIP，直接在本地文件头记录 CRC 和大小，去掉 macOS 附加元数据。
- 发布前检查 ZIP 完整性、Payload 主应用、Info.plist、iOS 可执行文件和本地文件头。
- 沿用 v0.1.1 的四套固定比例机身素材与游戏核心。

## 安装

全能签导入测试包：[3duos-0.1.2-resign.ipa](https://github.com/OceanJy333/3duos/releases/download/v0.1.2/3duos-0.1.2-resign.ipa)，9,287,455 字节（约 9.3 MB）。保留 Xcode 分发包的完整签名结构，使用零压缩 ZIP。请保存到「我的 iPhone」，在签名工具中导入后，使用自己的证书重新签名安装。本机已通过签名、ZIP 和 SSZipArchive 解压检查；全能签手机端导入仍待实测。

在本页 Assets 下载 `3duos-0.1.2-unsigned.ipa`，保存到「文件」，再导入签名工具。安装包需使用自己的 Apple ID 或证书签名。

对应 `.sha256` 文件可核对下载完整性。不要将 Release 网页另存为 `.ipa`。

最低系统为 iOS/iPadOS 26；Duo 折叠交互使用 iOS 27.1+。游戏文件自行导入，支持解密的 `.3ds`、`.cci`、`.cxi`。
