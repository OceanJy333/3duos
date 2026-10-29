# 3duos 自研模拟器交接

更新：2026-10-29。工程位于 `/Users/ocean/code/3duos`，是没有远端的独立 Git 仓库。用户明确要求模拟器也自己开发：允许下载或阅读其他仓库以研究行为，不 fork、不引入第三方模拟器运行库，也不复制其实现。本工程应用只链接 Apple 系统框架。旧工程 `/Users/ocean/code/folium-duo-3ds` 中可玩的 3duos 仅用于效果对照；它运行 Cytrus，与这里的自研核心没有链接关系。

## 当前结果

| 部分 | 已完成并验证 | 尚未完成 |
| --- | --- | --- |
| 游戏库 | 导入解密的 CXI/CCI/3DS，读取 NCSD/NCCH、ExeFS、SMDH 标题和图标。Mac Catalyst 已用本地《时之笛 3D》文件实际导入并显示繁体中文标题。 | 加密卡带解密、安装格式。 |
| 应用入口 | 白色 New 3DS XL 外观、HOME 风格游戏库、选中游戏后 `Open`、`Test screens` 与 HOME 返回。`Open` 在后台运行严格启动探针，显示停止位置；Mac Catalyst 用真实文件观察到第 310,813 条指令、PC `0x001046C8`、SVC `0x21`，无明显卡顿或崩溃。 | 应用内继续执行 SVC/系统服务并进入游戏画面；触屏按钮和摇杆尚未连接到自研 HID。 |
| CPU 与启动 | 自写 ARM11 ARMv6K A32 解释器、程序段与内存映射、VFPv2 系统状态及单/双寄存器访存、部分内核 SVC。CPU 独立测试 125 项断言通过。 | Thumb、完整 VFP 算术、异常/MMU、线程调度。 |
| GPU 与显示 | 自写 PICA 命令解码；合成命令读取受限 float2 顶点，经固定 Metal 着色器画离屏三角形，Metal Validation 与像素回读通过。LCD BGR8 双屏解码和原生 Metal 贴图显示通过。 | PICA 着色器、通用顶点格式、纹理、TEV、深度、GSP 提交、游戏帧缓冲。现在的三角形不是游戏画面。 |
| MetalFX | Metal 4 Spatial 以 64×64 合成纹理放大至 128×128，Apple M4 上四个色块 GPU 回读通过。 | 接入实际双屏帧链路；Temporal、Frame Interpolation、Neural Denoising 需要游戏帧及相应深度、运动、材质等输入，当前未接入。 |

应用的 `Test screens` 由自造 A32 程序只写一列像素；背景与文字由 UIKit 绘制。它验证双屏显示通路，不能当作《时之笛》画面。真实游戏尚不能在自研核心中游玩。

## 《时之笛 3D》启动记录

本机测试文件：`/Users/ocean/code/folium-duo-3ds/build/zelda-inspection/zelda-oot-decrypted.cxi`。它属于本机测试资产，不在新仓库。Title ID `000400000008F900`，产品码 `CTR-P-AQEW`；`.code` 由 2,876,004 字节解压成 4,624,384 字节，BSS 414,344 字节，主线程栈 16,384 字节。

| 模式 | 真实程序执行到的边界 | 解释 |
| --- | --- | --- |
| 应用 `Open` / CLI 默认 | 310,813 条；PC `0x001046C8`；SVC `0x21` | 严格探针在首个系统调用停下，Mac Catalyst UI 已回读一致结果。 |
| CLI `--hle` | 310,987 条；PC `0x001006A4`；SVC `0x3A` | 已处理 `CreateAddressArbiter` 和 `GetResourceLimit`；真实资源类别的当前 COMMIT 占用尚无可靠初值。 |
| CLI `--hle --estimated-commit` | 312,248 条；PC `0x004C8A08`；`FMULS s1,s2,s1` 尚未实现 | 仅供发现下一缺口。以程序段、BSS、栈估算初始 COMMIT 为 5,058,560 字节，并假设旧版线性内存从 `0x14000000` 顺排；这不是实际设备回读。已越过资源查询和 27 MiB 线性内存申请。 |

