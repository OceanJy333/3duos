# 3duos 自研内核

本工程是独立 Git 仓库，应用只链接 Apple 系统框架。旧版可玩的 3duos 留作画面、输入与性能对照；这里的游戏执行、系统服务和图形链路由我们逐步实现。

## 数据流

```text
本地 CXI/CCI
  → NCSD/NCCH、ExeFS、SMDH、BLZ
  → text / ro / data / bss 映射
  → ARM11（ARMv6K）CPU 与线程
  → SVC、句柄、IPC、FS/GSP/HID/DSP/APT 服务
  → PICA200 命令、顶点/片元、显存传输
  → 上下 LCD framebuffer → Metal → 3duos 双屏
```

现在已实现文件解析、代码段映射、A32 指令子集、部分内核 SVC、PICA 命令列表解析、LCD BGR8 解码和原生 Metal 显示。应用中的测试帧由自造 A32 程序写入一列帧缓冲，再交给 Metal 显示；测试帧文字由 UIKit 绘制。独立测试以合成 PICA 寄存器和顶点数据驱动固定 Metal 着色器，绘制三角形并回读像素。PICA 着色器和游戏程序尚未驱动画面。

## 《时之笛 3D》实测入口

本地繁体中文 CXI 的 Title ID 为 `000400000008F900`，产品码 `CTR-P-AQEW`。自研解析器提取了 SMDH 标题和图标，将 `.code` 从 2,876,004 字节解压为 4,624,384 字节，并按 ExHeader 映射三个程序段。从入口 `0x00100000` 执行真实 A32 指令，先后处理了 `0x21`（CreateAddressArbiter）和 `0x38`（GetResourceLimit）。严格探针在第 310,987 条、`0x001006A4` 停于 `0x3A`（GetResourceLimitCurrentValues）：尚无证据确定真实系统此刻的共享 COMMIT 计数。

另有明确标记的探索模式 `--estimated-commit`，以映射的程序段、按页取整的 BSS 和栈估算 5,058,560 字节。它已越过 `0x01`（ControlMemory），当前停在 VFP 算术；这条路径仅用于发现下一项实现缺口，不代表真实 3DS 返回同一计数或执行同一分支。最新指令位置、验证结果和下一步统一记录在 [HANDOFF.md](HANDOFF.md)。

游戏的 RomFS 中有角色、场景、繁体中文菜单与文本、音频及 PICA shader 资源。读到这些文件不等于还原了游戏引擎。先以程序执行和系统服务为主线，等首个 GSP 命令出现后再用真实数据验证 PICA 渲染。

## 接下来按真实缺口推进

1. 补 ARM11 Thumb/VFP、异常、内存语义，并由真实程序指令或自制测试验证。
2. 从首个 SVC 开始实现句柄、线程、调度和 IPC；每次记录新的停止点，直到游戏提交首个 GSP 命令。
3. 现有合成 PICA 命令、受限 float2 顶点和固定 Metal 着色器的三角形测试；继续实现 PICA 着色器、通用顶点格式、纹理、深度、TEV 与显存传输，再用游戏提交的命令验证。
4. 首帧之后逐项接输入、下屏触摸、DSP 音频和存档；用真实游戏画面与操作验收。
5. Metal 4 MetalFX Spatial 已在 Apple M4 上完成 64×64 至 128×128 合成纹理放大与 GPU 回读，待接入双屏展示器。Temporal 与 Frame Interpolation 需要连续颜色帧、深度和运动向量；神经降噪还需要适用的噪声和材质数据，只有输入齐备且实测改善画质时才接入。

技术依据：[3dbrew NCCH](https://www.3dbrew.org/wiki/NCCH)、[SVC](https://www.3dbrew.org/wiki/SVC)、[PICA GPU 寄存器](https://www.3dbrew.org/wiki/GPU/Internal_Registers)、[Arm ARMv6 架构手册](https://developer.arm.com/documentation/ddi0100/latest/)、[Apple MetalFX](https://developer.apple.com/documentation/metalfx)、[Metal 4 Frame Interpolation](https://developer.apple.com/videos/play/wwdc2025/211/)。
