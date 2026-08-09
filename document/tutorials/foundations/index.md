---
title: 通识基础
description: 从环境搭建到内核模块,一条线打通内核开发入门
maturity: verified
---

# 通识基础

> 从 WSL2 环境、Mini Config、编译内核、BusyBox rootfs、QEMU 启动、GDB 调试到内核模块与 9p 迭代——一条线打通，建立内核开发的基础工具链。✅ 8 篇已锤炼；🔨 8 篇整理中骨架(模块参数 / 进程线程 / 虚拟地址空间 / 内核数据结构 / 用户内核边界 / Kconfig / Kbuild / QEMU 基础)，对照 6.19 源码校订、待 QEMU 亲测。

## 教程

- ✅ [01 WSL2 环境摸底与交叉编译工具链](./01-wsl2-env-toolchain)
- ✅ [02 Mini Config：从零设计一份精简的内核配置](./02-kernel-mini-config)
- ✅ [03 编译你的第一个 ARM64 内核](./03-kernel-build)
- ✅ [04 用 BusyBox 构建最小根文件系统](./04-busybox-rootfs)
- ✅ [05 QEMU 首次启动与 boot log 解读](./05-qemu-first-boot)
- ✅ [06 GDB + QEMU 远程调试 ARM64 内核](./06-gdb-debug-setup)
- ✅ [07 从零写第一个内核模块](./07-kernel-module-hello)
- ✅ [08 用 9p 共享目录加速内核模块迭代](./08-kernel-module-9p-iteration)
- 🔨 [09 给内核模块装上"旋钮":module_param 与运行时调参](./09-kernel-module-params)
- 🔨 [10 "我在谁的上下文里跑":进程、线程与 task_struct](./10-process-thread-kernel)
- 🔨 [11 每个进程都以为自己独占内存:虚拟地址空间 VAS 全景](./11-virtual-address-space)
- 🔨 [12 内核数据结构四件套:container_of、list_head、hlist、rbtree](./12-kernel-data-structures)
- 🔨 [13 用户态/内核态边界:系统调用与 copy_to_user](./13-user-kernel-boundary)
- 🔨 [14 Kconfig 系统:内核配置语言与 defconfig 流程](./14-linux-kconfig)
- 🔨 [15 Kbuild 系统:内核怎么把自己编出来](./15-kernel-build)
- 🔨 [16 QEMU 基础:加速器、机型、monitor 与常用选项](./16-qemu-basics)
