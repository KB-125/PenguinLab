---
title: "线程化中断:把 ISR 的慢活挪进内核线程——让中断处理也能睡觉"
slug: drv-threaded-irq
prerequisites:
  - /tutorials/drivers/05-drv-irq
  - /tutorials/drivers/10-drv-platform
next: []
difficulty: intermediate
tags: [interrupt, threaded-irq, request_threaded_irq, irqf_oneshot, hardirq, irq_thread, preempt_rt, arm64]
architectures: [arm64, arm32, x86_64]
kernel_version: "6.19"
sources:
  - source: third_party/linux（6.19）kernel/irq/manage.c、kernel/irq/handle.c、include/linux/interrupt.h、kernel/sched/syscalls.c
  - notes: document/notes/linux_kernel_device_drivers/ch04.md
maturity: drafting
related:
  - /tutorials/drivers/05-drv-irq
  - /tutorials/kernel/sched/03-sched-rt
---

> 🔨 **整理中** · 这一篇讲**线程化中断(threaded interrupt)**——`request_threaded_irq` 把中断处理拆成"上半部 hardirq + 下半部内核线程"两段,让硬中断里干不了的慢活(走 I2C/SPI 慢总线读数据、持 mutex、分配内存,这些都得能睡)挪到可调度的内核线程里跑。先讲清楚"为什么需要线程化"的硬件动机(慢总线外设的中断处理本质要睡眠),再读 core 实现——内核怎么给每个线程化中断自动建一个 `irq/<N>-<name>` 内核线程(`setup_irq_thread`/`irq_thread`)、它睡在哪、被怎么唤醒,顺带把 `IRQF_ONESHOT` 为什么必用的源码根因挖出来。最后拿触摸屏驱动 `ad7879.c`(纯线程化、`handler=NULL`)的真实用例印证一遍。它是 [05 硬件中断](./05-drv-irq.md) 的进阶。

## 做什么

[05 硬件中断](./05-drv-irq.md) 讲了中断上下文的铁律:**不能睡眠、不能持 mutex、要速战速决**。这条铁律对很多外设太憋屈。

**硬件动机**——考虑一块电阻触摸屏(如 AD7879):手指按下去,触摸屏控制器在自己的中断输出线上拉一个下降沿。中断进来后,"处理"它要做的事是**走 SPI 总线读 AD7879 的 X/Y 坐标寄存器**。问题是:SPI 总线传输可能要等总线仲裁、等从设备响应、走 regmap 框架——这一路调下来**会睡眠**(SPI 控制器驱动用 mutex 保护总线、传输时可能 `wait_for_completion`)。而硬中断里不能睡,所以"读坐标"这步压根没法在 ISR 里干。

老办法是"硬中断里只做最紧急的(关中断源、ack),把读坐标的活儿延迟到工作队列(workqueue)"——但 `work_struct` 那套 API(`INIT_WORK`/`schedule_work`)写起来啰嗦,还要单独维护一个 work 结构。**线程化中断**给了个更顺手的办法:注册中断时直接提供两个函数,hardirq 只判"要不要叫醒下半部"(甚至什么都不做),真正处理在内核自动创建的一个内核线程里跑——这个线程能睡眠、能持 mutex、可调度,API 干净得多。这一篇我们就拆 `request_threaded_irq` 的工作机制,看内核怎么把"中断的下半部"变成一个能睡觉的内核线程。

## 要了解什么

### 〇、为什么需要线程化:慢总线外设的中断处理本质要睡眠

把"为什么不能在硬中断里处理触摸屏/传感器中断"这件事说到底:**这些外设的中断处理逻辑里,头一件事就是读它的寄存器,而读寄存器要走 I2C/SPI 总线,总线传输会睡眠**。

