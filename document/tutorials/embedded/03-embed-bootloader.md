---
title: "bootloader:U-Boot 与嵌入式启动链"
slug: embed-bootloader
prerequisites:
  - embed-qemu
  - qemu-first-boot
next:
  - embed-kernel-config
difficulty: intermediate
tags: [embedded, bootloader, u-boot, spl, bootcmd, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - source: U-Boot 项目(本仓库不含),通用嵌入式启动流程
maturity: drafting
related:
  - /tutorials/embedded/02-embed-qemu
  - /tutorials/foundations/05-qemu-first-boot
---

> 🔨 **整理中** · 这一篇讲**嵌入式 bootloader**——内核启动之前的那段引导代码,以 **U-Boot**(嵌入式最主流)为核心。它解决"上电后,内核镜像怎么被加载进内存、怎么被启动、怎么拿到设备树和命令行参数"。本站用 QEMU `-kernel` 直接加载内核,跳过了 bootloader,但真实板子上 bootloader 是必经一环。

## 做什么

[05 QEMU 启动](../foundations/05-qemu-first-boot.md) 里 QEMU 用 `-kernel Image -append "..."` 直接把内核加载进内存、传参数,跳过了"bootloader 怎么加载内核"这步。可真实 ARM/RISC-V 板子上电时,内核还躺在 flash/SD/eMMC 里,得有段代码先把它读进内存、配置好硬件、再把控制权交给它——这就是 **bootloader** 的活。嵌入式世界 bootloader 的事实标准是 **U-Boot**(还有 barebox、各家厂商闭源的 ROM bootloader)。这一篇讲 bootloader 在启动链里的位置、U-Boot 的阶段划分、它怎么加载并启动内核。

## 要了解什么

### 一、嵌入式启动链:ROM → SPL → U-Boot → kernel

一块板上电后的典型启动链是多级的:

1. **ROM Bootloader(BL1)**:固化在芯片内 ROM 的厂商代码(不可改),上电最先跑,做最基本硬件初始化,然后从 SD/eMMC/NAND/网络读下一级 bootloader 到内存。
2. **SPL(Secondary Program Loader)**:U-Boot 的"精简版"(体积小,跑在 SRAM,初始化 DDR 内存、加载完整 U-Boot)。规模太小放不下完整 U-Boot 时,SPL 当跳板。
3. **U-Boot(main)**:完整 bootloader,跑在 DDR 里,提供交互式命令行(可人工干预)、网络/文件系统能力、`bootm`/`bootz` 加载启动内核。
4. **Linux kernel**:U-Boot 把内核镜像 + 设备树 + initramfs 加载进内存、配置好寄存器、`bootm` 跳进去,内核开始跑([05 启动](../foundations/05-qemu-first-boot.md) 讲的内核启动阶段从这里开始)。

每级"信任链"递进——ROM 信任 SPL、SPL 信任 U-Boot、U-Boot 信任内核。Secure Boot 场景每级都验签。

### 二、U-Boot 的启动:bootcmd + bootargs

U-Boot main 的核心是 `bootcmd` 环境变量——它定义"自动启动时执行什么命令"。典型:

```
bootcmd=load mmc 0:1 ${kernel_addr_r} /boot/Image; \
        load mmc 0:1 ${fdt_addr_r} /board.dtb; \
        load mmc 0:1 ${ramdisk_addr_r} /boot/initramfs.cpio.uboot; \
        booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
```

这段从 SD 卡第 1 分区加载内核镜像、设备树、initramfs 到内存,然后 `booti`(ARM64 Image 的启动命令)/`bootm`(老 uImage)跳进内核。`bootargs` 环境变量是传给内核的命令行(`console=ttyAMA0 root=/dev/mmcblk0p2 ...`),U-Boot 启动内核时一并传。

### 三、U-Boot 交互式命令行

启动时按键打断自动 boot,进 U-Boot 命令行,能手动操作:`printenv`/`setenv`(看/设环境变量)、`load`/`tftp`(从 SD/网络加载)、`md`(看内存)、`bootm`/`booti`(启动)、`saveenv`(保存环境)。这套命令行是 bootloader 调试的核心——能单独测每一步(加载对不对、设备树对不对、参数对不对),再让它自动跑。

### 四、设备树与内核启动

ARM64 的 U-Boot 启动内核时必须传**设备树**(`fdt_addr_r`)——内核靠它知道硬件(关联 [drv-dts](../drivers/11-drv-dts.md))。这是 ARM64 相对 ARM32 的一个大变化:ARM32 内核启动时还能用老的板级文件(`machine_desc`),ARM64 完全依赖设备树。U-Boot 的 `booti <kernel> <initrd> <fdt>` 三参数就是把内核、initramfs、设备树三个的地址传进去。

## 动手试试

1. QEMU 里跑 U-Boot:`qemu-system-aarch64 -M virt -bios u-boot.bin`(或 `-machine virt,u-boot`),进 U-Boot 交互命令行,练 `printenv`/`version`/`help`
2. U-Boot 命令行里手动 `load` 一个内核镜像 + 设备树,`booti` 启动,体会本篇第二节 bootcmd 的每一步
3. `tftpboot` 从宿主机 TFTP 加载内核(配 `qemu user net` + 宿主 tftpd),测网络启动
4. 思考题:为什么 ARM64 启动内核必须传设备树,而 QEMU `-kernel` 不用?(提示:QEMU `-kernel` 模式自动生成并传设备树;真板要 U-Boot 传)

## 延伸阅读

- 关联本站:[05 QEMU 启动](../foundations/05-qemu-first-boot.md) 内核启动阶段、[drv-dts](../drivers/11-drv-dts.md) 设备树;本站用 QEMU `-kernel` 跳过 bootloader,这篇讲的是"真实板"的链。
- 外部:[U-Boot 项目](https://www.denx.de/wiki/U-Boot/)、`README`/`doc/`;barebox 是另一个开源 bootloader;各 SoC 厂商的 ROM boot 文档(如 NXP/ST/Rockchip 的 boot flow reference)。
