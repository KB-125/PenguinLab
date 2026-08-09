---
title: "嵌入式内核配置:为资源受限板子裁剪内核"
slug: embed-kernel-config
prerequisites:
  - kernel-mini-config
  - embed-cross-compile
next:
  - embed-rootfs
difficulty: intermediate
tags: [embedded, kernel-config, footprint, size-optimization, slob, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch02.md
  - guide: configs/、document/guides/
maturity: drafting
related:
  - /tutorials/foundations/02-kernel-mini-config
  - /tutorials/embedded/01-embed-cross-compile
---

> 🔨 **整理中** · 这一篇讲**为嵌入式裁剪内核**——资源受限(几 MB RAM、慢 flash)的板子上,内核要尽量小、省内存、省电。素材从 ch02 + 本站 [02 mini config](../foundations/02-kernel-mini-config.md) 实战整理。本站的 `configs/arm64-qemu-virt-learn.config` 已经是裁剪思路的样板,这里系统化嵌入式裁剪的几个关键开关。

## 做什么

[02 mini config](../foundations/02-kernel-mini-config.md) 讲了"allnoconfig + merge_config + olddefconfig"这套从零搭最小内核的流程。嵌入式场景把这套用到极致——板子可能只有 8MB flash、64MB RAM,默认 defconfig 编出的内核(几 MB)+ 模块(几十 MB)根本塞不下。裁剪目标是:**内核镜像体积小、运行时内存占用低、按需关掉非必要子系统、省电**。这一篇列嵌入式常调的几类开关。

## 要了解什么

### 一、体积裁剪:去掉用不到的子系统

`make menuconfig` 进 `General setup` 和各子目录,关掉目标板用不到的:

- 不需要的文件系统(iso9660/XFS/btrfs...,只留 ext4/squashfs/tmpfs)
- 不需要的驱动(桌面外设、未用的网络协议 IPv6/DECnet...)
- 调试选项关掉([debug-bug-classification](../debugging/00-debug-bug-classification.md) 第二节那些 KASAN/Lockdep/KGDB 在生产嵌入式全关)
- `CONFIG_EMBEDDED`(暴露"为嵌入式"的额外裁剪选项)

### 二、size 优化:编译器 + slab 选择

- **`CONFIG_CC_OPTIMIZE_FOR_SIZE=y`**:用 `-Os`(优化体积)替代默认 `-O2`(优化性能),内核镜像显著变小(代价是性能略降,嵌入式可接受)。
- **`CONFIG_SLOB`**(替代 SLUB/SLAB):最小的 slab 分配器,省内存(代价:性能差、无 SLUB 的调试特性),适合小内存嵌入式。
- **`CONFIG_KERNEL_GZ`/`LZ4`/`XZ`**:内核镜像压缩(LZ4 解压快、XZ 压缩率高),用更小镜像换启动时多解压一下。

### 三、省电:CONFIG_NO_HZ + CPU 频率调节

电池/低功耗场景:

- **`CONFIG_NO_HZ_IDLE`/`NO_HZ_FULL`**:tickless(无任务时停周期 tick,省 CPU 唤醒功耗)。
- **`CONFIG_CPU_FREQ`** + 调速器(`ondemand`/`powersave`):动态调频,CPU 空闲时降频。
- **`CONFIG_PM`/`PM_SLEEP`**:电源管理 + 挂起到内存(suspend to RAM)。

### 四、内核内置 vs 模块

嵌入式常把所有需要的驱动**编译进内核**(`CONFIG_*_BUILTIN`/`=y` 而非 `=m`)——避免 rootfs 上还要存模块、避免启动时 `modprobe` 依赖。代价是内核镜像变大,但省了模块存储 + 简化启动。具体取舍看板子资源。

### 五、本站的 mini config 是样板

`configs/arm64-qemu-virt-learn.config`(本仓库)就是这套思路的产物——allnoconfig 起步,只开学习需要的(ARM64 virt + virtio + PL011 + ext4 + 必要驱动),442 项 vs defconfig 952 项。读它能看到"哪些是嵌入式/学习必须、哪些是可裁的"。

## 动手试试

1. `make ARCH=arm64 allnoconfig` 起步,`make ARCH=arm64 menuconfig` 一个个开需要的,对比最终 `.config` 项数和内核镜像大小
2. 开 `CONFIG_CC_OPTIMIZE_FOR_SIZE`,对比内核镜像大小(`ls -l arch/arm64/boot/Image`)
3. 开 `CONFIG_SLOB`,对比启动后 `/proc/meminfo` 的内核内存占用
4. 读本站 `configs/arm64-qemu-virt-learn.config`,理解每一项为什么开
5. 思考题:嵌入式为什么常把驱动编进内核(=y)而非模块(=m)?代价是什么?

## 延伸阅读

- 关联本站:[02 mini config](../foundations/02-kernel-mini-config.md) 裁剪流程、[03 编译内核](../foundations/03-kernel-build.md) 编译;`configs/arm64-qemu-virt-learn.config` 是本站的嵌入式裁剪样板。
- 外部:kernel.org `Documentation/admin-guide/README.rst` 的配置说明;`CONFIG_EMBEDDED` 的 Kconfig 说明;`make tinyconfig`(比 allnoconfig 更极简的起点)。
- 读书笔记:[ch02](../../notes/linux_kernel_programming/ch02.md) 讲内核配置流程。