- **I2C/SPI 是"可睡眠总线"**:I2C 控制器驱动用 mutex 保护总线(`struct i2c_adapter` 一次只让一个传输进行),传输完成靠中断 + `wait_for_completion`,这些都会让当前任务睡眠。SPI 同理。
- **mutex 会睡眠**:硬中断里不能持 mutex——mutex 持不到会让当前任务"睡眠等待释放",而中断上下文不属于任何进程,睡下去就再也醒不来。
- **`kmalloc(GFP_KERNEL)` 会睡眠**:中断处理要分配内存(比如 `sk_buff`),`GFP_KERNEL` 允许睡眠等待内存回收,得用 `GFP_ATOMIC`(不睡,但可能失败、浪费紧急内存池)。

所以一旦中断处理要碰慢总线/锁/大内存,硬中断上下文就力不从心。线程化中断把这块"力不从心"的活儿整体搬到内核线程——线程是正常的进程上下文,上面三件事都能干。这是 PREEMPT_RT 实时内核能"把几乎全部硬中断都线程化"的底气:它换来的是中断处理可被更高优先级任务抢占的可预测延迟。

### 一、`request_threaded_irq`:hardirq + thread_fn 两段

核心 API(`include/linux/interrupt.h:155` 声明,实现在 `kernel/irq/manage.c:2100`):

```c
int request_threaded_irq(unsigned int irq,
                         irq_handler_t handler,     /* hardirq(上半部),可设 NULL */
                         irq_handler_t thread_fn,   /* 线程化下半部 */
                         unsigned long irqflags,
                         const char *devname,
                         void *dev_id);   /* kernel/irq/manage.c:2100 */
```

行为:**中断触发时先跑 `handler`(硬中断上下文)**,它返回 `IRQ_WAKE_THREAD` 表示"需要下半部",内核就唤醒对应的 irq 内核线程去跑 `thread_fn`;返回 `IRQ_HANDLED` 则不唤醒,纯上半部搞定。`thread_fn` 在**进程上下文**(就是那个 irq 线程)跑,能睡眠、能持 mutex、能慢——这是和硬中断最大的区别。

两种典型用法:

- **纯线程化**(`handler = NULL`):内核给你装个默认 primary——`irq_default_primary_handler`(`manage.c:986`),它的实现就一行 `return IRQ_WAKE_THREAD;`,于是中断进来几乎立刻唤醒线程、**所有处理都在 `thread_fn` 里**。适合中断处理没什么"硬实时紧急"要做的设备——多数 I2C/SPI 外设(触摸屏、传感器)都这样,第五节看 ad7879 实例。
- **混合**(`handler` 和 `thread_fn` 都填):handler 里做最紧急的(比如关 DMA、读时间戳)再返回 `IRQ_WAKE_THREAD`,thread_fn 里干慢活。适合"既有一点点紧急活、又有慢活"的设备。

反过来,[05](./05-drv-irq.md) 讲的 `request_irq` 就是 `request_threaded_irq(handler, NULL)` 的特例——纯上半部、没下半部线程,处理必须在硬中断上下文干完(`include/linux/interrupt.h:176`)。

### 二、IRQF_ONESHOT 为什么线程化必用——源码根因

线程化中断最容易漏的 flag 是 `IRQF_ONESHOT`(`include/linux/interrupt.h:80`)。漏了会出乱子,得从源码搞清根因。

回顾 [05](./05-drv-irq.md):电平触发中断,只要外设那边的电平没撤,中断线就一直触发。flow handler `handle_level_irq`(`kernel/irq/chip.c:685`)的对策是**进 handler 前 `mask_ack_irq` 屏蔽这条线、handler 返回后 `cond_unmask_irq` 解蔽**——一进一出之间,中断线是屏蔽的,不会重复触发。

现在问题来了:**线程化中断里,handler(hardirq)很快就返回了,但 `thread_fn` 还没跑(它在等内核线程被调度)。** 如果 handler 一返回就 `cond_unmask_irq` 解蔽,对电平中断来说——电平还高着,立刻又触发一次中断 → 又 wake thread → thread 还没跑又被 wake……中断风暴 + 线程被反复唤醒。

