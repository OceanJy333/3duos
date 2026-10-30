# 启动探针

从仓库根目录编译：

```sh
xcrun swiftc -O Core/CPU/*.swift Core/GPU/GPUState.swift Core/GPU/GPUTransfer.swift Core/Graphics/FramebufferDecoder.swift Core/Memory/*.swift Core/Kernel/*.swift Core/Services/*.swift Core/Cartridge/*.swift Core/Boot/*.swift Tests/Boot/main.swift -o /tmp/3duos-boot-probe
/tmp/3duos-boot-probe
```

不带参数运行合成检查。传入本机解密 CXI 和指令上限，用自研内核实际运行游戏：

```sh
/tmp/3duos-boot-probe /path/to/decrypted.cxi 200000000
```

可选标志：`--trace` 打印每个 SVC（含线程号和 tick）与服务调用；`--history` 打印停止前最后 400 个 PC；`--watch=十六进制地址` 记录谁在何时写了该字；`--shot=目录` 把当前上下屏帧缓冲写成 `top.ppm`、`bottom.ppm`；`--dump-text=文件` 导出解压后的代码段；`--texfilter` 打开贴图预放大；`--texdump=目录` 按 Citra/Azahar 命名导出游戏用到的贴图，`--texpack=目录` 加载替换贴图包。输出末尾给出停止原因、各线程状态、被桩化的服务命令。存档写到系统临时目录下的 `3duos-saves`。
