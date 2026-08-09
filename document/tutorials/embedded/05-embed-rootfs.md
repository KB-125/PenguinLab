---
title: "嵌入式 rootfs:从 BusyBox 到 Buildroot/Yocto"
slug: embed-rootfs
prerequisites:
  - embed-kernel-config
  - busybox-rootfs
next:
  - embed-buildroot
difficulty: intermediate
tags: [embedded, rootfs, busybox, initramfs, buildroot, yocto, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch04.md
  - guide: scripts/rootfs-minimal-maker.sh
maturity: drafting
related:
  - /tutorials/foundations/04-busybox-rootfs
  - /tutorials/embedded/06-embed-buildroot
---

> 🔨 **整理中** · 这一篇讲**嵌入式 rootfs**——内核启动后挂载的根文件系统。素材从 ch04 + 本站 [04 BusyBox rootfs](../foundations/04-busybox-rootfs.md) 实战整理。本站用 `scripts/rootfs-minimal-maker.sh` 手搓 BusyBox rootfs,这里对比嵌入式 rootfs 的几种构建方式:手搓 BusyBox(学习用)、Buildroot(小系统生产用)、Yocto(复杂产品级)。

## 做什么

内核启动后要挂一个根文件系统才能跑 init、起 shell、跑应用——这就是 rootfs。[04 BusyBox rootfs](../foundations/04-busybox-rootfs.md) 里我们手搓了一个:BusyBox(提供 shell + Unix 工具)+ 静态或动态 libc + 最小 `/etc` init 脚本,打包成 initramfs。这种手搓方式适合学习、适合超小系统,但真实嵌入式产品里 rootfs 要包含**完整的应用、库、配置、固件、init 系统(systemd/BusyBox init)**,手动拼不现实——所以有 **Buildroot**(自动化构建整个嵌入式 Linux 系统)和 **Yocto**(更复杂、产品级的发行版构建器)。这一篇对比这几种方式。

## 要了解什么

### 一、initramfs vs 持久 rootfs

- **initramfs**(本站用的方式):rootfs 打包成 `cpio.gz`,内核启动时解到内存(RAM-based)——**只读快照**(改了重启丢)、占 RAM。适合学习、小系统、或"真正 rootfs 加载前的过渡"。
- **持久 rootfs**:rootfs 是真实的块设备分区(ext4/squashfs),挂载、可写、持久。真实产品用这个——rootfs 在 flash/eMMC 上,改动持久保留。需要内核支持该文件系统 + 启动参数 `root=/dev/mmcblk0p2` 指向它。

本站 initramfs 是学习选择;真实板子多走持久 rootfs(ext4 on eMMC,或 squashfs 只读 + overlayfs 可写层)。

### 二、BusyBox:rootfs 的"瑞士军刀"

**BusyBox** 把 shell(`ash`)、coreutils(ls/cat/cp/...)、util-linux(mount/umount/...)、`init`、`udhcpc` 等几十个 Unix 工具**集成进一个二进制**(用 `applet` 机制,符号链接),体积几 MB——是嵌入式 rootfs 的标配。本站 [04 BusyBox rootfs](../foundations/04-busybox-rootfs.md) 就是手搓这套:编 BusyBox + 最小 `/etc/{inittab,init.d/rcS,profile,fstab}` + 打包 cpio。学习 rootfs 内部结构用它最清楚。

### 三、Buildroot:自动化构建整套嵌入式系统

[**Buildroot**](https://buildroot.org) 用一个 `.config`(类似内核 menuconfig)描述"目标系统长什么样"——选 CPU 架构、工具链、内核版本、BusyBox/系统库/应用、init 系统——`make` 后**自动交叉编出全套**:工具链、内核镜像、rootfs(各种格式 cpio/ext4/squashfs/ubi)、甚至 bootloader。它解决了"手搓 rootfs 拼不齐应用和库"的痛点,是小到中型嵌入式系统的首选。下一篇 [06 Buildroot](./06-embed-buildroot.md) 专讲。

### 四、Yocto:产品级发行版构建器

[**Yocto**](https://www.yoctoproject.org)/OpenEmbedded 更复杂——它不只是"构建一个 rootfs",而是一套**完整的嵌入式 Linux 发行版构建框架**:用 `bitbake` + recipe 描述每个组件,支持包管理(rpm/deb/ipk)、镜像变体、SDK 生成、长期维护、多板子 BSP 管理。学习曲线陡,但产品级嵌入式(手机/IoT/工业)多用它——可维护性、可定制性、商业支持都强。学习/小系统用 Buildroot 够,产品级多发行版变体选 Yocto。

### 五、选型

| 场景 | 选择 |
|:--|:--|
| 学习 rootfs 原理 | 手搓 BusyBox(本站 [04](../foundations/04-busybox-rootfs.md)) |
| 小系统、单一镜像 | Buildroot |
| 产品级、多变体、需包管理、长期维护 | Yocto |
| 仅启动一个简单应用 | initramfs + BusyBox(本站方式) |

## 动手试试

1. 复习本站 [04 BusyBox rootfs](../foundations/04-busybox-rootfs.md) 的手搓流程,理解 rootfs 每个目录(`/bin`/`/sbin`/`/etc`/`/lib`)放什么
2. 改 `rootfs-minimal-maker.sh` 打包出一个**持久** ext4 rootfs 镜像(不用 cpio initramfs),QEMU `-drive` 挂载,验证改动持久
3. 下载 Buildroot,`make qemu_aarch64_virt_defconfig && make`,跑它生成的 rootfs(下一篇详讲)
4. 思考题:initramfs 和持久 rootfs 各适合什么场景?(提示:只读快照 vs 持久可写)

## 延伸阅读

- 关联本站:[04 BusyBox rootfs](../foundations/04-busybox-rootfs.md) 手搓、[05 QEMU 启动](../foundations/05-qemu-first-boot.md) 挂载 rootfs;下一篇 [06 Buildroot](./06-embed-buildroot.md) 自动化构建;本站 `scripts/rootfs-minimal-maker.sh`。
- 外部:[Buildroot](https://buildroot.org)、[Yocto Project](https://www.yoctoproject.org)、BusyBox 项目。
- 读书笔记:[ch04](../../notes/linux_kernel_programming/ch04.md) 讲 rootfs 与模块加载。
