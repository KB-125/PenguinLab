---
title: "嵌入式 QEMU:模拟真实硬件板"
slug: embed-qemu
prerequisites:
  - qemu-first-boot
  - embed-cross-compile
next:
  - embed-bootloader
difficulty: intermediate
tags: [embedded, qemu, virt-machine, arm64, arm32, device-tree]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - guide: document/guides/、scripts/qemu-run.sh
maturity: drafting
related:
  - /tutorials/foundations/05-qemu-first-boot
  - /tutorials/embedded/01-embed-cross-compile
---

> 🔨 **整理中** · 这一篇讲**用 QEMU 模拟嵌入式板**——比 [05 QEMU 首次启动](../foundations/05-qemu-first-boot.md) 更深入:`-M` 选机型、`-cpu` 选 CPU、`-dtb` 传设备树、加外设(串口/网/盘),以及"virt 机型为什么是嵌入式学习首选"。本站 `scripts/qemu-run.sh` 就是这套的封装。

## 做什么

[05 QEMU 启动](../foundations/05-qemu-first-boot.md) 里我们用 QEMU `virt` 机型跑了 ARM64 内核 + BusyBox。但 QEMU 能模拟的板子远不止 virt——它能模拟真实存在的硬件板(vexpress、raspi3b、riscv-virt、xilinx-zynq 等),每块"板"有特定的 CPU、内存布局、外设(串口/网卡/磁盘控制器/中断控制器)。开发嵌入式时,手头没真板,QEMU 模拟一块足够接近的板子就能开发/调试。这一篇讲怎么选机型、配外设、传设备树,以及为什么本站学习环境固定用 `virt`。

## 要了解什么

### 一、QEMU 机型(`-M`)

`qemu-system-aarch64 -M <machine>` 选要模拟的板。ARM64 常用:

- **`virt`**:QEMU 的"通用 ARM64 虚拟机"——不对应任何真实板,但外设简单规范(PL011 串口/GIC 中断控制器/virtio 设备),是**学习/开发的首选**(本站就用它)。它支持任意 CPU 核数、大内存,设备树由 QEMU 自动生成。
- **`raspi3b`/`raspi4b`**:树莓派 3/4,Broadcom SoC,可跑树莓派官方内核/用户态。
- **`xilinx-zynq-a9`**:Xilinx Zynq(ARM32 + FPGA),工业/嵌入式常见。
- **`vexpress-a9`/`vexpress-a15`**:ARM Versatile Express,老牌开发板,LDD3/很多教程用它。

`-M help` 列全部。选机型取决于目标——学 ARM64 内核通用机制用 virt 最省心;要复现某块真板的行为用对应机型。

### 二、CPU(`-cpu`)+ SMP(`-smp`)+ 内存(`-m`)

- `-cpu cortex-a53`/`cortex-a72`/`cortex-a76`/`max`:选 CPU 型号(`max` = 启用所有该架构特性,开发常用)。
- `-smp 4`:4 核(测 SMP 调度/负载均衡用,[sched-load-balance](../kernel/sched/05-sched-load-balance.md))。
- `-m 1G`:1GB 内存。

### 三、外设:串口/网络/磁盘/设备树

- **串口**:`-serial mon:stdio`(串口接终端,本站常用)、`-nographic`(纯串口,无图形窗口)。
- **网络**:`-netdev user,id=net0 -device virtio-net-device,netdev=net0`(user 模式 NAT 网络 + virtio 网卡,Guest 能 ping 出去)。
- **磁盘**:`-drive file=disk.img,if=virtio,format=raw`(virtio-blk 磁盘,跑 ext4 等)。
- **设备树**:`virt` 机型的设备树由 QEMU 自动生成;要用自定义设备树(加自定义节点,关联 [drv-dts](../drivers/11-drv-dts.md)),`-machine virt,dumpdtb=virt.dtb` 导出 → `dtc` 反编译改 → `-machine virt,dtb=virt.dtb` 传回。
- **GDB 调试**:`-s -S`(开 gdbserver + 启动暂停,关联 [06 gdb](../foundations/06-gdb-debug-setup.md))。

### 四、为什么本站用 virt 机型

`virt` 的优势:外设规范简单(不模拟某真实芯片的怪癖)、设备树自动生成、virtio 设备性能好(不依赖真实硬件驱动)、CPU/内存/SMP 可任意配。对**学内核机制**(调度/mm/fs/驱动框架)来说,virt 够用且省心——不用和某块真实板的硬件特性纠缠。只有当你研究"某 SoC 的特定硬件"(如树莓派的 GPU、Zynq 的 FPGA)时,才换对应机型。本站 `scripts/qemu-run.sh` 封装了 virt 机型的标准启动参数。

## 动手试试

1. `qemu-system-aarch64 -M help` 看所有 ARM64 机型;`-cpu help` 看 CPU 型号
2. `-smp 4 -m 2G` 启动 4 核 2G 的 virt,Guest 里 `nproc`/`free -h` 确认
3. `-machine virt,dumpdtb=virt.dtb` 导出设备树,`dtc -I dtb -O dts virt.dtb` 反编译看结构(关联 [drv-dts](../drivers/11-drv-dts.md))
4. 加 virtio-blk 磁盘(`-drive file=disk.img,if=virtio`)、virtio-net(`-device virtio-net-device`),Guest 里 `fdisk -l`/`ip link` 验证
5. 思考题:学内核机制用 virt 机型,为什么不直接模拟某块真实板?(提示:外设简单 + 可任意配 + 不被硬件怪癖分心)

## 延伸阅读

- 关联本站:[05 QEMU 首次启动](../foundations/05-qemu-first-boot.md) 基础、[06 gdb 调试](../foundations/06-gdb-debug-setup.md) `-s -S`、[drv-dts](../drivers/11-drv-dts.md) 设备树;本站 `scripts/qemu-run.sh` 是 virt 机型的封装参考。
- 外部:QEMU 文档 `qemu.1`/`docs/system/arm/virt.rst`;`-machine virt,dumpdtb` 是 6.x 起的标准设备树导出法。
