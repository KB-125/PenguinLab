---
title: "用 BusyBox 构建最小根文件系统"
prerequisites:
  - kernel-build
next:
  - qemu-first-boot
difficulty: beginner
tags: [busybox, rootfs, initramfs, cpio, arm64]
architectures: [arm64]
kernel_version: "6.19"
maturity: verified
---

## 做什么

内核编译好了，但光有内核是没法用的——内核启动后需要一个根文件系统（rootfs）来提供基本的用户态环境，至少得有个 shell 让我们敲命令吧。这篇我们用 BusyBox 构建一个最小的 rootfs，把它打包成 cpio.gz 格式的 initramfs 镜像，作为内核启动时的初始内存盘。完成之后我们就有了启动所需的全部材料：一颗编译好的内核 + 一个打包好的根文件系统。

## 要了解什么

### 为什么是 BusyBox

BusyBox 是嵌入式 Linux 世界的瑞士军刀——它把 `ls`、`cat`、`sh`、`mount`、`cp`、`mv` 等几十个标准 Linux 工具打包成一个单一的二进制文件，通过符号链接的方式让每个"命令"都指向同一个 busybox 可执行文件。这样做的好处是极大地节省了存储空间，整个用户态工具集只需要几百 KB，非常适合 initramfs 这种容量敏感的场景。

我们的 rootfs 不需要是一个功能完备的 Linux 发行版，它只需要做到一件事：启动之后给我们一个可以交互的 shell，让我们能跑 `uname -a`、`cat /proc/cpuinfo`、`ls /sys/` 这些基本命令来验证内核功能。BusyBox 完全满足这个需求。

（插一个小广告：笔者自己Vibe Coding过一个类似BusyBox的最小core-binutils，叫CFBox，Github这边请：https://github.com/Awesome-Embedded-Learning-Studio/CFBox）


### 构建 rootfs

项目提供了一个自动化脚本 [rootfs-minimal-maker.sh](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/scripts/rootfs-minimal-maker.sh) 来处理整个 rootfs 构建流程。它的核心工作包括：编译 BusyBox（静态链接）、创建 rootfs 目录结构（`bin/`、`sbin/`、`usr/`、`proc/`、`sys/`、`dev/` 等）、安装 BusyBox 的符号链接、生成 `/init` 启动脚本。运行方式是：

```bash
ARCH=aarch64 ./scripts/rootfs-minimal-maker.sh defconfig
```

这里 `ARCH=aarch64` 很重要，它决定了编译出来的 BusyBox 是 ARM64 版本的。如果忘了设 `ARCH`，脚本不会报错，但会把 rootfs 输出到一个路径异常的目录（`out/build_latest_/rootfs/`——注意那个空的下划线，就是因为 `ARCH` 为空导致的），而且编译出来的 BusyBox 可能是 x86 架构的。这个坑我们实际踩过，排查起来还挺隐蔽的。

构建完成后检查一下 rootfs 目录：

```bash
ls out/build_latest_arm64/rootfs/
# bin/  dev/  etc/  init*  proc/  sbin/  sys/  usr/
```

一个能启动的最小 rootfs 需要这些目录和文件。`bin/` 和 `sbin/` 下面是 BusyBox 的符号链接，`init` 是内核启动后执行的第一个用户态程序。

### /init：内核启动后的第一个用户态程序

内核在完成硬件初始化之后，会去执行根文件系统里的 `/init` 程序（如果内核命令行指定了 `rdinit=/init` 的话）。我们的 `/init` 是一个简单的 shell 脚本，做的事情很直白：挂载 `/proc`、`/sys`、`/dev`（devtmpfs），然后启动一个交互式 shell。

```bash
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
exec /bin/sh
```

这里每一行都有它的必要性。`/proc` 提供进程信息和内核参数接口，`/sys` 提供设备模型和驱动信息，`/dev` 提供设备节点（比如 `/dev/console`、`/dev/null` 等）。如果忘了挂载 `/dev`， BusyBox 的 shell 启动时会抱怨 `can't access tty`，虽然 shell 还是能起来，但会少一些功能（比如 job control）。