`IRQF_ONESHOT` 的语义正是解这个:**hardirq 跑完不立即重开这条 IRQ 线,保持屏蔽,直到 `thread_fn` 跑完才 unmask**(`interrupt.h:52` 注释原话:"Interrupt is not reenabled after the hardirq handler finished")。这样 thread_fn 跑期间中断线一直关着,电平再高也不会重新触发,等 thread_fn 把信号源(外设那边的电平)处理掉了再开。

> ⚠️ **规则:电平触发的线程化中断必须加 `IRQF_ONESHOT`。** 边沿触发相对宽松(只记跳变次数),但加了也没坏处——稳妥起见,线程化中断一律加 `IRQF_ONESHOT` 是常见习惯。`handle_level_irq` 里 `cond_unmask_eoi_irq`(`chip.c:700`)那串对 `IRQS_ONESHOT`/`threads_oneshot` 状态的判断,就是在协调"oneshot 期间 mask、thread 跑完 unmask"的时序,逻辑相当绕——我们只要抓住"thread_fn 跑完才解蔽"这条主线就够用。

### 三、core 实现走读:irq 线程是怎么建、怎么跑的

这是线程化中断最有料的部分——看内核怎么给每个线程化中断自动建一个内核线程、它睡在哪、中断来了怎么唤醒它跑 `thread_fn`。全部在 `kernel/irq/manage.c`。

**建线程(`__setup_irq` → `setup_irq_thread`)**。`request_threaded_irq` 最终调 `__setup_irq`(`manage.c:1460`)把 action 挂到 irq_desc 上;如果 action 提供了 `thread_fn`,它会调 `setup_irq_thread`(`manage.c:1391`)建内核线程:

```c
/* kernel/irq/manage.c:1391 — 建 irq 内核线程 */
static int setup_irq_thread(struct irqaction *new, unsigned int irq, bool secondary)
{
    struct task_struct *t;
    if (!secondary) {
        t = kthread_create(irq_thread, new, "irq/%d-%s", irq, new->name);  /* :1396 主线程 */
    } else {
        t = kthread_create(irq_thread, new, "irq/%d-s-%s", irq, new->name); /* :1399 secondary */
    }
    ...
    new->thread = get_task_struct(t);   /* :1411 记到 action->thread,中断来了唤醒它 */
    kthread_bind_mask(t, cpu_possible_mask);   /* :1421 先绑全部 CPU,线程就绪后自己调亲和性 */
    ...
}
```

注意线程名 `irq/%d-%s`——`%d` 是 IRQ 号、`%s` 是你注册时给的 `devname`。所以 `request_threaded_irq(73, ..., "ad7879", ...)` 建出的线程名就是 `irq/73-ad7879`,`ps -ef | grep irq/` 能直接看到。secondary 线程名里多个 `-s-`(`irq/73-s-ad7879`),它的用途在踩坑节讲。

**线程主循环(`irq_thread`,`manage.c:1233`)**。这个内核线程的"函数体"是 `irq_thread`,它就一个循环——睡、等中断、醒来跑 thread_fn:

```c
/* kernel/irq/manage.c:1233(关键段) */
static int irq_thread(void *data)
{
    struct irqaction *action = data;
    struct irq_desc *desc = irq_to_desc(action->irq);

    irq_thread_set_ready(desc, action);                  /* :1241 标记线程就绪 */

    /* :1243-1246 设调度策略:secondary 用 _secondary,主线程用 sched_set_fifo */
    if (action->handler == irq_forced_secondary_handler)
        sched_set_fifo_secondary(current);
    else
        sched_set_fifo(current);

    /* :1248 force_irqthreads(PREEMPT_RT)时用 irq_forced_thread_fn,否则 irq_thread_fn */
    handler_fn = force_irqthreads() ? irq_forced_thread_fn : irq_thread_fn;

    while (!irq_wait_for_interrupt(desc, action)) {      /* :1257 ⭐ 睡在这等中断 */
        irqreturn_t action_ret = handler_fn(desc, action); /* :1260 醒来跑你的 thread_fn */
        if (action_ret == IRQ_WAKE_THREAD)
            irq_wake_secondary(desc, action);            /* :1262 唤醒 secondary 线程 */
        wake_threads_waitq(desc);
    }
    return 0;
}
```

