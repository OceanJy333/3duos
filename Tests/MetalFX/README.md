# MetalFX Spatial 实验

在支持 Metal 4 MetalFX 的 macOS 26 或更新系统上，仓库根目录运行：

```sh
xcrun swiftc Core/Graphics/MetalFXSpatial.swift Tests/MetalFX/main.swift -o /tmp/3duos-metalfx-check
MTL_DEBUG_LAYER=1 /tmp/3duos-metalfx-check
```

测试生成 64×64 RGBA 合成图，用 Metal 4 Spatial Scaler 放大至 128×128，等待 GPU 完成并读回四个色块；不支持的设备打印 SKIP。回读使用传统 Metal blit，仅用于验证。

核心接口的输入采用 perceptual 色彩模式。调用方提供符合 scaler 输入 usage 的二维纹理和正在录制的 Metal 4 命令缓冲区，需使输入和输出驻留，管理提交与同步，并在 GPU 完成前保留所需对象。每个实例持有固定尺寸和纹理，调用方应串行使用。接口需要 iOS 26 / macOS 26；当前未接入展示器或游戏画面。

仅检查 iOS 目标的编译类型：

```sh
xcrun swiftc -typecheck -target arm64-apple-ios26.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" Core/Graphics/MetalFXSpatial.swift Tests/MetalFX/main.swift
```
