---
title: "perf:性能分析神器"
slug: debug-perf
prerequisites:
  - debug-bug-classification
difficulty: intermediate
tags: [debugging, perf, pmu, profiling, flamegraph, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://perf.wiki.kernel.org/
  - source: third_party/linux（6.19）tools/perf/、include/uapi/linux/perf_event.h、kernel/events/
maturity: drafting
related:
  - /tutorials/debugging/06-debug-ftrace
  - /tutorials/debugging/14-debug-ebpf
---

> 🔨 **整理中** · 这一篇讲 **perf**——内核自带的性能分析神器,基于硬件性能计数器(PMC)和软件事件做"热点/缓存/调度/IO"各类性能剖析。素材以 6.19 源码 + [perf wiki](https://perf.wiki.kernel.org/) 为权威。它是 [debug-bug-classification](./00-debug-bug-classification.md) 矩阵里"性能问题 → perf"那一格的核心工具。

## 做什么

"程序慢了,慢在哪?"这个问题靠加 printk 答不了——你不知道慢在哪一行、是不是 cache miss 太多、是不是被某段锁拖住。**perf** 用 CPU 内置的**硬件性能计数器(PMC)** 和内核的软件计数,采样"程序运行时 CPU 在哪里花时间、cache 命中率怎样、分支预测失多少",把性能瓶颈定位到具体函数甚至指令。它是 Linux 上性能分析的标配工具(由内核源码 `tools/perf/` 自带),从"哪个函数吃 CPU 最多"到"哪条指令 cache miss 频繁"都能挖。这一篇拆 perf 的用法和它背后的 `perf_event_open` 内核接口。

## 要了解什么

### 一、perf 的内核基础:`perf_event_open`

perf 工具的后端是 **`perf_event_open(2)` 系统调用**(`include/uapi/linux/perf_event.h` + `kernel/events/core.c`)——它给用户态开放"配置一个性能计数、开始计数、读取计数"的能力。可计数的事件分几类:

- **硬件事件(PMU)**:`cycles`(CPU 周期)、`instructions`(指令数)、`cache-misses`、`branch-misses`、`L1-dcache-load-misses` 等——靠 CPU 的 PMC 寄存器,精度极高。
- **软件事件(内核计数)`cpu-clock`/`task-clock`/`context-switches`/`page-faults`/`cpu-migrations`。
- **tracepoint**:内核静态埋点(同 [ftrace](./06-debug-ftrace.md) 的 events)。
- **kprobe/uprobe**:动态探针(同 [02 kprobes](./02-debug-kprobes.md))。

perf 工具就是"帮你调 `perf_event_open`、采集成 `perf.data`、分析展示"的封装。

### 二、perf 子命令:`stat`/`record`/`report`/`top`

- **`perf stat <command>`**:跑 command,统计它用到的硬件计数(cycles/instructions/IPC/cache-miss 率),给出宏观性能画像——快速判断"瓶颈是 CPU 还是 cache 还是 IO"。
- **`perf record -F 99 -g <command>`**:按 99Hz 采样(采调用栈 `-g`),跑 command 后把样本存进 `perf.data`——找"哪个函数占 CPU 多"。
- **`perf report`**:打开 `perf.data` 交互式分析(按函数排序、展开调用栈)。
- **`perf top`**:实时(像 `top`)显示当前 CPU 占用最高的函数。
- **`perf bench`**:跑内置 benchmark。

### 三、典型场景

- **找 CPU 热点**:`perf record -g ./myapp; perf report`——看哪个函数采样占比高。
- **火焰图**:`perf record -g` + 用 Brendan Gregg 的 FlameGraph 脚本把调用栈画成火焰图,一眼看出"调用栈哪一层宽=时间花在哪"。
- **找 cache 瓶颈**:`perf stat -e cache-misses,cache-references ./myapp` 看 cache miss 率。
- **看调度/IO**:`perf stat -e context-switches,page-faults,sched:sched_switch`。

### 四、约束与注意

perf 需要内核 `CONFIG_PERF_EVENTS`(几乎总开)、部分硬件事件需要平台 PMU 支持;ARM64 的 PMU 实现(`arch/arm64/kernel/perf_event.c`)和 x86 不同但 perf 工具层通用。`perf record` 采样有开销(高频采样本身耗 CPU),生产环境用低频(`-F 99`)短期采样。`perf report` 需要带 `CONFIG_DEBUG_INFO` 的内核 + 符号才能看到源码行。

## 动手试试

1. `perf stat ls /` 看 ls 的硬件计数(cycles/instructions/IPC)
2. `perf record -F 99 -g find / > /dev/null; perf report` 看 find 的 CPU 热点
3. `perf top` 实时看系统热点
4. 用 FlameGraph 脚本把 `perf.data` 画成火焰图(`perf script | stackcollapse-perf.pl | flamegraph.pl > out.svg`)
5. 思考题:`perf stat` 和 `perf record` 的区别?(提示:计数统计 vs 采样记录)

## 延伸阅读

- 源码/工具:perf 工具在 `tools/perf/`(内核源码自带);内核后端 `kernel/events/core.c`(`perf_event_open` 实现);UAPI `include/uapi/linux/perf_event.h`(`perf_event_attr`/事件类型常量);ARM64 PMU `arch/arm64/kernel/perf_event.c`。
- wiki/perf wiki:[perf.wiki.kernel.org](https://perf.wiki.kernel.org/);Brendan Gregg 的 [perf 火焰图教程](https://www.brendangregg.com/perf.html)是 perf 实战权威。
- 关联本站:本篇是 [00 调试全景图](./00-debug-bug-classification.md) "性能→perf"的工具展开;perf 也用 tracepoint/kprobe,关联 [06 ftrace](./06-debug-ftrace.md)/[02 kprobes](./02-debug-kprobes.md);现代替代/增强 [14 eBPF](./14-debug-ebpf.md)。
