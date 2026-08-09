---
title: "性能剖析实战:综合项目"
slug: debug-profiling-project
prerequisites:
  - debug-perf
  - debug-ftrace
  - debug-ebpf
difficulty: advanced
tags: [debugging, profiling, performance, project, perf, ftrace, ebpf, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
type: project
sources:
  - source: 综合 [perf](./13-debug-perf.md)/[ftrace](./06-debug-ftrace.md)/[trace-cmd](./12-debug-trace-cmd.md)/[eBPF](./14-debug-ebpf.md) 实战
maturity: drafting
related:
  - /tutorials/debugging/13-debug-perf
  - /tutorials/debugging/14-debug-ebpf
---

> 🔨 **整理中** · 这一篇是 debugging 藤的**综合实战项目**——把 [perf](./13-debug-perf.md)/[ftrace](./06-debug-ftrace.md)/[trace-cmd](./12-debug-trace-cmd.md)/[eBPF](./14-debug-ebpf.md) 这几样工具组合起来,排查一个真实性能问题。它是项目型节点,核心是"排查流程"和"工具怎么配合",不是某个新工具。素材综合本藤已有各篇。

## 项目目标

把本藤学的性能/追踪工具串成一套**可复用的性能排查流程**,练手目标:面对一个"程序慢/卡顿/延迟高"的真实现象,能从复现 → 顶层画像 → 定位瓶颈 → 验证假设 → 优化 → 对比,一气走通。重点不是"某个工具的某个参数",而是"什么场景用哪个工具、它们怎么配合"。

## 工具组合速查(按"看什么"选)

| 现象/问题 | 首选工具 | 看什么 |
|:--|:--|:--|
| "CPU 去哪了"(总占比) | `perf stat` | cycles/instructions/IPC/cache-miss 率 |
| "哪个函数最吃 CPU" | `perf record -g` + `perf report`/火焰图 | 调用栈热点 |
| "时序:谁阻塞了谁" | `trace-cmd`/ftrace(function_graph) | 调用顺序 + 耗时 |
| "调度延迟/被抢占" | `perf sched`/`trace-cmd -e sched:*` | 调度切换/唤醒延迟 |
| "IO 卡在哪" | `perf stat -e block:*`/`biolatency`(BCC) | IO 延迟分布 |
| "锁竞争" | `perf record -e lock:*`/`offcputime`(bpftrace) | 等锁/被阻塞 |
| "系统调用/内核行为" | `bpftrace`/`strace` | 系统调用频率/参数 |
| "实时状态" | `top`/`vmstat`/`mpstat`/`pidstat` | CPU/内存/IO 总览 |

## 分步流程

**1. 复现 + 顶层画像**:先用 `top`/`vmstat`/`pidstat` 看现象是 CPU bound、IO bound、还是内存 bound——`perf stat` 看 IPC(cache miss 高 → CPU bound 且 cache 友好性差;IO wait 高 → IO bound)。这步决定下面用哪条工具线。

**2. 热点定位(CPU bound)**:`perf record -F 99 -g <app>; perf report` 找最吃 CPU 的函数,画火焰图看调用栈宽度。瓶颈函数锁定后,`perf stat -e cache-misses` 看是不是 cache 问题、或读源码看有没有低效算法。

**3. 时序与阻塞(延迟/卡顿)**:CPU 不忙但慢,多半在等——`trace-cmd record -e sched:* -e irq:*` 看调度/中断时序、`offcputime`(bpftrace)看"进程被阻塞时栈是什么"、`biolatency`(BCC)看 IO 延迟分布。找出"卡在哪等什么"。

**4. 验证假设**:形成"瓶颈是 X"的假设后,用 eBPF/bpftrace 写一行针对性验证(如假设"锁 L 争用",`bpftrace -e 'kprobe:mutex_lock {...}'` 统计 L 的等待)。能复现性地观察到瓶颈,才算坐实。

**5. 优化 + 对比**:改代码/配置后,用同样的 `perf stat`/`perf record` 跑一遍,对比优化前后的指标(热点占比降了、IPC 升了、延迟分布左移了)——用数据证明"确实改好了",而不是"感觉快了"。

## 典型案例(练习素材)

- **CPU 热点型**:`find /` 慢——`perf record find /; perf report` 找热点函数,看是不是某个 dir 操作低效。
- **IO 瓶颈型**:`cp 大文件` 慢——`biolatency` 看块设备延迟,`perf stat -e block:*` 看 IO 是不是瓶颈,改预读/缓冲对比。
- **锁竞争型**:多线程程序吞吐上不去——`perf record -e lock:contention_begin`(或 bpftrace 统计 mutex 等待),找争用最重的锁,改细粒度/无锁。
- **调度延迟型**:实时任务偶发抖动——`trace-cmd -e sched:*` 看被谁抢占、`perf sched latency` 看唤醒延迟分布。

## 动手试试

1. 选一个上面的案例,完整走一遍"复现 → 画像 → 定位 → 验证 → 对比"五步,把每步的工具命令和观察记录下来
2. 用火焰图把一个 CPU 热点案例的调用栈可视化(本藤 [13 perf](./13-debug-perf.md) 的 FlameGraph 流程)
3. 故意写一个有性能 bug 的小程序(如缓存不友好的遍历、或持锁太久),用本篇流程定位它
4. 思考题:为什么优化后必须用同样工具对比指标,而不能凭感觉?(提示:可量化、可复现)

## 延伸阅读

- 本藤工具各篇:[13 perf](./13-debug-perf.md)、[06 ftrace](./06-debug-ftrace.md)、[12 trace-cmd](./12-debug-trace-cmd.md)、[14 eBPF](./14-debug-ebpf.md)、[00 全景图](./00-debug-bug-classification.md)。
- 外部:Brendan Gregg 的 [Linux Performance](https://www.brendangregg.com/linuxperf.html) 是性能排查方法论的权威(工具图谱 + USE 方法 + 火焰图),本篇的"按现象选工具"思路深受它影响;《Systems Performance》(Brendan Gregg)是系统性能的方法学经典。
- 关联本站:本篇综合 debugging 藤所有工具;性能问题在 [00 调试全景图](./00-debug-bug-classification.md) 矩阵里独立一栏;SMP 上的负载/调度性能关联 [sched-load-balance](../kernel/sched/05-sched-load-balance.md)。