几个关键点:`irq_wait_for_interrupt`(:1257)是线程睡觉的地方——它检查 `IRQTF_RUNTHREAD` 标志位,没置位就把自己挂起;中断来了这个标志位被置(下面 `__irq_wake_thread` 干的),线程被唤醒继续循环,调 `handler_fn`(:1260)最终调你的 `thread_fn`。`sched_set_fifo(current)`(:1246)把线程设成 `SCHED_FIFO` 实时策略——这就是线程化中断"可调度、可被高优先级任务抢占"的来源,下一节讲。

**唤醒(`__irq_wake_thread`,`kernel/irq/handle.c:61`)**。中断真的触发、hardirq 返回 `IRQ_WAKE_THREAD` 后,`__handle_irq_event_percpu`(`handle.c:185`)的 switch 分支调 `__irq_wake_thread`(`handle.c:231`):

```c
/* kernel/irq/handle.c:61(关键段) */
void __irq_wake_thread(struct irq_desc *desc, struct irqaction *action)
{
    if (action->thread->flags & PF_EXITING)
        return;                                          /* 线程已挂,假装处理过(防风暴) */

    if (test_and_set_bit(IRQTF_RUNTHREAD, &action->thread_flags))
        return;             /* :77 ⭐ RUNTHREAD 已置位就直接返回——合并多次唤醒 */

    wake_up_process(action->thread);   /* 唤醒 irq 线程,它从 irq_wait_for_interrupt 醒来 */
}
```

这里有个只有读源码才发现的细节:`test_and_set_bit(IRQTF_RUNTHREAD, ...)` 用原子"测试并置位"——如果中断连续来好几次、但线程还没来得及跑(还睡在调度队列里),后续唤醒发现 `RUNTHREAD` 已置位就直接返回,**不会重复 wake_up_process**。也就是说:同一中断在你线程还没跑完时多次触发,thread_fn 只跑一次(下次中断的电平/数据要等这次读完才知道)。这是线程化中断合并高频中断、避免风暴的一个隐式机制。

### 四、数据流:中断进来 → hardirq → 唤醒线程 → thread_fn

把"一次线程化中断从硬件到 thread_fn"这条链走完(上半部和 [05](./05-drv-irq.md) 第四节数据流重合,这里从 hardirq 返回处接力):

1. **硬件 → CPU → flow handler → hardirq**:和 [05](./05-drv-irq.md) 一样,外设拉线 → 控制器 pending → CPU 跳异常 → `handle_arch_irq` → `generic_handle_domain_irq` → flow handler(`handle_level_irq:685` 先 `mask_ack_irq`)→ `__handle_irq_event_percpu`(`handle.c:185`)遍历 action 链调 `action->handler`(你的 hardirq,`handle.c:208`)。
2. **hardirq 返回 `IRQ_WAKE_THREAD`**:`__handle_irq_event_percpu` 的 switch(`handle.c:220`)走到 `case IRQ_WAKE_THREAD:`,检查 `action->thread_fn` 非空(`handle.c:226`),调 `__irq_wake_thread(desc, action)`(`handle.c:231`)。
3. **唤醒 irq 线程**:`__irq_wake_thread`(`handle.c:61`)设 `IRQTF_RUNTHREAD`、`wake_up_process(action->thread)`。
4. **irq 线程被调度执行**:这个线程是 `setup_irq_thread` 建的 `irq_thread`(`manage.c:1233`),它从 `irq_wait_for_interrupt`(`:1257`)醒来,调 `handler_fn`(`:1260`)→ `irq_thread_fn`(`manage.c:1130`)→ 你的 `thread_fn`。到这里就是在进程上下文跑、能睡眠了。
5. **thread_fn 返回**:`IRQ_HANDLED`(处理完)。flow handler 那边因为 `IRQF_ONESHOT`,此时才 `cond_unmask` 解蔽中断线(第二节讲的时序)。

