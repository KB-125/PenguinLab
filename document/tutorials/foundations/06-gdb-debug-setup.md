---
title: "GDB + QEMU 远程调试 ARM64 内核"
prerequisites:
  - qemu-first-boot
next:
  - linux-kconfig
difficulty: beginner
tags: [gdb, qemu, debug, kaslr, vscode, arm64]
architectures: [arm64]
kernel_version: "6.19"
maturity: verified
---

## 做什么

这篇我们搭建内核调试的基础设施——GDB 远程调试 ARM64 内核。后续写内核模块、调驱动、排查 panic 都要靠这套工具链，所以它值得我们花时间认真搞对。说实话，这个过程比想象中曲折不少，我们一共碰到了四层问题：`vmlinux` 里根本没有调试信息、QEMU 没有开放调试端口、VSCode 调试配置用了错误的 GDB、以及 KASLR 导致断点地址对不上。每一层单独看都不复杂，但叠在一起就是"断点是红色的但内核直接跑过去了"这种让人血压拉满的现象。我们从头到尾拆解一遍，以后遇到类似问题可以按这个排查层次快速定位。

## 要了解什么

### 第零层：`vmlinux` 里必须有调试信息

这一层不在 QEMU 也不在 GDB 侧，而在内核自身。如果 `vmlinux` 没有调试信息，GDB 依然能连上、断点也依然能命中，但 `list` 只能看到反汇编、`info locals` 看不到变量、单步时没有源码行号——很多人会误以为是 GDB 或 KASLR 的问题，其实是内核编的时候就没带 DWARF。我们按 [02 mini config](./02-kernel-mini-config.md) 的流程配置内核时就撞上了这一层：fragment 里写了 `CONFIG_DEBUG_INFO=y`，但它在 `olddefconfig` 阶段被悄悄丢掉（原因和修法见那边的小节 "CONFIG_DEBUG_INFO=y 写了，vmlinux 却没有调试信息"）。

连接 GDB 之前先花 10 秒确认：

```bash
aarch64-linux-gnu-readelf -S out/build_latest_arm64/vmlinux | grep -c '\.debug_'
```

输出应该是一个正数（DWARF 调试段的数量）；如果是 `0`，说明符号表里没有调试信息，先回 02 对一遍 fragment 里的 `CONFIG_DEBUG_KERNEL` 和 `CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT`。另一个最快的旁证是文件大小——带调试信息的 `vmlinux` 是几十 MB 量级，不带的是 7 MB 左右。

### 第一层：QEMU 必须开放 GDB 端口

QEMU 默认启动内核时是直接跑完的，不会在任何地方暂停等待调试器连接。要让 GDB 有介入的机会，我们需要两个启动参数：`-s` 是 `-gdb tcp::1234` 的简写，让 QEMU 在 1234 端口开放 GDB 远程调试协议的监听；`-S` 让 QEMU 在启动后立刻冻结 CPU，不执行第一条指令，等待 GDB 发送 `continue` 命令后才继续。

我们的 [qemu-run.sh](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/scripts/qemu-run.sh) 脚本为此增加了一个 `debug` 命令，在构建 QEMU 命令时自动追加 `-s -S`：

```bash
./scripts/qemu-run.sh debug
```

这样 QEMU 启动后会停在最初的状态，等待 GDB 连接。如果直接用 `run` 命令启动，内核会不等你直接跑完，GDB 根本没有连接的窗口。

### 第二层：必须用交叉调试器

这一层是我们实际踩过的大坑。最初 VSCode 的 `launch.json` 配置里用了本机的 `/usr/bin/gdb`——这是一个 x86_64 架构的 GDB，它根本不认识 ARM64 指令集。虽然连接 QEMU 的 GDB stub 本身不需要理解目标架构（GDB 远程协议是架构无关的），但解析符号、设置断点、单步执行这些操作都需要理解目标二进制的指令编码和寄存器布局，x86 的 GDB 做不了这些。

正确的做法是用交叉工具链自带的 `aarch64-linux-gnu-gdb`。修正后的 VSCode `launch.json` 配置如下：

```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Kernel Debug (ARM64 QEMU)",
            "type": "cppdbg",
            "request": "launch",
            "program": "${workspaceFolder}/out/build_latest_arm64/vmlinux",
            "MIMode": "gdb",
            "miDebuggerPath": "/usr/sbin/aarch64-linux-gnu-gdb",
            "miDebuggerServerAddress": "localhost:1234",
            "cwd": "${workspaceFolder}",
            "setupCommands": [
                {
                    "text": "set architecture aarch64",
                    "ignoreFailures": false
                }
            ]
        }
    ]
}
```

这里有几个关键点。`program` 指向 `vmlinux` 而不是 `Image`，因为 GDB 需要 ELF 格式的文件来读取符号表和调试信息（`Image` 是剥离了这些信息的纯二进制）。`miDebuggerPath` 指向交叉调试器。`miDebuggerServerAddress` 告诉 VSCode GDB stub 的地址和端口。注意不要在 `setupCommands` 里重复添加 `target remote localhost:1234`——`miDebuggerServerAddress` 这个字段本身就会让 cppdbg 适配器自动执行 `target remote` 连接，手动再来一遍会导致重复连接报错。

