---
title: "QEMU 基础:加速器、机型、monitor 与常用选项"
slug: qemu-basics
prerequisites:
  - qemu-first-boot
difficulty: intermediate
tags: [qemu, tcg, kvm, monitor, snapshot, virtio]
architectures: [arm64, arm32, riscv, x86_64]
kernel_version: "6.19"
sources:
  - guide: scripts/qemu-run.sh、document/guides/
  - doc: QEMU 文档(qemu.org)
maturity: drafting
related:
  - /tutorials/foundations/05-qemu-first-boot
  - /tutorials/embedded/02-embed-qemu
  - /tutorials/foundations/06-gdb-debug-setup
---

> 🔨 **整理中** · 这一篇是 QEMU 的**选项速查/系统级总览**——[05 首次启动](./05-qemu-first-boot.md) 跑通了最小启动,这里把 QEMU 常用选项分类讲清:加速器(TCG vs KVM)、机型/CPU、内存/SMP、外设(串口/网/盘/9p)、调试(monitor/快照/GDB)。本站 `scripts/qemu-run.sh` 是这套的封装。

## 做什么

QEMU 是个庞大的仿真器,选项几百个,新手容易懵。这一篇把最常用的几十个按"用途"分类,给个速查表 + 解释"什么时候用哪个"。它和 [05 首次启动](./05-qemu-first-boot.md)(实战入门)、[02 embed-qemu](../embedded/02-embed-qemu.md)(嵌入式机型)互补:这篇是通用选项总览。

## 要了解什么

### 一、加速器:`-accel` / `-enable-kvm`

- **TCG(Tiny Code Generator)**:纯软件翻译执行,**跨架构可用**(x86 宿主跑 ARM64 Guest 靠它),慢。本站 x86 宿主跑 ARM64 Guest 走 TCG。
- **KVM**:硬件加速(Guest=Host 架构时),接近原生。`-enable-kvm` 或 `-accel kvm`。详见 [virt-kvm](../virtualization/02-virt-kvm.md)。
- `-accel help` 看支持哪些;`-accel kvm,thread=multi` 多线程 TCG 加速。

### 二、机型/CPU/内存/SMP

- **`-M <machine>`**:机型(ARM64 `virt`/`raspi3b`,x86 `q35`/`pc`,RISC-V `virt`)。`-M help` 列全部。
- **`-cpu <model>`**:CPU 型号(`cortex-a53`/`host`/`max`)。`-cpu help` 列全部。
- **`-m <size>`**:内存(`-m 1G`)。
- **`-smp <n>`**:CPU 核数(`-smp 4`)。

### 三、内核/设备树/启动参数

- **`-kernel <Image>`**:直接加载内核镜像(跳过 bootloader)。
- **`-dtb <file.dtb>`**:传自定义设备树(`virt` 机型默认自动生成)。
- **`-append "cmdline"`**:内核命令行(`root=... console=...`)。
- **`-initrd <file>`**:initramfs。
- **`-bios <u-boot.bin>`**:用 U-Boot 当 bootloader(替代 `-kernel` 直接加载)。

### 四、外设:串口/网络/磁盘/9p

- **串口**:`-serial mon:stdio`(串口接终端,monitor 复用)、`-nographic`(纯串口无图形)。
- **网络**:`-netdev user,id=n(hostfwd=tcp::2222-:22 端口转发) -device virtio-net-device,netdev=n`(user 模式 NAT + virtio 网卡)。
- **磁盘**:`-drive file=disk.img,if=virtio,format=raw`(virtio-blk 高性能磁盘)。
- **9p 共享**:`-virtfs local,path=/host/share,mount_tag=host0,security_model=mapped-xattr`(宿主- Guest 共享目录,本站 [08 9p](./08-kernel-module-9p-iteration.md) 用过,改 ko 免重打包)。

### 五、调试:monitor / 快照 / GDB

- **`-monitor stdio`**:QEMU monitor 命令行(交互控制 VM,如 `info registers`/`quit`/`savevm`)。
- **`-s -S`**:`-s` 开 gdbserver(1234 端口)、`-S` 启动时暂停(等 gdb 连接)——[06 gdb 调试](./06-gdb-debug-setup.md) 用。
- **快照**:`-snapshot`(临时,不写回镜像)、monitor 的 `savevm <tag>`/`loadvm <tag>`/`delvm`(虚拟机状态快照,调试可回退)。
- **`-d <item>`**:`-d guest_errors`/`int` 等调试输出。

### 六、本站的 qemu-run.sh

`scripts/qemu-run.sh`(本仓库)封装了 `virt` 机型 + ARM64 内核 + initramfs 的标准启动,带 `9P_*/QEMU_9P_*` 环境变量开关(9p 共享)、`debug` 命令(自动加 `-s -S` 和 `nokaslr`)。它就是这篇选项总览的实战落地——读它能看全套常用选项怎么组合。

## 动手试试

1. `qemu-system-aarch64 -M help | head` / `-cpu help | head` 看机型/CPU 清单
2. `-accel help` 看支持的加速器;`-enable-kvm`(若同架构)对比 TCG 速度
3. `-serial mon:stdio -nographic` 跑,练 monitor 命令(`Ctrl-A C` 切 monitor、`info registers`、`quit`)
4. 加 `-drive if=virtio` + `-device virtio-net-device`,在 Guest 里验证磁盘/网络
5. `-snapshot` 起动,改 rootfs 后重启看是否还原;`savevm`/`loadvm` 练快照
6. 思考题:为什么本站 ARM64 Guest 在 x86 宿主上不能用 `-enable-kvm`?(提示:KVM 只加速同架构)

## 延伸阅读

- 关联本站:[05 首次启动](./05-qemu-first-boot.md)、[06 gdb 调试](./06-gdb-debug-setup.md)(`-s -S`)、[08 9p](./08-kernel-module-9p-iteration.md)(9p 共享)、[02 embed-qemu](../embedded/02-embed-qemu.md)(嵌入式机型);本站 `scripts/qemu-run.sh` 是这套选项的封装。
- 外部:[QEMU 文档](https://www.qemu.org/docs/master/)(`system/` 各章节)、`man qemu-system-*`。