整条链:外设拉线 → hardirq(`handle.c:208`)返回 `IRQ_WAKE_THREAD` → `__irq_wake_thread:61` → `wake_up_process` → `irq_thread:1233` 醒来 → `irq_thread_fn:1130` → 你的 `thread_fn`(进程上下文,能睡)。注意 hardirq 和 thread_fn 之间隔了一次调度——thread_fn 跑得"慢一点"(要等线程被调度),换来的是它能睡眠。

### 五、真实用例:ad7879 触摸屏(纯线程化)

拿一个真实驱动看线程化中断怎么用。`drivers/input/touchscreen/ad7879.c` 是 AD7879 电阻触摸屏驱动(SPI/I2C 接口),它是"纯线程化"的典型——hardirq 什么都不做,所有处理在 thread_fn 里:

```c
/* drivers/input/touchscreen/ad7879.c:615 — 注册:handler=NULL(纯线程化) */
err = devm_request_threaded_irq(dev, ts->irq, NULL, ad7879_irq,
                                IRQF_TRIGGER_FALLING | IRQF_ONESHOT, ...);

/* ad7879.c:246 — thread_fn:走 regmap(底层 SPI)读坐标,会睡眠 */
static irqreturn_t ad7879_irq(int irq, void *handle)
{
    struct ad7879 *ts = handle;
    int error;

    error = regmap_bulk_read(ts->regmap, AD7879_REG_XPLUS,         /* :251 SPI 读坐标,可睡 */
                             ts->conversion_data, AD7879_NR_SENSE);
    if (error)
        dev_err_ratelimited(ts->dev, "failed to read %#02x: %d\n", ...);
    else if (!ad7879_report(ts))                                    /* 上报坐标给 input 子系统 */
        mod_timer(&ts->timer, jiffies + TS_PEN_UP_TIMEOUT);         /* 启动"抬笔"超时定时器 */

    return IRQ_HANDLED;
}
```

每个选择都对应前面的机制:`NULL`(handler)走 `irq_default_primary_handler`(`manage.c:986`),中断进来直接 wake thread;`IRQF_ONESHOT` 保证 thread_fn 跑 `regmap_bulk_read` 这段慢活期间中断线屏蔽,不会被打断;`thread_fn` 里 `regmap_bulk_read` 走 SPI 总线读坐标——这一步在硬中断里根本干不了(SPI 会睡),但线程化后能睡,代码写得跟普通函数一样干净。这就是线程化中断的价值:**让"中断处理要读慢总线"这件事不再痛苦**。

### 六、源码真踩坑(都是读 core 才发现的)

1. **`IRQF_ONESHOT` 漏了的后果是电平风暴**(第二节)。线程化 + 电平触发时,thread_fn 跑完前中断线必须屏蔽。漏了 ONESHOT,handler 一返回 flow handler 就解蔽,电平没撤 → 立刻再触发 → 风暴。这是线程化中断最经典的坑——`handle_level_irq` 那串对 `IRQS_ONESHOT`/`threads_oneshot` 的状态机判断(`chip.c:700`),就是为了在"thread 跑完"这个时机才 unmask。

2. **`handler = NULL` 走 `irq_default_primary_handler`,一行代码 `return IRQ_WAKE_THREAD`**(`manage.c:986`)。所以"纯线程化"不是什么特殊机制,就是 primary handler 用了个永远 wake thread 的默认实现。读到这你才理解 `request_threaded_irq` 注释里"handler can be NULL for oneshot interrupts"的意思。

3. **同一中断多次到、thread_fn 只跑一次**(`__irq_wake_thread` 的 `IRQTF_RUNTHREAD`,`handle.c:77`)。`test_and_set_bit` 原子置位,已置就返回——线程还没跑到时,后续中断不会重复 `wake_up_process`。这意味着线程化中断对高频中断有"合并"效应:thread_fn 跑得慢、中断来得快时,中间几次中断的数据可能合并到一次 thread_fn 里处理(ad7879 用 `regmap_bulk_read` 一次读多个寄存器,正是这种合并的自然结果)。