当前探针固定 Old3DS retail 测试配置：`APPMEMTYPE=0`、`APPMEMALLOC=64 MiB`。装载和后续内存提交已按此配置检查尺寸；其他内存配置还未实现。相关格式与 ABI 可查 [3dbrew NCCH](https://www.3dbrew.org/wiki/NCCH)、[SVC](https://www.3dbrew.org/wiki/SVC)、[Kernel ABI](https://www.3dbrew.org/wiki/Kernel_ABI)、[Memory Management](https://www.3dbrew.org/wiki/Memory_Management)。

## 代码入口

- `project.yml` 生成 `3duos.xcodeproj`；`App/` 是导入、选游戏和启动检测；`UI/` 是掌机外观及触控表面。
- `Core/Cartridge/` 负责文件头、图标、程序段和 BLZ 解压；`Core/CPU/` 执行 ARM11 指令。
- `Core/Boot/` 建立访客内存并限制探针指令数；`Core/Kernel/` 处理已实现的 SVC、句柄和内存提交。
- `Core/GPU/` 从 PICA 命令到合成几何；`Core/Graphics/` 负责 LCD 帧、Metal 呈现和 MetalFX Spatial 实验。
- `Tests/` 是可单独用 `swiftc` 编译的核心检查；`ARCHITECTURE.md` 说明完整数据流。

## 复现与验证

在仓库根目录运行：

```sh
xcodegen generate
xcodebuild -project 3duos.xcodeproj -scheme 3duos -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

xcrun swiftc Core/CPU/*.swift Tests/CPU/main.swift -o /tmp/3duos-cpu-check
/tmp/3duos-cpu-check
xcrun swiftc Core/CPU/*.swift Core/Kernel/*.swift Tests/Kernel/main.swift -o /tmp/3duos-kernel-check
/tmp/3duos-kernel-check
xcrun swiftc Core/CPU/*.swift Core/Cartridge/*.swift Core/Kernel/*.swift Core/Boot/*.swift Tests/Boot/main.swift -o /tmp/3duos-boot-probe
/tmp/3duos-boot-probe /Users/ocean/code/folium-duo-3ds/build/zelda-inspection/zelda-oot-decrypted.cxi 500000 --hle
/tmp/3duos-boot-probe /Users/ocean/code/folium-duo-3ds/build/zelda-inspection/zelda-oot-decrypted.cxi 500000 --hle --estimated-commit
xcrun swiftc Core/GPU/*.swift Tests/GPU/main.swift -o /tmp/3duos-gpu-check
MTL_DEBUG_LAYER=1 /tmp/3duos-gpu-check
xcrun swiftc Core/Graphics/MetalFXSpatial.swift Tests/MetalFX/main.swift -o /tmp/3duos-metalfx-check
MTL_DEBUG_LAYER=1 /tmp/3duos-metalfx-check
```

Cartridge、Graphics 的独立命令见各自 `Tests/*/README.md` 或测试入口。iOS generic 和 Mac Catalyst 已编译；Mac Catalyst 已实测导入、Open、HOME 和测试帧。此机 `simctl` 当前没有 iOS runtime，Duo 在 `devicectl` 显示 `unavailable`；独立 App 尚未在 Duo 真机安装或验收。旧版已安装 App 与新工程 App ID 不同：新工程为 `xyz.ocean33.3duos.lab`。

## 下一步

1. 实现 VFPv2 `FMULS` 及相关算术的舍入、异常和寄存器语义，用真实启动程序与定向断言验证；继续记录下一个停止位置。
2. 建立真实资源限制记账与标题所需的内存布局，替换探索模式中的估算值；再补线程、IPC、服务发现与首个 GSP 请求。未知系统调用继续显式停止。
3. 将游戏提交的 PICA 命令、顶点、着色器、纹理和显示传输逐步映射到原生 Metal；拿到真实上/下屏帧后，再把现有 MetalFX Spatial 接入展示器。
4. 真实画面出现后接 HID 按键、摇杆、下屏触摸、DSP 音频与存档，最后在 Duo 上测方向、折叠布局、帧时间和功耗。

可只读研究本机 `folium-duo-3ds/Cytrus/System/` 的 CPU→SVC/IPC→GSP→PICA→显示边界；自研工程仍按自身接口实现，不引入其源码或依赖。[Apple MetalFX](https://developer.apple.com/documentation/metalfx) 说明 Spatial 只需颜色纹理；[WWDC25 Metal 4](https://developer.apple.com/videos/play/wwdc2025/211/) 说明插帧需要前后帧、运动和深度，神经降噪还需无噪的材质辅助数据。

## 本机空间

此前已清理多个 Xcode、Swift、Node 和视频过程缓存。本轮曾在没有 VM 进程或打开句柄时删除 Claude Cowork `rootfs.img`（10 GiB），保留其 `rootfs.img.zst` 与 `sessiondata.img`；空闲空间一度超过 50 GiB。Claude 桌面端随后在后台自动重建了这份镜像。尝试正常退出桌面端后，它又被后台任务拉起；目前不能把 50 GiB 目标记为持续达成。不要删除正在运行的 Claude 会话数据或手动删除系统 swap。磁盘空闲量会随系统 swap 变化，交接时用 `df -k /Users/ocean` 重新读取；不要以目录 `du` 代替实际回收量。
