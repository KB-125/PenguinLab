---
title: "RT 实时调度:SCHED_FIFO/SCHED_RR 与带宽限制"
slug: sched-rt
prerequisites:
  - sched-overview
next:
  - sched-context-switch
difficulty: intermediate
tags: [scheduler, rt, sched_fifo, sched_rr, rt_rq, rt_prio_array, rt_throttling, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch10.md
  - source: third_party/linux（6.19）kernel/sched/rt.c、kernel/sched/sched.h
maturity: drafting
related:
  - /tutorials/kernel/sched/01-sched-overview
  - /tutorials/kernel/sched/02-sched-cfs-eevdf
---

> 🔨 **整理中** · 这一篇讲 Linux 的**实时(RT)调度**——`SCHED_FIFO`/`SCHED_RR` 两种实时策略,以及内核为防 RT 任务霸占 CPU 而设的**带宽限制(RT throttling)**。素材从读书笔记 ch10 + 6.19 源码整理。它是 [01 调度器框架](./01-sched-overview.md) 里"`rt_sched_class` 比 `fair` 优先级高"的展开,和 [02 CFS/EEVDF](./02-sched-cfs-eevdf.md) 是配对的"另一类调度类"。

## 做什么

[框架那篇](./01-sched-overview.md) 我们说 `pick_next_task` 沿调度类优先级链从高到低问,RT 类(`rt_sched_class`)排在 fair 之上——所以只要系统里有就绪的 RT 任务,fair 的普通任务就靠边。哪些任务算 RT?用了 `SCHED_FIFO` 或 `SCHED_RR` 策略、带 1~99 实时优先级的任务。这一篇拆 RT 调度类内部:它的优先级怎么组织、`FIFO` 和 `RR` 两种策略的区别、用什么数据结构 O(1) 选最高优先级任务,以及最关键的——内核怎么防止一个失控的 RT 任务把整台机器锁死(带宽限制)。理解它,你就知道为什么写 RT 程序要谨慎、以及 `chrt` 设了优先级后系统行为怎么变。

## 要了解什么

### 一、RT 优先级:1~99,nice 之外的另一套

普通任务用 nice 值(-20~+19)在 fair 类里调权重;RT 任务用**实时优先级**(1~99,数字越大越猛),在 rt 类里另起炉灶。这两套优先级**不在一个竞技场**——[框架](./01-sched-overview.md) 的 `for_each_class` 保证只要 rt 类有就绪任务,fair 类根本轮不到。所以一个优先级 1 的 RT 任务,能压过所有 nice -20 的普通任务。

### 二、`SCHED_FIFO` vs `SCHED_RR`:有无时间片

两种 RT 策略的区别只在"同优先级之间怎么轮":

- **`SCHED_FIFO`**(先进先出):**没有时间片**。一个 FIFO 任务上了 CPU,只要它不让出(不阻塞、不 `sched_yield`)、不被更高优先级打断,它就**一直跑下去**。同优先级的其它 FIFO 任务只能干等。这意味着 FIFO 容易让同优先级任务**饿死**——一个死循环 FIFO 任务能把同优先级的伙伴永远晾着。
- **`SCHED_RR`**(轮转):**有时间片**(默认 100ms)。同优先级的 RR 任务**轮流上**,谁时间片用完就排到该优先级队列末尾、换下一个。比 FIFO 友好,适合"几个同等重要的 RT 任务需要并发"。

两者的"抢占"规则一致:**更高 RT 优先级的任务一就绪,立刻抢占当前在跑的**。这是"实时"的本质——可预测、可抢占。

### 三、`rt_rq` + `rt_prio_array`:O(1) 选最高优先级

RT 调度类的运行队列 **`struct rt_rq`**(`kernel/sched/sched.h:826`)内嵌一个 **`struct rt_prio_array active`**(`:827`),这是 RT 选任务的精巧数据结构:

```c
struct rt_prio_array {        /* sched.h:308 */
    DECLARE_BITMAP(bitmap, MAX_RT_PRIO+1); /* 位图:第 i 位=1 表示优先级 i 有任务 */
    struct list_head queue[MAX_RT_PRIO];    /* 每个优先级一个链表头 */
};
```

选下一个任务时,内核用 `find_first_bit(bitmap)` 一次找到"最高的非空优先级"(O(1)),再从那个优先级的 `queue[i]` 链表头取一个(O(1))——所以 RT 选任务是真正的 **O(1)**,和优先级数无关(老 O(1) 调度器就是这套思路,fair 才改用红黑树/EEVDF)。`FIFO` 任务从队首取、跑完排回队首(让同优先级接着等);`RR` 任务时间片用完排到队尾(轮流)。

### 四、RT 带宽限制:防止 RT 霸占

`SCHED_FIFO` 没时间片,意味着一个失控的 RT 任务能占住 CPU 永远不让——系统其它部分(包括内核自己的维护任务、`softdog`)饿死,整台机器看起来就"死"了。为防这种灾难,内核给 RT 设了**带宽限制(RT throttling)**:RT 任务在一个 `period` 内最多只能跑 `runtime` 时间,超了就被强制限流、把 CPU 让给其它任务。

- `sysctl_sched_rt_period`(`kernel/sched/rt.c:18`,默认 `1000000`us = 1s):统计周期
- `sched_rt_runtime`(默认 `950000`us = 0.95s):周期内 RT 总共能跑的上限

默认配比 950000/1000000 = **95%**——RT 任务最多占 95% CPU,留 5% 给系统维护/调度器自己喘气,防止"RT 失控 → 系统假死、连 shell 都进不去"。可调(`/proc/sys/kernel/sched_rt_period_us`/`sched_rt_runtime_us`),设 `-1` 关闭限流(慎用,适合你能保证 RT 任务行为可控的场合)。这套机制是 Linux 作为 GPOS(通用 OS)对"RT 失控"的最后防线——真硬实时场景需要 PREEMPT_RT 补丁,那是另一个话题。

### 五、给任务设 RT 策略:`chrt` 与内核里的 `sched_set_fifo`

用户态用 `chrt -f -p 50 <pid>`(FIFO 优先级 50)或 `chrt -r -p 50 <pid>`(RR)设任务策略。内核侧,5.9 起**模块里不再用 `sched_setscheduler` 随便塞优先级**,改用三个受限封装([框架那篇](./01-sched-overview.md) 提过):`sched_set_fifo(p)`(FIFO 优先级 50)、`sched_set_fifo_low(p)`(优先级 1)、`sched_set_normal(p, nice)`。社区认为"模块不该凭空挑实时优先级"——优先级值反映系统设计,该由系统集成者/用户空间定。

## 动手试试

1. 宿主机上 `chrt -p $$` 看当前 shell 的策略(应该是 `SCHED_OTHER`/nice 0);`chrt -f -p 50 $$` 把 shell 切成 FIFO 50(⚠️ 别在远程 ssh 会话里玩,可能锁死自己)
2. 写一个死循环程序,`chrt -f -p 99` 给它最高 FIFO 优先级,单核上观察它把 CPU 吃满 95%(RT throttling)后让出 5%——直观看到带宽限制
3. 起两个同优先级 FIFO 死循环,观察**只有一个**在跑(另一个饿死);改成 `chrt -r`,两个轮流(各约 50%)
4. 读 `kernel/sched/rt.c:2575` 的 `DEFINE_SCHED_CLASS(rt)`,对照 [框架](./01-sched-overview.md) 的 `pick_next_task` 理解 RT 怎么被选
5. 思考题:为什么 RT throttling 默认留 5% 给非 RT?(提示:系统维护、shell 进得去、softdog 不咬)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`kernel/sched/sched.h:308 struct rt_prio_array`、`:826 struct rt_rq`、`:109 sysctl_sched_rt_period`;`kernel/sched/rt.c`——`:18 sysctl_sched_rt_period`(默认值)、`:12 max_rt_runtime`/`MAX_BW`、`:68 init_rt_rq`、`:2575 DEFINE_SCHED_CLASS(rt)`、RT throttling 在 `sched_rt_runtime_exceeded`/`do_balance_runtime`;RT 调度策略 API `sched_set_fifo` 等在 `kernel/sched/syscalls.c`。
- 关联本站:本篇是 [01 调度器框架](./01-sched-overview.md) `for_each_class` 里 RT 类的内部展开;普通任务的 fair 类见 [02 CFS/EEVDF](./02-sched-cfs-eevdf.md);"按 bug 类型选工具"里的 softdog/lockup 见 [debugging/00 调试全景图](../../debugging/00-debug-bug-classification.md)。
- 读书笔记:[ch10](../../../notes/linux_kernel_programming/ch10.md) 讲 POSIX 调度策略与优先级层级。
