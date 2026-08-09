---
title: "BSP 项目:给一块板子搭完整 Linux 支持"
slug: embed-bsp-project
prerequisites:
  - embed-bootloader
  - embed-buildroot
  - drv-dts
difficulty: advanced
tags: [embedded, bsp, project, u-boot, device-tree, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
type: project
sources:
  - source: 综合 [01-06](./) embedded 藤 + [drivers/](../drivers/)
maturity: drafting
related:
  - /tutorials/embedded/06-embed-buildroot
  - /tutorials/drivers/11-drv-dts
---

> 🔨 **整理中** · 这一篇是 embedded 藤的**综合实战项目**——**BSP(Board Support Package,板级支持包)** 开发:给一块具体板子搭完整 Linux 支持(bootloader + 内核 + 设备树 + rootfs + 关键驱动),让它能跑起来、能跑应用。它是项目型节点,综合本藤前几篇 + drivers 藤。

## 项目目标

**BSP** 是"让某块具体硬件板跑上 Linux"的全部软件:配置 bootloader 引导它、移植/配置内核、写设备树描述板子硬件、构建 rootfs、为板子上的非标准外设写驱动。目标:拿一块新板子(QEMU 模拟的 virt、或一块真 SoC 板),走完"从零到能跑应用"的全流程,把前面学的交叉编译/QEMU/bootloader/kernel-config/rootfs/drivers 串起来用。

## 项目流程(典型 BSP 开发链)

**1. 硬件摸底**:板子用的 SoC 什么型号、内存多大、flash/eMMC 多大、有哪些外设(串口/网/SD/USB/GPIO)、有没有现成的厂商 BSP/参考代码。

**2. bootloader**:选 U-Boot,基于 SoC 厂商的 U-Boot 移植(或用 mainline U-Boot 的对应 SoC 支持)。配 `bootcmd`/`bootargs`,确认能从 SD/eMMC/网络加载内核。QEMU 虚拟板可省这步(用 QEMU `-kernel`)。

**3. 内核 + 设备树**:
- 交叉编内核(基于 SoC 厂商的 defconfig 或 mainline)。
- **写/改设备树**——这块板子的硬件描述(SoC 的设备树骨架 + 板子上的外设节点),这是 BSP 的核心工作之一([drv-dts](../drivers/11-drv-dts.md))。设备树错了,内核认不出硬件。

**4. rootfs**:用 Buildroot([06](./06-embed-buildroot.md))构建完整 rootfs(BusyBox + libc + 你的应用),或从厂商 BSP 拿。

**5. 关键驱动**:板子上有"mainline 内核还没支持"的外设,自己写驱动(platform/USB/...,[drivers 藤](../drivers/))。把外设的 compatible 加进设备树 + 写驱动 probe。

**6. 集成测试 + 烧录**:把 bootloader/kernel/rootfs 烧进 flash/eMMC(QEMU 里直接加载),板上电,串口看启动、shell 验证外设。

## 用 QEMU virt 当 BSP 练手

真实板子 BSP 开发的每个环节,都能在 QEMU `virt` 机型上练:

- "bootloader":跑 U-Boot on QEMU(`-bios u-boot.bin`),[03 bootloader](./03-embed-bootloader.md)
- "设备树":QEMU 导出 dtb + 加自定义节点 + 写 platform 驱动匹配,[drv-dts](../drivers/11-drv-dts.md)/[drv-platform](../drivers/10-drv-platform.md)
- "内核":交叉编 + 裁剪 + 加自定义配置,[04 kernel-config](./04-embed-kernel-config.md)
- "rootfs":Buildroot 构建 QEMU virt 的 rootfs,[06 Buildroot](./06-embed-buildroot.md)

本站学习环境(`configs/` + `scripts/qemu-run.sh`)其实就是一个"QEMU virt 板的简易 BSP"——它有内核配置、设备树(QEMU 自动生成 + 你可改)、rootfs(手搓 BusyBox)、bootloader(用 QEMU `-kernel` 跳过)。理解这套,迁移到真板 BSP 就是把每环换成对应板子的实现。

## 动手试试

1. 把本站 `configs/arm64-qemu-virt-learn.config` + `scripts/qemu-run.sh` 当"QEMU virt BSP"完整跑通(本藤 01-06 都用过),理解每环
2. 在 QEMU 设备树里加一个自定义外设节点(如 `penguinlab,led-demo`),写 platform 驱动匹配它、在 sysfs 暴露属性——走完 BSP 的"设备树 + 驱动"环节
3. 用 Buildroot 构建一个完整 QEMU virt 系统(替代本站手搓),对比两套 rootfs
4. 若有真板(树莓派/BeagleBone/某 SoC 板),尝试给它搭 BSP(从厂商 BSP 起步改设备树/配置),对照本篇流程
5. 思考题:BSP 里"设备树"为什么是核心环节?(提示:内核认硬件全靠它)

## 延伸阅读

- 关联本站:本篇综合 embedded 藤([01-06](./)) + [drivers/10 platform](../drivers/10-drv-platform.md)/[11 dts](../drivers/11-drv-dts.md);本站 `configs/` + `scripts/` 是"QEMU virt BSP"样板。
- 外部:各 SoC 厂商的 BSP 文档(如 TI/Rockchip/NXP/Xilinx);`Documentation/arm`/`riscv`/`arm64` 的板子移植指南;U-Boot/Linux mainline 对各板的 `board/<vendor>/` 目录。