### 打包成 cpio.gz

QEMU 需要的 initrd 镜像是 cpio 格式的归档文件，而且必须是 `newc` 格式——这是内核 initramfs 的标准格式。我们的构建脚本已经内置了打包步骤，但如果你需要手动打包（比如修改了 rootfs 内容），命令如下：

```bash
cd out/build_latest_arm64/rootfs
find . -print0 | cpio --null -ov --format=newc | gzip -9 > ../rootfs.cpio.gz
```

拆解一下这条管道命令：`find . -print0` 递归列出 rootfs 下所有文件，用 null 字节分隔（处理文件名中的空格和特殊字符）；`cpio --null -ov --format=newc` 读取这些路径，打包成 newc 格式的 cpio 归档；`gzip -9` 用最大压缩比压缩，最终产出一个大约 1MB 的 `rootfs.cpio.gz` 文件。

> **别给 `cpio` 加 `2>/dev/null`。** 这是本站真踩过的坑：宿主机没装 `cpio` 时，shell 会报 `cpio: command not found`，但 `2>/dev/null` 把这个错误吞掉了，`gzip` 照样把「空输入」压成一个 **20 字节的合法 gzip**——文件在、`gzip -t` 也通过，打包"成功"得毫无破绽。直到启动内核才暴露：

```text
Unpacking initramfs...
Initramfs unpacking failed: junk at the end of compressed archive
check access for rdinit=/init failed: -2, ignoring
Kernel panic - not syncing: VFS: Unable to mount root fs on "/dev/ram0" or unknown-block(0,0)
```

内核的 initramfs 解析器只有在读到 cpio 的 `TRAILER!!!` 记录后才会把状态置为完成；空归档里没有这条记录，于是整份数据被丢弃，`/init` 不存在，内核只能回退去挂 `root=/dev/ram0`（而这颗最小内核根本没有块设备驱动）。所以打包完先自检：

```bash
ls -lh ../rootfs.cpio.gz                     # 约 1MB 才正常，20 字节就是空包
gzip -l ../rootfs.cpio.gz                    # uncompressed 一栏不能是 0
gzip -dc ../rootfs.cpio.gz | head -c 6       # 应以 cpio newc 头 070701 开头
```

本项目的 `rootfs-minimal-maker.sh` 已经把这些检查做进打包流程：打包前确认 `cpio` 存在、不吞 stderr、打包后校验 gzip 格式与 cpio 尾部记录，任何一步不过就报错退出，不会再产出"看起来成功"的空包。

为什么用静态链接？BusyBox 编译时我们选择了静态链接（`CONFIG_STATIC=y`），这意味着 BusyBox 的可执行文件包含了所有需要的 C 库函数，不依赖任何外部共享库（`.so` 文件）。在 initramfs 场景下这是必要的，因为我们的 rootfs 里没有 `/lib/` 目录——如果 BusyBox 是动态链接的，内核启动后执行 `/init` 时会找不到动态链接器（`ld-linux-aarch64.so.1`），直接报错退出。

## 动手试试

1. 运行 `ARCH=aarch64 ./scripts/rootfs-minimal-maker.sh defconfig` 构建 rootfs
2. 检查 `out/build_latest_arm64/rootfs/init` 文件是否存在且有执行权限（`ls -l`）
3. 用 `file out/build_latest_arm64/rootfs/bin/busybox` 确认 BusyBox 是 ARM64 架构的静态链接二进制
4. 检查 `out/build_latest_arm64/rootfs.cpio.gz` 是否已生成，用 `ls -lh` 查看大小

## 延伸阅读

- [rootfs-minimal-maker.sh](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/scripts/rootfs-minimal-maker.sh) — rootfs 构建脚本，特别是 `setup_rootfs()` 函数展示了最小 rootfs 需要哪些目录和文件
- [BusyBox 官方网站](https://busybox.net/) — BusyBox 项目主页和文档
