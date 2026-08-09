---
title: "多架构:一份内核跑遍 ARM/RISC-V/x86"
slug: embed-multi-arch
prerequisites:
  - embed-cross-compile
  - kernel-mini-config
difficulty: intermediate
tags: [embedded, multi-arch, arm64, arm32, riscv, x86_64]
architectures: [arm64, arm32, riscv, x86_64]
kernel_version: "6.19"
sources:
  - guide: configs/、example/common/Makefile.arch
maturity: drafting
related:
  - /tutorials/embedded/01-embed-cross-compile
---

> 🔨 **整理中** · 这一篇讲**多架构**——Linux 内核源码一份,能编出 ARM64/ARM32/RISC-V/x86_64 各种架构的内核。素材从本站 `example/common/Makefile.arch`(支持多架构) + configs/ 整理。本站主线是 ARM64,但构建系统支持切其他架构。

## 做什么

Linux 内核是个**跨架构**的内核——同一份源码树,通过 `arch/<arch>/` 目录隔离架构相关代码,用 `ARCH=` 变量切换,能编出跑在不同 CPU 架构上的内核。这是 Linux 相对很多"绑死某架构"的内核的大优势。本站 [02 mini config](../foundations/02-kernel-mini-config.md)/[03 编译内核](../foundations/03-kernel-build.md) 主线是 ARM64,但 [Makefile.arch](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/example/common/Makefile.arch) 已经支持切 `arm`/`riscv`/`x86_64`。这一篇讲内核怎么做到多架构、怎么在它们之间切换、多架构测试的价值。

## 要了解什么

### 一、内核源码的架构组织:`arch/<arch>/`

内核源码树里 `arch/` 下每个架构一个目录:`arch/arm64/`、`arch/arm/`(ARM32)、`arch/riscv/`、`arch/x86/`。架构相关代码都隔离在这里:页表布局(`pgtable.h`)、系统调用入口(`entry.S`/`syscall.c`)、上下文切换(`__switch_to`)、中断向量(`entry.S`)、TLB/缓存管理、per-arch 的 `Kconfig`/`Makefile`(定义本架构的配置选项和编译规则)。`mm/`/`kernel/`/`fs/`/`drivers/`(共用部分)里绝大多数代码架构无关,靠 `arch/<arch>/` 提供的接口工作。这就是"一份源码跑多架构"的实现方式——共用层 + 架构隔离层。

### 二、切换架构:`ARCH` + `CROSS_COMPILE`

编内核/模块时两个变量决定架构:

- **`ARCH=arm64`**(或 `arm`/`riscv`/`x86`):决定走 `arch/<arch>/`、用哪个 defconfig。
- **`CROSS_COMPILE=aarch64-linux-gnu-`**:决定工具链前缀(x86_64 本机编 x86 可省,交叉编必须)。

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- defconfig
# x86_64 本机编:
make ARCH=x86_64 defconfig
```

本站 [Makefile.arch](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/example/common/Makefile.arch) 按 `ARCH` 自动选对应 `CROSS_COMPILE` 和 `KDIR`,让模块编译一份 Makefile 跑多架构。

### 三、各架构的差异点

不同架构在内核里差异最明显的几处:

- **页表层级**:ARM64 通常 4 级(pgd/pud/pmd/pte),x86 看模式 4-5 级,RISC-V 看 sv39/sv48/sv57。
- **系统调用入口**:ARM64 `SVC` 指令 + `el0_svc`,x86 `SYSCALL`/`SYSENTER`,RISC-V `ecall`。
- **设备树 vs ACPI**:ARM/RISC-V 用设备树([drv-dts](../drivers/11-drv-dts.md)),x86 服务器用 ACPI,ARM64 服务器也可用 ACPI。
- **内核镜像格式**:`Image`(ARM64)、`bzImage`(x86)、`Image`(RISC-V)、启动入口不同。

写驱动/应用时多数情况不感知架构(走通用 API),但涉及页表/系统调用/启动入口时要分架构看。

### 四、多架构测试的价值

在多架构 QEMU 上跑同一套测试,能抓出"隐藏架构假设"的 bug(代码在某架构能跑、换个架构挂)——比如字节序(ARM64/x86 小端,RISC-V 可配)、对齐要求、指针大小。本站主线 ARM64,但若把 [example/mini/](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/example/mini/) 下的模块同时在 ARM32/RISC-V 上编跑,能验证它们是否真正可移植。

## 动手试试

1. `ls arch/` 看内核支持的所有架构目录;`make ARCH=arm64 help | head` 看本架构的构建目标
2. 装 RISC-V 工具链(`gcc-riscv64-linux-gnu`),`make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- defconfig && make`,编一个 RISC-V 内核,QEMU `-M virt -cpu rv64` 跑
3. 本站 `example/mini/00-kernel_module_hello/` 改成 `make ARCH=riscv`(用 Makefile.arch 的多架构支持),编出 RISC-V 的 hello.ko,跑 RISC-V QEMU 验证
4. 思考题:为什么内核能把"共用 + 架构相关"分开,让一份源码跑多架构?(提示:arch/ 隔离 + 通用层接口)

## 延伸阅读

- 关联本站:[01 交叉编译](./01-embed-cross-compile.md)、[02 mini config](../foundations/02-kernel-mini-config.md)/[03 编译内核](../foundations/03-kernel-build.md) 多架构切换;[Makefile.arch](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/example/common/Makefile.arch) 是本站多架构支持样板。
- 外部:kernel.org `Documentation/<arch>/`;各架构的 `arch/<arch>/Kconfig` 看本架构支持的选项。
