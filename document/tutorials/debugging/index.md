---
title: 调试与性能
description: printk、ftrace、perf、eBPF——内核调试与性能分析全栈
---

# 调试与性能

> printk → ftrace → perf → eBPF，内核调试和性能分析全栈。

🔨 **整理中**。通识基础里的 [GDB + QEMU 调试](../foundations/06-gdb-debug-setup)打底，这里往运行时调试展开。

## 调试地图(序章) 🔨 整理中

- 🔨 [00 调试先认路:Bug 分类与工具全景图](./00-debug-bug-classification)

## 调试工具 🔨 整理中

- 🔨 [printk：内核调试的生命线](./01-debug-printk)
- 🔨 [Kprobes：在任意函数上插眼](./02-debug-kprobes)
- 🔨 [KASAN：影子内存抓内存破坏](./03-debug-kasan)
- 🔨 [SLUB 调试：红区、毒药与追踪](./04-debug-slub)
- 🔨 [Oops：内核崩溃现场解读](./05-debug-oops)
- 🔨 [ftrace：内核的瑞士军刀追踪器](./06-debug-ftrace)
- 🔨 [KCSAN：抓并发里的数据竞争](./07-debug-kcsan)
- 🔨 [panic、Hung Task 与死锁检测](./08-debug-panic)
- 🔨 [KGDB：让 GDB 停下整个内核](./09-debug-kgdb)

## 动态调试 / 进阶工具 🔨 整理中

- 🔨 [10 动态调试:运行时开关任何 pr_debug,还几乎零开销](./10-debug-dynamic-debug)
- 🔨 [11 lockdep:在死锁发生前抓住它](./11-debug-lockdep)
- 🔨 [12 trace-cmd:ftrace 的命令行封装与 KernelShark](./12-debug-trace-cmd)
- 🔨 [13 perf:性能分析神器](./13-debug-perf)
- 🔨 [14 eBPF:在内核里跑沙盒程序](./14-debug-ebpf)
- 🔨 [15 crash:分析崩溃转储(vmcore)](./15-debug-crash)
- 🔨 [16 性能剖析实战:综合项目](./16-debug-profiling-project)
