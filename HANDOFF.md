# 3duos 自研模拟器交接

更新：2026-10-30（《时之笛 3D》在自研核心里已渲染出真实画面：标题、过场、战斗场景；PICA 软件渲染器、HID、DSP 通路已接上；MetalFX 的深度、运动矢量、抖动输入已由渲染器提供）。工程位于 `/Users/ocean/code/3duos`，是没有远端的独立 Git 仓库。用户明确要求模拟器也自己开发：允许下载或阅读其他仓库以研究行为，不 fork、不引入第三方模拟器运行库，也不复制其实现。本工程应用只链接 Apple 系统框架。旧工程 `/Users/ocean/code/folium-duo-3ds` 中可玩的 3duos 仅用于效果对照；它运行 Cytrus，与这里的自研核心没有链接关系。

## 当前结果

| 部分 | 已完成并验证 | 尚未完成 |
| --- | --- | --- |
| 游戏库 | 导入解密的 CXI/CCI/3DS，读取 NCSD/NCCH、ExeFS、SMDH 标题和图标。Mac Catalyst 已用本地《时之笛 3D》文件实际导入并显示繁体中文标题。 | 加密卡带解密、安装格式。 |
| 应用入口 | 白色 New 3DS XL 外观、HOME 风格游戏库、`Open` 启动自研内核（`App/GameRunner.swift` 后台分片运行），双屏显示游戏帧，按键、摇杆、触屏经 HID 服务送入游戏；`Test screens` 与 HOME 返回保留。iOS generic 与 Mac Catalyst 曾编译通过（本轮改动后需重编）。 | 应用内实际打开《时之笛》尚未实测；解释器约 2000 万条指令/秒，渲染器繁忙帧 20–30 ms，实时性未达标。 |
| CPU 与内核 | ARM11 ARMv6K A32 解释器（含 VFPv2、LDREX/STREX、SSAT/USAT、半字访存）；分页内存；线程调度与同步对象；约 60 个 SVC。线性堆基址 `0x14000000`（游戏的物理地址换算只认这个值）。CPU 测试 127 项断言通过。 | Thumb、完整 VFP 舍入/异常、MMU/异常。 |
| GPU 与显示 | GSP 共享内存、中断队列、命令队列、60 Hz VBlank；显示传输、纹理拷贝、内存填充；PICA 软件渲染器（顶点着色器解释器、裁剪、光栅化、TEV、ETC1 纹理、混合、深度/模板、光照 LUT、雾）。`Tests/GPU` 75 项断言通过（含运动矢量真值检查）。游戏已能画出真实帧。 | mipmap、程序纹理、阴影/立方体纹理、几何着色器；渲染速度；Metal 后端（接口 `PICAPixelBackend` 已留）。 |
| MetalFX | Spatial、Temporal、Denoised、Frame Interpolation 已接入双屏展示器，`Tests/MetalFX` 在 M4 上通过。游戏路径喂真实深度（`DepthExport`）、真实运动矢量（`PICAMotionTracker`：每个绘制用上一帧 uniform 重放顶点着色器，按透视正确插值得到像素运动）和 Halton(2,3) 亚像素抖动（视口偏移）。合成场景的真值测试通过：uniform 平移 12 像素给出 (0, +12) LCD 像素运动。 | 真实帧上运动矢量部分场景有效、部分无改善（见“运动矢量验证”）；Duo 真机未测。 |

应用的 `Test screens` 由自造 A32 程序只写一列像素；背景与文字由 UIKit 绘制。它验证双屏显示通路，不能当作《时之笛》画面。真实游戏尚不能在自研核心中游玩。

## 《时之笛 3D》启动记录

本机测试文件：`/Users/ocean/code/folium-duo-3ds/build/zelda-inspection/zelda-oot-decrypted.cxi`（本机资产，不在仓库）。Title ID `000400000008F900`。

自研核心现在能跑到标题画面、Hyrule 场景和战斗场景，上屏出真实 3D 画面，下屏出“按START鍵”触屏界面（繁体中文，来自 cfg 地区设置）。最后卡住游戏的几处根因，都已修在仓库里：线性堆基址（原 `0x30000000`，应为 `0x14000000`）；`cfg:u` 立体相机参数块 `0x00050005`；`hid:USER` 命令 `0x16` 的陀螺仪校准值；DSP 音频管道每帧中断；GSP 命令槽偏移与显示传输缩放尺寸。

