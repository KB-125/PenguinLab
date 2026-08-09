---
title: "上下文切换:从一个任务切到另一个发生了什么"
slug: sched-context-switch
prerequisites:
  - sched-overview
  - process-thread-kernel
next:
  - sched-load-balance
difficulty: intermediate
tags: [scheduler, context-switch, switch_to, switch_mm, lazy-tlb, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch10.md
  - source: third_party/linux（6.19）kernel/sched/core.c、arch/arm64/kernel/process.c
maturity: drafting
related:
  - /tutorials/kernel/sched/01-sched-overview
  - /tutorials/foundations/10-process-thread-kernel
---

> 🔨 **整理中** · 这一篇拆**上下文切换(context switch)**——`__schedule` 选出下一个任务后,从 prev 切到 next 那一刻内核干了什么。素材从 ch10 + 6.19 源码整理。它是 [01 调度器框架](./01-sched-overview.md) 的"`__schedule` → `context_switch`"那一步的展开。

## 做什么

调度器选定下一个任务后,真正"换人"的动作是**上下文切换**:把当前(prev)任务的 CPU 寄存器现场保存下来、把下一个(next)任务的现场恢复进去,于是 CPU 接着跑的就是 next 的代码。这件事听起来简单,细节却不少:寄存器怎么存、内核栈怎么换、如果两个任务属于不同进程地址空间怎么切(`switch_mm` 改页表)、内核线程怎么特殊处理(不切地址空间、复用前一个的)。这一篇把这套流程拆透,顺便讲清"上下文切换有代价、所以别频繁切换"这条性能常识的根。

## 要了解什么

### 一、`context_switch`:三段式

`__schedule` 选出 next 后,调 `context_switch(rq, prev, next, &rf)`(`kernel/sched/core.c`,在 `__schedule` 体内)。它干三件事:

1. **`prepare_task_switch(rq, prev, next)`**(`core.c:5051`):切换前的预备——通知各种子系统(如 perf、firewall、audit)"要切换了",调架构无关的钩子。
2. **`switch_to(prev, next, prev)`**:核心的架构相关切换——保存 prev 的寄存器、恢复 next 的寄存器。这一步执行**返回时,CPU 已经在 next 的内核栈上跑**了(prev 被"冻结"在它调用 `switch_to` 的地方)。
3. **`finish_task_switch(prev)`**(`core.c:5082`):切换后的清理——完成前一个任务(pre)的收尾(如 `put_task_struct` 释放它的引用、开抢占)。

注意第 2 步的特殊性:`switch_to` 返回时,**当前执行流已经不是 prev 了**,而是 next(它上次切走时停在 `switch_to` 的位置,现在恢复);而 prev 要等将来某次又切回它时,才从 `switch_to` 的下一条语句继续。所以 `switch_to` 之后的代码(`finish_task_switch`)其实是**为"将来切回这个任务时"做清理**——这是个容易绕晕的点,内核用 `switch_to(prev, next, prev)` 的第三参数(返回前一个任务指针)处理这种语义。

### 二、`switch_to`:架构相关的寄存器/栈切换

`switch_to` 是宏,展开到架构代码。ARM64 的链条是 `switch_to` → `__switch_to(prev, next)`(`arch/arm64/kernel/process.c`)→ `cpu_switch_to(prev, next)`(汇编,在 `arch/arm64/kernel/entry.S` 附近)。它做的事:

- 保存 prev 的** callee-saved 寄存器**(x19-x29、sp、pc)到 prev 的 `thread_info`/`cpu_context`。
- 把 next 的 `cpu_context` 里存的寄存器**恢复**回去(包括栈指针 sp)。
- 由于 sp 现在指向 next 的内核栈,后续指令的局部变量、返回地址全是 next 的——切换完成。

关键点:**切换的是"内核栈 + callee-saved 寄存器"**,不是所有寄存器(调用者保存的 x0-x18 在 `__switch_to` 函数调用边界本来就不保证,由编译器处理)。prev 的用户态寄存器现场,在它进内核态时已经保存在它的内核栈顶(`pt_regs`),不在 `cpu_context` 里——这部分随着内核栈切走而"留在那里",下次切回来自然还在。

### 三、`switch_mm`:地址空间切换

如果 prev 和 next 属于**不同进程**(不同 `mm_struct`),还要切**地址空间**——`switch_mm(prev_mm, next_mm, next)`。它把 ARM64 的 `TTBR0_EL1`(用户空间页表基址寄存器)指向 next 的 `mm->pgd`,并刷掉 TLB(老地址翻译缓存作废)。这样后续用户态访问走的是 next 的页表——next 进程"独占内存"的幻觉就是这么续上的。

### 四、内核线程的特例:lazy TLB

如果 next 是**内核线程**(`next->mm == NULL`,它没有用户空间),就**不切地址空间**——内核线程共享前一个任务的 `mm`(借用它的页表,反正内核线程不访问用户空间)。这套机制叫 **lazy TLB**:避免无谓的 `switch_mm` + TLB flush(刷 TLB 代价大,会让后续访问都 TLB miss)。所以内核线程切换比进程切换便宜得多——这是为什么"用内核线程干后台活"比"用普通进程"开销小的一个原因。

### 五、切换的代价:为什么别频繁切换

上下文切换不是免费的:`switch_to` 的寄存器保存恢复、可能的 `switch_mm` + TLB flush、cache 预热失效(prev 把 cache 暖起来、next 一来又冷启动)——单次切换几百纳秒到几微秒,TLB/cache miss 后的连锁反应更大。所以"上下文切换率高"是性能问题的一个常见信号(`perf`/`vmstat` 能看),调度器设计(如 EEVDF 给的时间片、SMP 负载均衡的频率)也要在"响应性"和"切换开销"之间权衡。

## 动手试试

1. `cat /proc/<pid>/status` 看 `voluntary_ctxt_switches`(自愿让出,如等 I/O)/`nonvoluntary_ctxt_switches`(被抢占),体会本篇讲的切换
2. `vmstat 1` 看 `cs` 列(context switch 每秒次数),制造负载(多线程)观察它涨
3. `perf stat -e context-switches,cpu-migrations <cmd>` 看一次命令执行触发了多少次切换 + 多少次核迁移
4. 读 `__schedule`(`kernel/sched/core.c:6729`)里调 `context_switch` 那段,对照本篇第一节走一遍三段式
5. 思考题:为什么内核线程切换比普通进程便宜?(结合本篇第四节 lazy TLB)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`kernel/sched/core.c`(`context_switch`、`prepare_task_switch :5051`、`finish_task_switch :5082`、`__schedule :6729`);ARM64 架构部分 `arch/arm64/kernel/process.c`(`__switch_to`)与汇编 `cpu_switch_to`;`switch_mm` 在 `arch/arm64/include/asm/mmu_context.h`。
- 关联本站:本篇是 [01 调度器框架](./01-sched-overview.md) `__schedule` 那条线的展开;切换的"进程上下文"底座在 [10 进程线程](../../foundations/10-process-thread-kernel.md);切换次数是性能指标,关联 [debugging/00 调试全景图](../../debugging/00-debug-bug-classification.md) 的 perf/trace 工具。
- 读书笔记:[ch10](../../notes/linux_kernel_programming/ch10.md) 讲上下文切换的概念。
