<!-- input: standalone kernel integration test -->
<!-- output: build and run command -->
<!-- pos: Kernel test entry point -->

Run from the repository root:

```sh
swiftc Core/CPU/*.swift Core/Kernel/*.swift Tests/Kernel/main.swift -o /tmp/3duos-kernel-check
/tmp/3duos-kernel-check
```

The guest program executes real A32 SVC and MOV instructions. The host dispatches each SVC after the CPU traps, as the boot loop must do.

ABI references: [3dbrew SVC list](https://www.3dbrew.org/wiki/SVC); [libctru SVC assembly](https://github.com/devkitPro/libctru/blob/master/libctru/source/svc.s) shows the `r0` result, `r1` output handle, and `r0` close input. For GetResourceLimit, the process input is in `r1`; [libctru's header](https://github.com/devkitPro/libctru/blob/master/libctru/include/3ds/svc.h) defines the current-process pseudo handle.

For GetResourceLimitCurrentValues, `r0` is the output array, `r1` the resource-limit handle, `r2` the array of names, and `r3` the count. The implemented COMMIT query requires `currentCommit` to be supplied by the boot context; otherwise it remains unsupported. Resource limits are shared by category as described in [3dbrew KResourceLimit](https://www.3dbrew.org/wiki/KResourceLimit).
