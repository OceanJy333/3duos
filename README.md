# 3duos

为 iPhone Duo 折叠屏写的 3DS 模拟器。内核从零自写，渲染直接走 Apple Metal（不经 Vulkan / MoltenVK），并把深度、运动矢量和抖动交给 MetalFX 做超分和插帧。合上时外屏显示 3DS 外盖，打开后上下两块屏对应 3DS 双屏。

A 3DS emulator for the foldable iPhone Duo, with a self-written core, native Metal rendering and MetalFX upscaling / frame interpolation fed with real depth and motion vectors.

## 现状

- 《塞尔达传说 时之笛 3D》可在 iPhone Duo 真机上稳定 30 fps 游玩；MetalFX Temporal 超分（内部 800×480 → 1207×724）加 2 倍插帧。
- 已运行过：iPhone Duo 真机、Duo 模拟器、Mac Catalyst。其他游戏尚未测试。
- 应用只链接 Apple 系统框架，不含第三方模拟器或渲染库。

## 不包含

仓库不提供任何游戏、系统固件或密钥。请只使用你自己合法导出的已解密游戏文件（NCCH/CXI 或 NCSD/CCI）。

## 构建

需要 Xcode 27.2 和 xcodegen：

```sh
xcodegen generate
xcodebuild -project 3duos.xcodeproj -scheme 3duos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

真机安装需在 `project.yml` 填自己的签名团队与 Bundle ID。结构见 [ARCHITECTURE.md](ARCHITECTURE.md)，开发记录见 [HANDOFF.md](HANDOFF.md)；独立测试见 `Tests/*/README.md`。

## 许可

MIT，见 [LICENSE](LICENSE)。Nintendo 3DS 与《塞尔达传说》是任天堂的商标，本项目与任天堂无关。
