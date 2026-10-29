# 3duos Lab

独立开发中的 3DS 模拟器。Git 仓库没有远端；应用只链接 Apple 系统框架。旧版 3duos 仅供运行效果对照，不参与本工程的编译或链接。

当前可导入解密的 NCCH/CXI 或 NCSD/CCI，读取标题、图标和程序段。自写的 ARM11 A32 解释器已经执行《时之笛 3D》的真实入口，但尚未进入游戏画面。应用内的 `Test screens` 运行自造 A32 程序，写入一列帧缓冲像素，再交给 Metal 显示；背景与文字由 UIKit 绘制。独立图形测试能把合成 PICA 命令和顶点送入固定 Metal 着色器画三角形，以及用 Metal 4 MetalFX Spatial 放大合成纹理；这些还未接入游戏帧。

游戏文件留在本机原路径，不放进仓库。当前验证结果和接手步骤见 [HANDOFF.md](HANDOFF.md)；数据流见 [ARCHITECTURE.md](ARCHITECTURE.md)。

需要 Xcode 27.2 和 xcodegen：

```sh
xcodegen generate
xcodebuild -project 3duos.xcodeproj -scheme 3duos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

App ID 为 `xyz.ocean33.3duos.lab`。应用依赖 Apple 系统框架，不包含第三方模拟器或渲染库。

独立核心测试的命令见 `Tests/Boot/README.md`、`Tests/Kernel/README.md`、`Tests/Graphics/README.md`、`Tests/MetalFX/README.md`；其余 CPU、Cartridge、GPU 测试可以分别和对应 `Core` 目录用 `swiftc` 编译。
