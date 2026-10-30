# MetalFX 管线检查

在支持 MetalFX Frame Interpolation 的 macOS 26 或更新系统上，仓库根目录运行（参数是放大倍数 1–3，默认 2）：

```sh
xcrun swiftc Core/Graphics/MetalFXScreenPipeline.swift Tests/MetalFX/main.swift -o /tmp/3duos-metalfx-check
MTL_DEBUG_LAYER=1 /tmp/3duos-metalfx-check 3
```

测试在 CPU 上生成 400×240 的平移场景（棋盘格背景加移动圆盘），把 16 帧依次送入 Spatial、Temporal、Temporal + Frame Interpolation，并与原生高分辨率画面比较 PSNR。插帧输出还与中间时刻的真值比较，要求优于“直接显示当前帧”和“前后帧淡入淡出”。最后用带 Halton 抖动的静止画面确认：`jitter` 填几何平移量（同号）时重建最好。设 `DUMP_DIR` 可把结果写成 PPM。

MetalFX Temporal 的放大倍数每个维度最多 3 倍。

仅检查 iOS 目标的编译类型：

```sh
xcrun swiftc -typecheck -target arm64-apple-ios26.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" Core/Graphics/MetalFXScreenPipeline.swift Tests/MetalFX/main.swift
```
