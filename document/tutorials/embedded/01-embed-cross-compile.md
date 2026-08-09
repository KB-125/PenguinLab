---
title: "嵌入式交叉编译:在 x86 上编 ARM/RISC-V 代码"
slug: embed-cross-compile
prerequisites:
  - wsl2-env-toolchain
  - kernel-module-hello
next:
  - embed-qemu
difficulty: intermediate
tags: [embedded, cross-compile, toolchain, sysroot, arm64, arm32, riscv]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch05.md
  - guide: document/guides/
maturity: drafting
related:
  - /tutorials/foundations/01-wsl2-env-toolchain
  - /tutorials/foundations/07-kernel-module-hello
---

> 🔨 **整理中** · 这一篇讲**交叉编译**——在 x86 宿主机上编译出 ARM/RISC-V 目标机运行的代码。素材从 ch05 + 本站 foundations 的工具链实战整理。本站从一开始就在做交叉编译(编 ARM64 内核、编模块),这篇把它系统化:工具链组成、sysroot、内核/模块/用户态三类的交叉编译差异、常见坑。

## 做什么

嵌入式开发里,宿主机(你的 x86 PC/WSL)和目标机(ARM/RISC-V 板子)架构不同——你不能直接用宿主机 gcc 编出能在板子上跑的代码。**交叉编译(cross compile)** 就是用一个"跑在 x86、但生成 ARM 代码"的特殊 gcc,在宿主机上产出目标机可执行的二进制。本站 [01 WSL2 环境](../foundations/01-wsl2-env-toolchain.md) 装的 `aarch64-linux-gnu-gcc` 就是 ARM64 的交叉编译器,我们一直在用它编内核和模块。这篇系统化讲交叉编译的全套:工具链怎么来、怎么用、不同场景(内核/模块/用户态程序)的差异、以及 ABI/浮点等坑。

## 要了解什么

### 一、工具链(toolchain):4 件套

一个交叉工具链是 4 个核心工具的组合,**前缀**统一(如 `aarch64-linux-gnu-`):

- **`<prefix>-gcc`**:交叉编译器(C → 目标架构机器码)
- **`<prefix>-ld`/`as`/`ar`/`objdump`/`readelf`**:binutils 二进制工具(链接/汇编/反汇编)
- **`<prefix>-gdb`**:交叉调试器(在宿主机上调试目标二进制,关联 [06 gdb 调试](../foundations/06-gdb-debug-setup.md))
- **libc**(glibc/musl):目标机的 C 库(程序运行时依赖)

常见前缀:`aarch64-linux-gnu-`(ARM64)、`arm-linux-gnueabihf-`(ARM32 硬浮点)、`riscv64-linux-gnu-`(RISC-V 64)。装工具链:`apt install gcc-aarch64-linux-gnu` 等;或用 Linaro/Bootlin 的预编译包,或自己用 Buildroot/Yocto 构建。

### 二、内核与模块:ARCH + CROSS_COMPILE

交叉编译内核:[03 编译内核](../foundations/03-kernel-build.md) 走 `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make`。关键两个变量:`ARCH`(目标架构,决定 `arch/<arch>/` 走哪套)和 `CROSS_COMPILE`(工具链前缀,让 make 调 `<prefix>-gcc` 而非宿主 gcc)。本站的 [example/common/Makefile.arch](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/example/common/Makefile.arch) 把它们设好并 `export`,模块 `make` 自动走交叉编译——[07 第一个模块](../foundations/07-kernel-module-hello.md) 的"第一个坑"就是这两个变量没传进递归子 make。

### 三、用户态程序:sysroot 是关键

交叉编译用户态程序(如 BusyBox、自己的 C 程序),光有 `<prefix>-gcc` 还不够——编译器要找**目标机的头文件和库**(目标机的 libc.so、内核头、其他依赖库),这块叫 **sysroot**。工具链自带一个默认 sysroot(`aarch64-linux-gnu-gcc -print-sysroot` 看),里面有目标 libc;但若你的程序依赖额外库(如 libssl),要么自己交叉编那些库放 sysroot、要么用一个完整的交叉编译发行版构建系统(Buildroot/Yocto)替你管 sysroot。

典型交叉编一个用户态 C 程序:`aarch64-linux-gnu-gcc -o hello hello.c`(静态链接最简单);用 autotools/cmake 的项目用 `./configure --host=aarch64-linux-gnu` 或 `cmake -DCMAKE_TOOLCHAIN_FILE=...` 让构建系统切到交叉工具链。

### 四、常见坑

- **ABI/浮点**:ARM32 有软浮(gnueabi)和硬浮(gnueabihf)两套 ABI,工具链必须和目标用户态匹配,否则链接期符号找不到或运行时寄存器约定冲突。ARM64 统一硬浮,没这问题。
- **vermagic**:内核模块带版本魔数,模块和运行的内核必须 vermagic 完全一致(版本+编译器+配置),否则 `insmod` 报 `Invalid module format`——[07 模块](../foundations/07-kernel-module-hello.md) 讲过。
- **链接了宿主库**:忘了设 sysroot 或 `LDFLAGS`,误链接了宿主机的 x86 libc,跑在 ARM 上直接 exec format error。

## 动手试试

1. `aarch64-linux-gnu-gcc -print-sysroot` 看 sysroot 路径;`dpkg -L gcc-aarch64-linux-gnu` 看工具链包含哪些工具
2. 写个 hello.c,`aarch64-linux-gnu-gcc -static -o hello hello.c` 静态编译;`file hello` 确认是 ARM64;拷进 QEMU BusyBox 跑(`./hello` 输出 hello world)
3. 交叉编一个开源项目(`./configure --host=aarch64-linux-gnu && make`),体会 autotools 的 `--host` 切换
4. 故意用错的 ABI(如 ARM32 用 gnueabi 工具链链硬浮库),观察链接/运行报错
5. 思考题:为什么交叉编用户态需要 sysroot,而交叉编内核模块不需要?(提示:内核模块不依赖 libc,只依赖内核符号)

## 延伸阅读

- 关联本站:[01 WSL2 环境](../foundations/01-wsl2-env-toolchain.md) 装工具链、[03 编译内核](../foundations/03-kernel-build.md) 交叉编内核、[07 模块](../foundations/07-kernel-module-hello.md) 交叉编模块 + `Makefile.arch` 的 export 修复;[06 gdb](../foundations/06-gdb-debug-setup.md) 交叉调试。
- 外部:Linaro/Bootlin 预编译工具链;`crosstool-NG`(自己构建工具链);Buildroot/Yocto 也内置工具链构建。
- 读书笔记:[ch05](../../notes/linux_kernel_programming/ch05.md) 讲交叉编译内核模块的多次尝试与坑。
