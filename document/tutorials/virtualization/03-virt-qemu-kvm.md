---
title: "QEMU + KVM:用户态仿真 + 内核加速的配合"
slug: virt-qemu-kvm
prerequisites:
  - virt-kvm
next:
  - virt-project
difficulty: advanced
tags: [virtualization, qemu, kvm, tcg, virtio, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/virt/kvm/
  - source: QEMU 项目(本仓库不含 QEMU 用户态源码)
maturity: drafting
related:
  - /tutorials/virtualization/02-virt-kvm
  - /tutorials/foundations/05-qemu-first-boot
---

> 🔨 **整理中** · 这一篇讲 **QEMU 和 KVM 怎么配合**——QEMU 当"VM 外壳"(设备仿真 + 主循环),KVM 当"加速器"(vCPU/内存直接跑在硬件)。素材综合 [02 KVM](./02-virt-kvm.md) + QEMU 工作模型。本站用 QEMU 跑 ARM64 Guest,在 x86 宿主上走 TCG(纯仿真)——这篇解释"什么时候能用 KVM、什么时候只能 TCG"。

## 做什么

[02 KVM](./02-virt-kvm.md) 讲了 KVM 提供"vCPU + 内存加速",但 KVM 不仿真设备(磁盘/网卡/显卡)。**QEMU** 补这块——它是用户态进程,仿真 Guest 看到的全套虚拟硬件,并主导 VM 的主循环。两者配合:QEMU 用 KVM 的 `/dev/kvm` ioctl 让 Guest 的 CPU/内存指令在硬件上飞跑,设备访问由 QEMU 仿真。这一篇拆这套配合:QEMU 的启动流程、主循环(Guest 跑↔陷出处理)、TCG vs KVM 的选择。

## 要了解什么

### 一、QEMU 的启动:打开 KVM + 创建 VM

QEMU 启动一个 KVM-accelerated VM 的大致流程:

1. `open("/dev/kvm")` → 拿到 KVM fd。
2. `KVM_CREATE_VM` → 创建 VM,拿 vm fd。
3. `KVM_SET_USER_MEMORY_REGION`(多次)→ 把 QEMU 进程的几段用户态内存注册为"Guest 物理地址空间"(Guest 看到的内存,实际是 QEMU 的 mmap 内存)。
4. `KVM_CREATE_VCPU`(每核一个)→ 创建 vCPU,拿 vcpu fd。
5. 初始化 vCPU 寄存器(设 Guest 的入口 PC、加载内核镜像到 Guest 物理内存)。
6. 进入主循环(下一节)。

这整套"VM 生命周期"由 QEMU 主导,KVM 在背后提供加速。QEMU 命令行 `-enable-kvm` 就是让 QEMU 用这套 KVM ioctl 路径;不带的走 TCG(下一节)。

### 二、主循环:Guest 跑 ↔ 陷出处理

QEMU 的 VM 主循环核心是"反复 `KVM_RUN`":

- `KVM_RUN(vcpu)` → KVM 切到 Guest 模式跑(Guest 的 CPU/内存指令在硬件上飞跑)。
- Guest 执行到 IO 访问(读虚拟磁盘/网卡/MMIO)/`HLT`/异常 → 陷出,`KVM_RUN` 返回。
- QEMU 看 `KVM_RUN` 的返回原因(IO/异常/HLT)→ **仿真对应设备**(如 Guest 读虚拟串口,QEMU 把对应字节填给它)→ 处理完再 `KVM_RUN` 继续 Guest。

这样 QEMU 只在"Guest 陷出"时干活(仿真设备),其余时间 Guest 在硬件上自跑——开销小。设备仿真的开销取决于 Guest 访问设备的频率(高频访问 → 频繁陷出 → 慢),这正是为什么有 **virtio**:virtio 设备是"Guest 和 QEMU 协议化通信"的设备,大幅减少陷出(关联 [14 netdev](../drivers/14-drv-netdev.md)/[13 block](../drivers/13-drv-block.md) 的 virtio-net/virtio-blk)。

### 三、TCG vs KVM:何时用哪个

- **KVM 加速**(`-enable-kvm`):Guest 跑在硬件 vCPU 上,接近原生。**前提:Guest 架构 = Host 架构**(x86_64 Host 跑 x86_64 Guest;ARM64 Host 跑 ARM64 Guest——靠 ARM 的 VHE)。本站 x86 宿主跑 ARM64 Guest,**不能用 KVM**(架构不同,KVM 只加速同架构)。
- **TCG(Tiny Code Generator,纯仿真)**:QEMU 把 Guest 指令**翻译**成 Host 指令执行,跨架构可用(本站情境),但慢(每条 Guest 指令要翻译 + 无硬件加速)。

所以本站 ARM64 学习环境跑在 TCG 上(慢但跨架构);若你的机器是 ARM64(树莓派/Mac M 系列),跑 ARM64 Guest 能用 KVM(快)。

### 四、virtio:减少陷出的高性能设备

传统 QEMU 设备仿真(仿真某真实硬件)每次 Guest 访问都陷出 → QEMU 仿真 → 返回,高频设备(磁盘/网络)性能差。**virtio** 是"Guest 驱动 + QEMU 后端"配合的协议化虚拟设备:Guest 用 virtio 驱动(简化、批量、共享内存队列)和 QEMU 后端通信,大幅减少陷出次数、提升性能。本站 [13 block](../drivers/13-drv-block.md)/[14 netdev](../drivers/14-drv-netdev.md) 的 virtio-blk/virtio-net 就是这套。

## 动手试试

1. x86_64 宿主:`qemu-system-x86_64 -enable-kvm -cpu host ...`(同架构 Guest)开 KVM;`-accel help` 看 QEMU 支持的加速器
2. 对比 `-enable-kvm`(快)和不带(走 TCG,慢)的启动速度
3. QEMU 启动带 `-d`(调试选项,如 `-d guest_errors`)看 Guest 的设备访问陷出
4. 加 virtio 设备(`-drive if=virtio`/`-device virtio-net-pci`),对比仿真设备的性能
5. 思考题:为什么本站 ARM64 Guest 在 x86 宿主上不能用 KVM?(提示:KVM 只加速同架构,CPU 指令集不同)

## 延伸阅读

- 关联本站:本篇是 [02 KVM](./02-virt-kvm.md) 的 QEMU 侧展开;[05 QEMU 启动](../foundations/05-qemu-first-boot.md) 本站 QEMU 实战;virtio 设备见 [13 block](../drivers/13-drv-block.md)/[14 netdev](../drivers/14-drv-netdev.md)。
- 外部:[QEMU 文档](https://www.qemu.org/docs/master/)(TCG/virtio/KVM 加速);kernel.org [virt/kvm](https://docs.kernel.org/virt/kvm/)。
