---
title: "crash:分析崩溃转储(vmcore)"
slug: debug-crash
prerequisites:
  - debug-panic
  - debug-oops
difficulty: advanced
tags: [debugging, crash, kdump, vmcore, post-mortem, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/admin-guide/kdump/kdump.html
  - source: crash(用户态工具,基于 gdb)
maturity: drafting
related:
  - /tutorials/debugging/08-debug-panic
  - /tutorials/debugging/05-debug-oops
---

> 🔨 **整理中** · 这一篇讲 **crash**——分析 [kdump](./08-debug-panic.md) 转储的 `vmcore` 文件的工具,做"事后分析(post-mortem)"。素材以 kernel.org [kdump 文档](https://docs.kernel.org/admin-guide/kdump/kdump.html) 为权威。它是 [00 调试全景图](./00-debug-bug-classification.md) 矩阵"事后分析 → Kdump+Crash"那一格的核心工具。

## 做什么

[05 Oops](./05-debug-oops.md)/[08 Panic](./08-debug-panic.md) 讲了系统崩溃时怎么从屏幕/串口日志初判原因,但有些 bug 的现场复杂(死锁、内存损坏、并发竞态),光看栈不够,得把崩溃瞬间**整个内核内存**留下来慢慢查。**kdump** 就是干这个的:主内核崩溃触发 panic 时,自动启动一个提前预留内存的**捕获内核(capture kernel)**,它把主内核的完整内存 dump 成 `vmcore` 文件、重启。重启后用 **crash** 工具打开 `vmcore`,你就能像 gdb 调试一样查崩溃时的内核状态:任何进程的栈、task_struct、内存结构、打开的文件、运行队列……一切冻结在崩溃那一刻。这是排查"难复现、现场复杂"的内核 bug 的终极手段。

## 要了解什么

### 一、kdump:捕获内核 + vmcore

kdump 的工作链:正常时,主内核启动时**预留一段内存**(给捕获内核用,`crashkernel=128M` 之类的内核参数);主内核 panic 时,`kexec` 把那段预留内存里的捕获内核(一个独立的、极简的内核镜像)跳进去执行——它在干净的环境里把主内核的内存 dump 成 `vmcore`、保存到磁盘、重启。整个机制的关键是"用一个干净的捕获内核去读已挂掉的主内核的内存",保证 dump 本身可信。

### 二、crash 工具:基于 gdb 的 vmcore 分析器

**crash**(用户态工具,本仓库不含其源码)打开 `vmcore` + 对应的 `vmlinux`(带 DEBUG_INFO 的内核镜像)后,进入交互式 shell,主要命令:

- **`bt`/`bt <pid>`**:**栈回溯**——当前 panic 上下文 或 指定进程的内核栈(最常用,先看它)。
- **`ps`**:列出崩溃时所有进程(状态/在哪个 CPU)。
- **`sys`**:崩溃时的系统信息(内核版本/机器/CPU)。
- **`log`**:崩溃时的内核日志(dmesg)。
- **`kmem`**:查内核内存(slab/页分配/某地址),排查内存损坏/泄漏。
- **`struct <type> <addr>`**:按数据结构类型打印某地址的内容(如 `struct task_struct <addr>` 看一个任务的全部字段)。
- **`task`/`files`/`dev`/`mod`/`runq`**:看任务详情/打开文件/设备/模块/运行队列。

### 三、典型分析流程

崩溃 vmcore 拿到手,典型排查顺序:

1. **`sys` + `log`**:确认内核版本、看崩溃前后的 dmesg(panic 原因常在这里)。
2. **`bt`**:看 panic 上下文的栈——是哪个函数、调用链是什么、参数是什么。
3. 根据栈,用 **`struct`** 看相关数据结构(比如栈里有个 `struct task_struct *p`,`struct task_struct <addr>` 看它)。
4. 如果怀疑内存问题,**`kmem`** 看 slab/页状态;如果死锁,**`ps`** 看哪些任务在 D 状态、`bt` 看它们的栈找锁依赖。
5. 结合源码定位根因。

### 四、约束:嵌入式可能用不起

kdump 要预留一段内存给捕获内核(典型 128-256MB),64MB 的嵌入式板子可能奢侈不起;有些架构的捕获内核支持也不全。这类场景退而用 [Oops](./05-debug-oops.md)/串口日志 + `kmsg_dump`,或用 [KGDB](./09-debug-kgdb.md) 实时调试。所以 kdump+crash 主要在服务器/桌面场景用,嵌入式按需。

## 动手试试

1. 服务器/桌面配 kdump(`kdump-tools`/`kexec-tools`),`sysctl kernel.panic` 设自动重启,故意触发 panic(模块 NULL deref),验证 vmcore 生成
2. `crash /usr/lib/debug/vmlinux vmcore` 打开 vmcore,`sys`/`log`/`bt`/`ps` 走一遍本篇第三节
3. `crash` 里 `struct task_struct <addr>` 看一个任务的全部字段
4. 进阶:`kmem -s` 看 slab 缓存、`kmem -p` 看页分配,排查内存问题
5. 思考题:为什么 kdump 要用独立的"捕获内核",而不是主内核自己 dump 自己内存?(提示:主内核状态已不可信)

## 延伸阅读

- 源码/工具:crash 工具(项目 `github.com/crash-utility/crash`,基于 gdb);kdump 内核侧 `kernel/kexec*.c`、`include/linux/kexec.h`、`kernel/panic.c` 的 `__crash_kexec`;文档 `Documentation/admin-guide/kdump/`。
- kernel.org:[kdump](https://docs.kernel.org/admin-guide/kdump/kdump.html)、[crash utility](https://crash-utility.github.io/)。
- 关联本站:本篇是 [05 Oops](./05-debug-oops.md)/[08 Panic](./08-debug-panic.md) 的事后分析展开;实时调试(事后分析的替代)是 [09 KGDB](./09-debug-kgdb.md);[00 调试全景图](./00-debug-bug-classification.md) "事后分析"那一栏。