如果你用的是 Ubuntu/Debian、只装了 `gdb-multiarch`（本机就是这种情况：`/usr/bin/gdb-multiarch` 存在，但 `aarch64-linux-gnu-gdb` 不在 PATH 里），把上文所有命令里的 `aarch64-linux-gnu-gdb` 换成 `gdb-multiarch` 即可，它内置 AArch64 支持，效果一样。

### 第三层：KASLR 让断点地址偏走了

前两层都修好之后，我们用命令行 GDB 验证断点确实能设成功：

```
$ aarch64-linux-gnu-gdb -batch \
  -ex "set architecture aarch64" \
  -ex "target remote localhost:1234" \
  -ex "break start_kernel" \
  -ex "info breakpoints" \
  out/build_latest_arm64/vmlinux

Breakpoint 1 at 0xffff800080550a08: file init/main.c, line 1006.
```

`start_kernel` 的断点设在 `0xffff800080550a08`，地址解析正确，源码行号也对。但内核还是不断——这就是第三层问题。

根因是 KASLR（Kernel Address Space Layout Randomization，内核地址空间布局随机化）。`vmlinux` 文件里的符号地址是编译时静态链接的——比如 `start_kernel` 在 `0xffff800080550a08`，内核基址 `_text` 从 `0xffff800080000000` 开始。如果 KASLR 生效，内核每次启动时会把加载基址加上一个随机偏移，实际运行时的地址就和编译时的符号地址错开，GDB 拿着静态地址去设断点，当然拦不住在不同地址上执行的代码。

这里要补一句说明：我们这版 mini config 是从 `allnoconfig` 起步的，`CONFIG_RANDOMIZE_BASE` 默认是关的（可以 `grep RANDOMIZE_BASE out/build_latest_arm64/.config` 确认），所以用本站配置构建的内核不会触发这一层。但这是一个非常经典的坑——一旦你改用 `defconfig`（它默认 `CONFIG_RANDOMIZE_BASE=y`）或者手动把 KASLR 打开，静态符号地址和运行时地址就会错开，断点"设上了却打不中"。

解决方案是在内核启动参数里加 `nokaslr`，告诉内核这次不要随机化地址。我们把它集成到了 `debug` 命令里，只有调试时才关掉 KASLR，正常运行时保持开启：

```bash
build_qemu_debug_command() {
    local cmd
    cmd="$(build_qemu_command)"
    # nokaslr: 让 GDB 断点地址匹配 vmlinux 的静态符号
    cmd="${cmd/rdinit=\/init/rdinit=\/init nokaslr}"
    # -s -S: 开放 GDB 端口 + 启动时暂停
    cmd+=" -s -S"
    echo "${cmd}"
}
```

这里用了一个 bash 字符串替换技巧，在已有的 `-append` 参数里插入 `nokaslr`，而不是覆盖整个参数。

### 完整的调试工作流

上面的问题全部修完之后，调试流程就通了，一共三步。

第一步，在一个终端启动 QEMU 调试模式：

```bash
./scripts/qemu-run.sh debug
```

QEMU 启动后暂停，等待 GDB 连接。

第二步，用命令行 GDB 连接并设断点（或者用 VSCode 按 F5）：

```bash
aarch64-linux-gnu-gdb out/build_latest_arm64/vmlinux
(gdb) set architecture aarch64
(gdb) target remote :1234
(gdb) break start_kernel
(gdb) continue
```

第三步，断点命中。你会看到 GDB 停在 `init/main.c` 的 `start_kernel` 函数，从这里开始就可以单步执行、查看变量、观察调用栈了。

### 排查层次总结

回顾一下，这几个问题形成了一个从外到内的排查层次。最外层是 `vmlinux` 本身没有调试信息——这时 GDB 能连上、断点能命中，但 `list` 只有反汇编、看不到源码和变量；再往里是 QEMU 启动参数——没有 `-s -S` 的话 GDB 根本没有介入的窗口；然后是调试工具链——用错 GDB 或者重复执行 `target remote` 会导致连接异常；最深层是内核自身的 KASLR——它让运行时地址和编译时符号不一致。以后遇到"断点不命中"或"断点命中但看不到源码"的问题，建议按 **调试信息 → QEMU 参数 → GDB 连接 → 地址映射** 这个顺序逐层排查。

## 动手试试

1. 终端运行 `./scripts/qemu-run.sh debug`，观察输出中是否包含 "Waiting for GDB connection"
2. 另开一个终端，用命令行 GDB 连接并设断点验证：`aarch64-linux-gnu-gdb -batch -ex "target remote :1234" -ex "break start_kernel" -ex "c" out/build_latest_arm64/vmlinux`
3. 如果使用 VSCode，配置好 `launch.json` 后按 F5，确认断点能命中
4. 在 GDB 中尝试 `bt`（查看调用栈）、`list`（查看源码）、`info registers`（查看寄存器）
5. 试试在 `rest_init` 或 `kernel_init` 等其他函数上设断点，观察内核启动的不同阶段

## 延伸阅读

- [GDB 内核调试文档](https://docs.kernel.org/process/debugging/gdb-kernel-debugging.html) — kernel.org 官方的 QEMU+GDB 调试方法
- [Speeding up kernel development with QEMU](https://lwn.net/Articles/660404/) — LWN 经典文章
- qemu-run.sh — 项目脚本中的 `build_qemu_debug_command()` 函数