4. **irq 线程是 `SCHED_FIFO` prio 50,可被更高优先级实时任务抢占**(`irq_thread:1246` 调 `sched_set_fifo`,`kernel/sched/syscalls.c:812`)。`sched_set_fifo` 把线程设成实时调度类,优先级 `MAX_RT_PRIO / 2 = 50`(`MAX_RT_PRIO = 100`,`include/linux/sched/prio.h:16`)。系统集成者可以按需调高关键 irq 线程的优先级、压低次要的,实现"中断处理优先级化"——这是 [03 sched-rt](../kernel/sched/03-sched-rt.md) 讲的实时调度的实战用武之地。

5. **secondary 线程 `-s-` 是 force-threaded 场景的归宿**(`setup_irq_thread:1399`,`irq_thread:1243`)。PREEMPT_RT 内核(或启动参数 `threadirqs`)会强制把绝大多数硬中断线程化——连那些原本用 `request_irq`(纯上半部)注册的也被拆。原 hardirq 被塞进 secondary 线程(`irq_forced_secondary_handler` 判定后走 `sched_set_fifo_secondary`,`syscalls.c:836`,优先级比主线程低一档 49),primary 用默认 wake thread。所以你会在 RT 内核的 `ps` 里看到大量 `irq/N-s-name` 线程。`irq_setup_forced_threading`(`manage.c:1301`)是这套强制的入口。

6. **`force_irqthreads()` 是 PREEMPT_RT 的核心开关**(`irq_thread:1248`)。它返回 true 时,`irq_thread` 用 `irq_forced_thread_fn`(`manage.c:1147`)代替 `irq_thread_fn`(`:1130`)——前者会把"原本的 hardirq"也在线程里跑一遍(因为 RT 把 hardirq 强制挪线程了)。这是 PREEMPT_RT"可预测延迟"的根基:硬中断不再无脑抢占一切,而像普通实时任务一样可被更高优先级任务抢占。

7. **线程挂了不会风暴**(`__irq_wake_thread` 检查 `PF_EXITING`,`handle.c:68`)。如果 irq 线程崩溃退出,`__irq_wake_thread` 发现 `PF_EXITING` 直接返回——"假装处理过",配合 ONESHOT 的 mask 状态(中断线还屏蔽着),不会再唤醒,避免风暴。注释原话:"The hardirq handler has disabled the device interrupt, so no irq storm is lurking."

## 与软中断/工作队列的关系

线程化中断和老的"软中断/tasklet/work queue"解决同一类问题(把中断的慢活延后),但 API 更简洁、且自带"可调度"性质。简单对照:

- **softirq**:编译期静态注册的向量(NET_RX/TX、TASKLET、TIMER 等),最快但没并发保护,容易踩 SMP 竞态,驱动不能动态注册新类型。
- **tasklet**:建在 softirq 上,保证"同一 tasklet 不会同时在两 CPU 上跑",**已被标记 deprecated**(6.x 正在逐步淘汰,新代码别用)。
- **workqueue**:`work_struct` 丢给内核线程跑,可睡眠,适合要排队/大量延迟处理的场景(磁盘 I/O 等)。
- **线程化中断**:最适合"中断处理本身要睡眠"的场景,API 最干净(`request_threaded_irq` 一次搞定)。

它们不是互斥,可以组合——但简单场景下,一个 `request_threaded_irq` 就够。新代码里,中断下半部**优先用线程化中断**。

## 动手试试

> 机制可在 QEMU ARM64 virt 上验证;`irq/<N>-<name>` 内核线程在 `ps` 里能直接看。