调试方法：编译 `Tests/Boot`（见下方命令）并运行，参数 `指令数 [--trace] [--history] [--watch=地址] [--shot=目录] [--film=N] [--threads] [--dump=地址:数量] [--stack] [--gpu] [--motion] [--motioncheck=起始指令数]`，用 `llvm-objdump --triple=armv6k` 反汇编 `--dump-text` 导出的代码段（基址 0x100000）。每个停止点的循环是：读停止信息、查反汇编、补指令/SVC/服务命令，再重跑。

相关格式与 ABI 可查 [3dbrew NCCH](https://www.3dbrew.org/wiki/NCCH)、[SVC](https://www.3dbrew.org/wiki/SVC)、[Kernel ABI](https://www.3dbrew.org/wiki/Kernel_ABI)、[GSP Shared Memory](https://www.3dbrew.org/wiki/GSP_Shared_Memory)、[GPU/External Registers](https://www.3dbrew.org/wiki/GPU/External_Registers)。

## 代码入口

- `project.yml` 生成 `3duos.xcodeproj`；`App/` 是导入、选游戏、`GameRunner` 和测试帧；`UI/` 是掌机外观及触控表面。
- `Core/Cartridge/` 文件头、图标、程序段、RomFS；`Core/CPU/` ARM11 解释器；`Core/Memory/` 分页访客内存。
- `Core/Kernel/` 线程调度、同步对象、SVC；`Core/Boot/ProcessLoader.swift` 建进程并登记服务。
- `Core/Services/` HLE 服务：`srv:`、APT、fs:USER（RomFS/ExeFS、SaveData 目录存档）、gsp::Gpu、dsp::DSP、hid:USER、cfg:u、其余按需桩化（`stubbedCalls` 记录）。
- `Core/GPU/` PICA 命令解码、显示传输；`Core/Graphics/` LCD 帧、Metal 呈现和 MetalFX 管线。
- `Tests/` 是可单独用 `swiftc` 编译的核心检查；`ARCHITECTURE.md` 说明数据流。

## 复现与验证

在仓库根目录运行：

```sh
xcodegen generate
xcodebuild -project 3duos.xcodeproj -scheme 3duos -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

xcrun swiftc Core/CPU/*.swift Tests/CPU/main.swift -o /tmp/3duos-cpu-check
/tmp/3duos-cpu-check
xcrun swiftc -O Core/CPU/*.swift Core/GPU/GPUState.swift Core/GPU/GPUTransfer.swift Core/GPU/P*.swift Core/Graphics/FramebufferDecoder.swift Core/Memory/*.swift Core/Kernel/*.swift Core/Services/*.swift Core/Cartridge/*.swift Core/Boot/*.swift Tests/Boot/main.swift -o /tmp/3duos-boot-probe
/tmp/3duos-boot-probe /Users/ocean/code/folium-duo-3ds/build/zelda-inspection/zelda-oot-decrypted.cxi 200000000 --shot=/tmp
xcrun swiftc -O Core/CPU/*.swift Core/Memory/*.swift Core/Kernel/*.swift Core/Services/IPC.swift Core/GPU/*.swift Core/Graphics/FramebufferDecoder.swift Tests/GPU/*.swift -o /tmp/3duos-gpu-check
MTL_DEBUG_LAYER=1 /tmp/3duos-gpu-check
xcrun swiftc Core/Graphics/MetalFXScreenPipeline.swift Tests/MetalFX/main.swift -o /tmp/3duos-metalfx-check
MTL_DEBUG_LAYER=1 /tmp/3duos-metalfx-check 3
```

Cartridge、Graphics 的独立命令见各自 `Tests/*/README.md` 或测试入口。iOS generic 和 Mac Catalyst 已编译；Mac Catalyst 已实测导入、Open、HOME、测试帧和六种 MetalFX 组合。部署目标已升到 iOS 26（Denoised 需要 iOS 18，Frame Interpolation 需要 iOS 26）。2026-10-30 已安装 Duo iOS 27.2 simulator runtime，独立 App 已在该模拟器启动《时之笛》并显示双屏标题画面。本轮未验证 Duo 真机。旧版已安装 App 与新工程 App ID 不同：新工程为 `xyz.ocean33.3duos.lab`。

## 运动矢量验证

`--motioncheck=N` 在第 N 条指令后逐帧比较“用渲染器运动矢量把上一帧弯到当前帧”与“不弯”的亮度误差，并给出整图最佳平移。结果：合成场景正确；真实场景 4 段样本里，第 4 段（战斗，约 4.3e9 条指令处）弯折后误差 5.3 对 9.8，明显改善；其余 3 段没有改善，常见原因是画面变化来自动画、特效或着色器内运动，而不是几何位移。已排除：立体双眼交替、实例错配（按网格身份与 uniform 相似度匹配）、抖动混入（检查时关闭）。超过 64 像素的运动按新内容处理，置零。

## 下一步

1. 在应用内对比 Temporal 配合真实运动与块匹配的观感；必要时给运动矢量加置信度，低置信像素回退块匹配。
2. 渲染器与解释器提速：渲染繁忙帧 20–30 ms 降到 5 ms 内；解释器 JIT 之外的快速路径；然后是静态重编译（CPU 提升器）这条第二阶段路线。
3. 重编 iOS generic 与 Mac Catalyst，在应用内 Open 时之笛，核对 GameRunner、HID 触控、深度/运动/抖动在 MetalFX 里的实际观感，最后上 Duo 真机测方向、帧时间和功耗。
4. 其余 PICA 功能与服务：mipmap、程序/阴影/立方体纹理、几何着色器、Thumb、更多 HLE 服务。

可只读研究本机 `folium-duo-3ds/Cytrus/System/` 的 CPU→SVC/IPC→GSP→PICA→显示边界；自研工程仍按自身接口实现，不引入其源码或依赖。[Apple MetalFX](https://developer.apple.com/documentation/metalfx) 说明 Spatial 只需颜色纹理；[WWDC25 Metal 4](https://developer.apple.com/videos/play/wwdc2025/211/) 说明插帧需要前后帧、运动和深度。

## 本机空间

此前已清理多个 Xcode、Swift、Node 和视频过程缓存。本轮曾在没有 VM 进程或打开句柄时删除 Claude Cowork `rootfs.img`（10 GiB），保留其 `rootfs.img.zst` 与 `sessiondata.img`；空闲空间一度超过 50 GiB。Claude 桌面端随后在后台自动重建了这份镜像。尝试正常退出桌面端后，它又被后台任务拉起；目前不能把 50 GiB 目标记为持续达成。不要删除正在运行的 Claude 会话数据或手动删除系统 swap。磁盘空闲量会随系统 swap 变化，交接时用 `df -k /Users/ocean` 重新读取；不要以目录 `du` 代替实际回收量。

## Duo 合盖与展开 · 2026-10-30

- `UI/ConsolePresentation.swift` 使用 SDK 的 `UIHingeInteraction`（iOS 27.1+）。closed 显示横向白色 XL 外盖，partial/full 显示原有双屏。外盖转轴按作者反馈调整到 Duo 转轴侧。
- 外屏横向盖板在固定竖向场景里旋转铺满，展开后使用竖向双屏。素材、屏幕与触控区共用 `ConsoleShellGeometry`，内屏由留边改为等比铺满。
- `GameRunner` 使用条件变量暂停执行，展开继续同一个内核，恢复时重置计时；HOME 取消会唤醒已暂停的线程。合盖及离开前台清除触摸、摇杆和 HID 锁存输入。
- iOS 27 的 scene-bound display link 随场景切换显示器。盖板图片没有虚拟摄像头；内外素材的外侧黑底已用生图补白。资源和完整提示词见 `Design/ASSETS.md`，视觉决定见 `DESIGN.md`。
- 上屏随后改为 900 × 540（5:3），宽度比原版增加约 16%，面积增加约 21%；生成新皮肤 `New3DSWhiteFaceplateXLBigScreen`，同步收窄上屏边框、外移扬声器孔。坐标仍由 `ConsoleShellGeometry` 统一维护。
- Duo 模拟器验证过 closed → partial → full 和游戏中 closed → full。核心日志显示 frame 2509 合盖，36 秒后仍从 frame 2509 继续；同一进程恢复后帧数继续增长。最终版 Start 按键已从标题进入存档选择界面。截图和日志在本机 `build/validation/duo-*.png`、`duo-core-fold.log`；构建日志为 `closed-lid-build.log` 与 `closed-lid-ios-build.log`。
