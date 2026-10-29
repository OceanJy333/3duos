# 首次取指探针

从仓库根目录编译并运行合成检查：

```sh
swiftc Core/CPU/*.swift Core/Cartridge/*.swift Core/Kernel/*.swift Core/Boot/*.swift Tests/Boot/main.swift -o /tmp/3duos-boot-probe
/tmp/3duos-boot-probe
```

传入本机解密 CXI 可检查实际入口；可选第二个参数设置指令上限，默认 10,000：

```sh
/tmp/3duos-boot-probe /path/to/decrypted.cxi 500000
/tmp/3duos-boot-probe /path/to/decrypted.cxi 500000 --hle
/tmp/3duos-boot-probe /path/to/decrypted.cxi 500000 --hle --estimated-commit
```

默认在第一个 SVC 处停止。`--hle` 使用内核分发器处理已实现的 SVC，继续到下一个未支持的调用、CPU 停止或指令上限；输出处理过的调用数量和未支持调用编号。

`--estimated-commit` 给 `GetResourceLimitCurrentValues` 注入一个仅用于探索的 COMMIT 数值：已映射程序段大小、按页取整的 BSS 和主线程栈大小之和。真实系统的资源限制可能由同一类别的其他进程共享；没有这个参数时，探针在未建立真实计数的资源查询处停止。

探针将解压后的 text、ro、data 映射到头部指定地址，把 BSS 接在 data 页面之后，初始化位于 `0x10000000` 以下的栈，并在 `0x1FF82000` 映射主线程 TLS 页，再从 text 起始地址执行。结果中的 `running` 表示达到上限；PC 和指令为下一条待执行指令。其他停止结果的 PC 和指令对应触发停止的指令。Thumb 状态下只报告首个 16 位半字。计数是 CPU 已取指的 A32 指令数。

探针使用 Old3DS retail 的测试配置：`APPMEMTYPE=0`、`APPMEMALLOC=0x04000000`（64 MiB）。配置页只读，目前只提供这两个已知字段；访问其他字段会停止。字段和页位置见 [Configuration Memory](https://www.3dbrew.org/wiki/Configuration_Memory)，内存布局见 [Memory layout](https://www.3dbrew.org/wiki/Memory_map)。这组值会影响游戏分配内存的启动分支，并非对实际设备配置的读取。

该探针只检查现有解释器的启动路径，尚未实现游戏运行需要的完整指令集、系统调用及硬件环境。游戏文件留在本机，不加入仓库。