1. **观察 irq 内核线程**:写一个 platform 驱动,`probe` 里用 `devm_request_threaded_irq(irq, NULL, my_thread_fn, IRQF_TRIGGER_FALLING | IRQF_ONESHOT, "mydev", dev)`(`my_thread_fn` 里 `msleep(10)` 故意慢 + 打印当前上下文);`ps -ef | grep "irq/"` 能看到对应的 `irq/<N>-mydev` 内核线程——这就是 `setup_irq_thread`(`manage.c:1391`)建的。
2. **验证 thread_fn 能睡**:`my_thread_fn` 里 `msleep(10)`(模拟慢总线读)不 panic、`in_task()` 为真(进程上下文);对比一下,如果在硬中断 handler 里 `msleep`,开 `CONFIG_DEBUG_ATOMIC_SLEEP` 会立刻吐 `might_sleep` 警告——亲眼看到"硬中断不能睡、线程能睡"。
3. **看 hardirq → thread_fn 的先后**:`my_thread_fn` 打印前加个 `pr_info`、给一个虚拟 primary handler(返回 `IRQ_WAKE_THREAD`)也打 `pr_info`;触发中断,`dmesg` 看 primary 先打、thread_fn 后打(中间隔了一次调度)。
4. **故意漏 `IRQF_ONESHOT`**(在边沿触发上试,电平触发太危险):重新触发,观察可能的重复唤醒(`IRQTF_RUNTHREAD` 的合并效应,见第三节踩坑 3)。
5. **优先级实证**(需要 root):`chrt -f -p 60 <irq线程PID>` 把某 irq 线程提到 prio 60(高于默认 50),再用 `chrt` 起一个 prio 70 的实时任务,观察实时任务能抢占 irq 线程的中断处理——这是 RT 优先级化的实战。
6. 思考题:ad7879 注册时 `handler` 传了 `NULL`,那中断进来后"primary handler"实际跑的是哪个函数?它做了什么?(答:`irq_default_primary_handler`,`manage.c:986`,一行 `return IRQ_WAKE_THREAD`——直接唤醒线程。)
7. 思考题:为什么网卡、USB 这些"中断处理要走协议栈/要分配 skb"的设备几乎都用线程化中断?(结合 [05](./05-drv-irq.md) 的铁律 + 本篇第一节"慢总线外设"的硬件动机,本质是同一类问题——中断处理要睡眠。)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):
  - core 实现:`kernel/irq/manage.c`(`request_threaded_irq:2100`、`__setup_irq:1460`、`setup_irq_thread:1391` 建 `irq/%d-%s` 线程、`irq_thread:1233` 线程主循环、`irq_default_primary_handler:986`、`irq_thread_fn:1130`、`irq_forced_thread_fn:1147`、`irq_setup_forced_threading:1301`、`irq_wake_thread:1282`);`kernel/irq/handle.c`(`__handle_irq_event_percpu:185` 的 `IRQ_WAKE_THREAD` 分支、`__irq_wake_thread:61` 用 `IRQTF_RUNTHREAD` 合并唤醒);`kernel/irq/chip.c`(`handle_level_irq:685`、`cond_unmask_eoi_irq:700` 协调 oneshot 时序)。
  - 线程调度:`kernel/sched/syscalls.c:812 sched_set_fifo`、`:836 sched_set_fifo_secondary`;`include/linux/sched/prio.h:16 MAX_RT_PRIO`。
  - 数据结构:`include/linux/interrupt.h:123 struct irqaction`(含 `thread_fn:131`/`thread`)、`:80 IRQF_ONESHOT`。
  - 真实用例:`drivers/input/touchscreen/ad7879.c:615`(纯线程化注册)、`:246 ad7879_irq`(thread_fn 走 regmap 读);`drivers/input/keyboard/gpio_keys.c`(gpio 按键,线程化 + 去抖,在 [26 drv-input](./26-drv-input.md) 走读过)。
- kernel.org:[Generic IRQ subsystem](https://docs.kernel.org/core-api/genericirq.html)(含 threaded interrupts 设计)、`Documentation/core-api/genericirq.rst` 的 "Threaded interrupt handlers" 小节。
- 关联本站:本篇是 [05 硬件中断](./05-drv-irq.md) 的进阶(那里讲上半部全景 + irqchip 驱动走读);irq 线程的 `SCHED_FIFO` 实时优先级见 [03 sched-rt](../kernel/sched/03-sched-rt.md);ad7879 这类输入设备的中断最终喂给 input 子系统,见 [26 drv-input](./26-drv-input.md)。
