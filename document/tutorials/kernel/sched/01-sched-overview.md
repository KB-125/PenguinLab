---
title: "调度器框架:谁上 CPU,内核怎么拍板"
slug: sched-overview
prerequisites:
  - process-thread-kernel
next:
  - sched-cfs-eevdf
difficulty: intermediate
tags: [scheduler, sched-class, runqueue, pick-next-task, preempt, posix-policy, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch10.md
  - notes: document/notes/linux_kernel_programming/ch11.md
maturity: drafting
related:
  - /tutorials/foundations/10-process-thread-kernel
  - /tutorials/kernel/sched/sched-evolution-03-cfs
---

> 🔨 **整理中** · 这篇是调度器藤的**机制主教程**——讲清楚 6.19 当前内核里"谁该上 CPU"这套决策是怎么组织的。它和我们已有的 [演进史骨架](./sched-evolution-03-cfs)(讲 CFS 怎么从 O(1) 演变来)是配对关系:演进史讲来路,本篇讲现行。所有 6.19 源码都对照本仓库 `third_party/linux/` 校订过行号;但 `/proc/sched_debug`、`chrt`、`perf sched` 这些观察手段在 QEMU 上亲手验过之前,命令输出标"待亲测"。fair 调度类**内部**怎么用 EEVDF 挑下一个任务(vruntime、lag、eligibility、deadline 时间片),放在下一篇 [02 CFS/EEVDF 机制](./02-sched-cfs-eevdf),本篇只搭骨架。

## 做什么

写过用户态多线程程序的我们,多少都建立过一个模糊的信念:"线程在 CPU 上轮流跑,调度器是公平的"。可一旦往内核走,这个信念马上会被一连串更硬的问题碾碎:**到底是"谁"在轮流跑,是进程还是线程?轮流跑的规则写在哪个函数里?同一个系统里既有普通进程又有实时进程,内核凭什么永远让实时进程先上?一个线程正跑着,内核又是从哪儿插进来把它换下去的?** 这一篇我们就把这套决策的骨架拆清楚——调度器是怎么用一张"调度类"的函数指针表、一条靠链接器排好的优先级链、再加上每个 CPU 核各一份的运行队列,搭出"谁上 CPU"这套机制的。读懂这一篇,你就能在 `kernel/sched/` 的源码里找到自己的方向,而不是面对一坨几千行的 `fair.c` 两眼一抹黑。

## 要了解什么

### 一、调度器调度的"东西"是线程,不是进程

第一个要钉死的认知:**Linux 内核的可调度实体(Kernel Schedulable Entity, KSE)是线程,不是进程**。这条我们在 [10-process-thread-kernel](../../foundations/10-process-thread-kernel.md) 里已经讲过缘由——内核眼里每个 `task_struct` 就是一个执行流,所谓"进程"不过是"共享了地址空间的一组线程"。调度器操作的就是这一个一个的 `task_struct`,至于它属于哪个进程、和谁是兄弟,调度器根本不关心。

这件事换算成具体数字最直观:假设一个 CPU 核上挤着一个单线程进程(P1)、一个双线程进程(P2)、一个五线程进程(P3),外加 3 个内核线程,那抢这一个核的 KSE 总数是 `1+2+5+3 = 11` 个线程——不是 3 个进程,也不是 6 个"进程加内核线程"。系统负载(load average)统计的也是这 11 个"车"(线程),而不是 3 个"车队"(进程)。后面所有讨论,我们说到"任务",默认指的就是一个线程对应的 `task_struct`。

### 二、状态机:`__state` 决定你有没有资格抢 CPU

一个线程不是随时都能上 CPU 的,它得先处在"对的"状态。Linux 给每个 `task_struct` 维护了一个状态位掩码 `__state`(`include/linux/sched.h` 里 `task_struct` 的成员,过去叫 `state`,后来改名加双下划线),几个核心状态值得记牢:

- **`TASK_RUNNING`(`R`)**:这个状态名最容易骗人——它**不代表"正在 CPU 上跑"**,而是代表"**在运行队列里排队、随时可被选中**"。一个核上同一时刻真在跑的线程只有一个(抛开 SMT),但 `R` 状态的线程可以有一打,它们都是候选人。
- **`TASK_INTERRUPTIBLE`(`S`)**:可中断睡眠,在等某个事件(网络包、磁盘 I/O、信号量)。能被信号唤醒。
- **`TASK_UNINTERRUPTIBLE`(`D`)**:不可中断睡眠,雷打不动,通常在等关键 I/O。`ps` 里看到一堆 `D` 基本等于"存储卡了"。
- **`TASK_STOPPED`(`T`)**:被 `SIGSTOP` 或调试器暂停。**`TASK_DEAD`/`TASK_ZOMBIE`(`X`/`Z`)**:死了或等父进程收尸。

调度的关键只在于:**只有 `TASK_RUNNING` 的任务才在运行队列里,才有资格被 `pick_next_task` 选中**。一个线程从 `R` 转成 `S`/`D`(它主动调了 `schedule()` 让出 CPU 去等事件),它就离开运行队列;等它等的事件到来被唤醒,状态改回 `TASK_RUNNING`,它才重新入队。所谓"调度",本质就是在这群 `R` 状态的候选人里挑一个让它上 CPU。

> ⚠️ **别误会"运行队列"**
> 运行队列**不是**全局唯一的——Linux 给**每个 CPU 核**都维护了独立的运行队列(`struct rq`,见第五节)。一个 `R` 状态的线程待在某个核的运行队列里,就默认在那个核上跑;负载均衡组件(`migration/N` 内核线程)必要时会把它搬到别的核的队列去。等待队列(wait queue)更是遍地都是,每个驱动/子系统想用就建一个,跟运行队列是两码事。

### 三、模块化调度类:`sched_class` 是一张函数指针表

那么"按什么规则从运行队列里挑人"——这个规则是统一写在一份代码里吗?不是。Linux 把调度策略做成了**模块化的调度类(scheduling class)**:每种策略(DL 实时、RT 实时、CFS/EEVDF 普通、SCHED_EXT 可编程、IDLE 空闲)各自实现成一个 `struct sched_class`,它本质上是一张**虚函数表**——一簇函数指针,描述"这种策略下,怎么入队、怎么出队、怎么挑下一个任务、怎么切换"。

我们看 6.19 里这张表的轮廓(`include/linux/sched.h:2449`):

```c
struct sched_class {
#ifdef CONFIG_SCHED_CORE
    int scopes;                          /* 核调度(CORE scheduling)相关 */
#endif

    void (*enqueue_task)(struct rq *rq, struct task_struct *p, int flags);
    void (*dequeue_task)(struct rq *rq, struct task_struct *p, int flags);

    struct task_struct *(*pick_next_task)(struct rq *rq, struct task_struct *prev,
                                          struct rq_flags *rf);
    void (*put_prev_task)(struct rq *rq, struct task_struct *p);
    void (*set_next_task)(struct rq *rq, struct task_struct *p, bool first);

    int  (*select_cpu)(struct task_struct *p, int cpu, int flags);  /* 选核 */
    void (*balance)(struct rq *rq, struct task_struct *prev, struct rq_flags *rf);
    /* ... 迁移、优先级变更、cgroup 切换等更多钩子 ... */

    unsigned int task_change_group(struct task_struct *p);
} __aligned(__alignof__(struct sched_class));
```

注意这张表里最关键的三个钩子:`enqueue_task`(任务变成 `R` 状态、加入本策略的队列)、`dequeue_task`(任务让出 CPU 或阻塞、离开队列)、**`pick_next_task`**(本策略挑出下一个该上 CPU 的任务)。每种调度类各自实现这三个钩子,逻辑互不干扰——CFS/EEVDF 有自己的一套(按 vruntime/eligibility 挑),RT 有自己的(按优先级挑),DL 有自己的(按 deadline 挑)。

> 这种"把策略做成可插拔虚表"的设计,是 Linux 调度器能同时容纳实时、普通、可编程(BPF)调度器的根本。它和面向对象语言里的"接口 + 多份实现"是同一种思路,只不过这里用 C 的函数指针表手写。后面我们会看到,SCHED_EXT(sched_ext,6.12 合入)甚至允许你用 BPF 程序实现一个自定义调度类——这正是这套抽象的红利。

### 四、调度类的优先级链:链接器替你排好序

光有各自的调度类还不够,得规定"它们之间的优先级"。一个核上同时有 RT 任务和普通任务时,凭什么 RT 永远先跑?答案藏在**链接器脚本**里,这是个相当优雅(也相当隐蔽)的机制。

每个调度类用 `DEFINE_SCHED_CLASS(name)` 宏(`sched.h:2681`)定义:

```c
#define DEFINE_SCHED_CLASS(name) \
const struct sched_class name##_sched_class \
    __aligned(__alignof__(struct sched_class)) \
    __section("__" #name "_sched_class)
```

注意最后的 `__section("__" #name "_sched_class")`——它把这个调度类塞进一个**以类名命名的专属 ELF 段**。然后内核的链接脚本(`include/asm-generic/vmlinux.lds.h` 里的 `SCHED_DATA`)按**固定的优先级顺序**排列这些段,生成一条连续的、从 `__sched_class_highest` 到 `__sched_class_lowest`(`sched.h:2687-2688`)的数组。6.19 里这条链的实际顺序是:

```
stop_sched_class   (stop_task.c:99)   ← 最高,用于 CPU 间同步,核迁移
dl_sched_class     (deadline.c:3362)  ← SCHED_DEADLINE,EDF 最早截止期优先
rt_sched_class     (rt.c:2575)        ← SCHED_FIFO / SCHED_RR,实时
ext_sched_class    (ext.c:3403)       ← SCHED_EXT,BPF 可编程调度器
fair_sched_class   (fair.c:13978)     ← SCHED_NORMAL/OTHER,EEVDF,绝大多数任务
idle_sched_class   (idle.c:553)       ← 最低,无事可做时才轮到
```

`for_each_class(class)` 宏(`sched.h:2715`)就是沿这条链从高到低遍历:

```c
#define for_each_class(class) \
    for_class_range(class, __sched_class_highest, __sched_class_lowest)
```

这套设计的精妙之处在于:**调度类的优先级不是用 `if/else` 硬编码在某个 `pick_next_task` 函数里的,而是由链接器在编译期把它们的存储顺序排好的**。想新增一个调度类,定义好它、塞进对应的段、在链接脚本里排好位置,主循环的遍历逻辑一行都不用改。这是"用链接器干脏活"的典范,内核里 cgroup、initcall、PCI 驱动表都用了类似的招数。

### 五、每个 CPU 核一份的运行队列:`struct rq`

调度类是"策略",策略要有"数据"来操作——这就是运行队列。Linux 给**每个 CPU 核**维护一个独立的 `struct rq`(`include/linux/sched.h:1119`),它通过 per-CPU 变量分发:

```c
DECLARE_PER_CPU_SHARED_ALIGNED(struct rq, runqueues);   /* sched.h:1353 */
```

`struct rq` 是个"大杂烩"结构体,里面嵌套了**每种调度类各自的子队列**:`cfs_rq`(EEVDF 用)、`rt_rq`(实时用)、`dl_rq`(deadline 用),再加上当前正在跑的任务指针 `curr`、时钟统计、负载权重、cgroup 信息、核调度(CORE scheduling)状态等等。可以这样理解它:**一个 CPU 核的全部调度状态,都打包在这一个 `struct rq` 里**。

当一个任务变成 `R` 状态,调度器会根据它的调度类,把它塞进所在核 `rq` 里对应的子队列(`enqueue_task` 钩子);要选下一个任务时,沿调度类优先级链问每个类"从你的子队列里挑一个"(`pick_next_task` 钩子)。所以同一个 `rq` 里,RT 子队列和 fair 子队列是**并列存在**的,只是 RT 永远先被询问。

> ⚠️ **别照搬老教科书的"单一就绪队列"图**
> 很多 OS 教科书讲调度时画的是"一个全局就绪队列,所有就绪进程排一起"。Linux **不是**这样:每核一个 `rq`,各自管各自的子队列,再加负载均衡在核之间搬运任务。这个差异在多核调度、CPU 亲和性、负载均衡的话题里会反复出现,先把"每核一份"刻进脑子。

### 六、主循环:`__schedule` → `pick_next_task` → 切换

骨架搭齐了,现在把"谁上 CPU"这个决策的完整调用链走一遍。入口是 `__schedule()`(`kernel/sched/core.c:6729`),它干的事可以浓缩成三步:锁住当前核的 `rq` → 调 `pick_next_task()` 选出下一个任务 → 调 `context_switch()` 切换地址空间和寄存器(真正的"换人"动作)。对外暴露的 `schedule()`(`core.c:6961`)是对 `__schedule` 的薄包装,自愿让出 CPU 的内核代码都调它。

选人的核心是 `__pick_next_task()`(`core.c:5878`),它的逻辑简洁到感人——就是拿 `for_each_class` 从高到低挨个问:

```c
/* core.c:5878 起(简化) */
for_each_class(class) {
    if (class->pick_next_task) {
        p = class->pick_next_task(rq, prev, rf);   /* 问本类:你挑一个 */
        if (p) return p;                            /* 挑到了就用它 */
    }
}
```

也就是说:**调度器从优先级最高的调度类(stop)开始问,只要某个类能挑出一个任务,就立刻用它、不再往下问**。所以只要系统里有 `R` 状态的 RT 任务,`rt_sched_class->pick_next_task` 一定先应答,`fair_sched_class` 根本轮不到开口——这就是"实时永远先于普通"的代码级根因。只有当所有更高优先级的类都挑不出人(它们队列空),才会落到 `fair_sched_class`,让 EEVDF 从普通任务里挑;要是连 fair 也挑不出(系统空闲),才一路落到 `idle_sched_class`,跑那个永不停歇的 idle 任务(每核一个,`swapper/N`)。

每个调度类内部的 `pick_next_task` 怎么挑,是各自的家务事:`dl` 按"最早绝对截止期"、`rt` 按"优先级数组"、`fair` 按 EEVDF 的 eligibility + deadline(下一篇详讲)。主循环不关心细节,只负责按链问、谁应答用谁。

### 七、调度时机:内核什么时候插进来换人

知道了"怎么换",还得知道"**什么时候**换"。`__schedule` 不是随时都能调的,它有一组触发点和一组约束。

**自愿让出(主动调度)**:最常见的情形。一个任务跑到一半要等资源(等磁盘 I/O、等信号量、等网络包),它自己调了某个会让出 CPU 的函数(`wait_event`、`mutex_lock` 睡眠路径、`schedule_timeout` 等),这些函数内部最终都会调 `schedule()`——任务把自己改成 `S`/`D` 状态、移出运行队列、让 `__schedule` 选别人。这是合作式的让出。

**抢占(被动调度)**:另一种情形是任务没招惹谁、正跑得好好的,被内核强行换下。触发点主要是两个:
1. **时间片到**:时钟中断里发现当前任务用完了本次配额(EEVDF 里是 deadline 到了),给当前任务打个 `TIF_NEED_RESCHED` 标记。
2. **更高优先级任务唤醒**:一个 RT 任务被唤醒进了运行队列,而它比当前跑的优先级高,也会给当前任务打 `TIF_NEED_RESCHED`。

打了标记并不代表立刻就换——内核会在**下一个抢占点**(preemption point)检查这个标记,常见的是:中断处理完返回内核态时(`preempt_schedule_irq`)、或者显式的 `preempt_enable()` 让 `preempt_count` 归零时。这时候才真正调进 `__schedule` 完成切换。

> ⚠️ **黄金法则:调度器代码不能在原子上下文跑**
> 这一节背后藏着一条铁律,我们在 [10-process-thread-kernel](../../foundations/10-process-thread-kernel.md) 也强调过——`schedule()` 绝对不能在中断上下文或持有自旋锁时调用。原因很直接:`__schedule` 要做上下文切换,会把当前任务"挂起来",可中断/持锁上下文根本没有一个"可挂起的任务"做载体;强行切换会导致锁永远释放不了(被切走的任务还拿着锁)、或调度器找不到恢复点,直接死锁/panic。所以中断处理里、持自旋锁的临界区里,抢占是被 `preempt_count` 禁掉的;中断返回用户态(或返回可抢占的内核态)才是安全的换人时机。

### 八、POSIX 策略与优先级:跟调度类怎么对应

把上面的机制映射到我们用户空间能摸到的接口上。POSIX 规定了一套调度策略,每个线程在任一时刻必属其一,而每种策略绑定到一个调度类:

| 策略 | 所属调度类 | 说明 |
|:---|:---|:---|
| `SCHED_OTHER`(=`SCHED_NORMAL`) | fair | 默认策略,nice 值 `-20~+19`(默认 0),走 EEVDF |
| `SCHED_BATCH` | fair | 批处理,少抢占、重吞吐 |
| `SCHED_IDLE` | fair(极低权重) | 比 nice +19 还低,只在 CPU 空闲时跑 |
| `SCHED_FIFO` | rt | 实时先进先出,无时间片,主动让出或被更高优先级打断才下 |
| `SCHED_RR` | rt | 实时轮转,有时间片(默认 100ms),同优先级轮流 |
| `SCHED_DEADLINE` | dl | 最早截止期优先,需指定 runtime/deadline/period |
| `SCHED_EXT` | ext | BPF 可编程调度器(6.12 起正式) |

优先级是分层的:**实时优先级 `1~99`** 给 `SCHED_FIFO/RR/DEADLINE`;只要运行队列里有实时任务,`SCHED_OTHER` 一律靠边(第六节 `for_each_class` 的直接后果)。普通任务的 **nice 值 `-20~+19`** 不跨进实时竞技场,它只在 fair 调度类内部、通过影响 EEVDF 的权重来调节 CPU 占比。而**硬件/软件中断的优先级永远高于一切任务线程**,哪怕是 RT 优先级 99——这是系统最后的刹车。

用户空间改这些属性的工具是 `chrt`(查/设策略和实时优先级)和 `nice`/`renice`(改 nice 值),底层走 `sched_setscheduler`/`sched_setattr` 系统调用。值得注意的是,从 5.9 起,内核**模块**里不许再用 `sched_setscheduler` 随便给内核线程塞任意实时优先级了,改成 `sched_set_fifo()`(固定优先级 50)、`sched_set_fifo_low()`(优先级 1)、`sched_set_normal(p, nice)` 三个受限封装——社区认为"模块不该凭空挑实时优先级,那是系统设计者的活"。

### 九、CPU 亲和性:把线程钉在指定的核上

最后补一个跟"在哪个核的运行队列排队"直接相关的控制手段——**CPU 亲和性**。每个 `task_struct` 里有个位掩码 `cpus_ptr`(5.3 前叫 `cpus_allowed`),标示这个线程**允许在哪些 CPU 核上跑**。一个 8 核系统里默认掩码是 `0xff`(每个核都行);若把它设成 `0x05`(二进制 `0000_0101`),线程就只能出现在 0 号和 2 号核的运行队列里。

用户空间改它靠 `sched_setaffinity()` 系统调用,命令行用 `taskset`(比如 `taskset -c 2,3 ./myapp` 把程序钉在 2、3 号核)。显式设亲和性的典型动机是减少缓存抖动(线程老在一个核上跑、数据常驻该核 L1/L2)、消除核间迁移开销,或把某核"专享"给实时任务(配 cpuset cgroup)。不过内核的负载均衡器对 CPU 拓扑门儿清,大多数情况下让它自己决定反而更好,手动绑核只在极端场景才值得。

> ⚠️ **树外模块想改亲和性的坑**
> 内核侧的 `sched_setaffinity()` 没有被 `EXPORT_SYMBOL`,树外模块调不到。原始素材里演示了一种"野路子":用 `/proc/kallsyms` 查到 `sched_setaffinity` 的地址(注意 KASLR 让它每次启动都变),通过模块参数把地址传进模块、转成函数指针调用。这种 hack 能跑,但它踩在未导出接口上,**生产代码绝对别用**——内核没导出是有理由的,绕过它等于走钢丝。需要绑核的场景,老老实实走用户态 `taskset`/cgroup。

## 动手试试

> 这一篇的 example 偏观察,主要靠 `/proc`、`chrt`、`taskset`、`perf sched` 这些工具把抽象机制验成可见现象。QEMU 上逐条验的清单:

1. `cat /proc/sched_debug`(需要内核开了 `CONFIG_SCHED_DEBUG`)看每个 CPU 核的运行队列——`.curr` 当前任务、`.nr_running` 队列里 `R` 状态任务数、`.cfs_rq`/`.rt_rq` 子队列详情
2. `ps -o pid,policy,nice,pri,comm -e`(BusyBox 的 `ps` 字段有限,宿主机上用完整 `ps`)看每个任务的调度策略(`TSK_OTHER`/`FF`/`RR`...)、nice 值、优先级
3. 用 `chrt -p <pid>` 查某个线程的策略和优先级;试着 `chrt -f -p 50 <pid>` 把一个 BusyBox 进程切到 `SCHED_FIFO` 优先级 50,观察它对其他普通进程的压制
4. `taskset -p <pid>` 查亲和性掩码;`taskset -p 0x03 <pid>` 把某进程钉到 0、1 号核,QEMU 里再 `cat /proc/<pid>/stat` 第 39 个字段(`on_cpu`/所在核)验证
5. 制造负载观察调度:起两个死循环 `yes`(BusyBox 里可用 `sh -c 'while :; do :; done' &`)、`perf sched record` 几秒后 `perf sched map`(宿主机上跑,看线程在核之间怎么被分配/迁移)
6. 思考题:为什么把一个 `SCHED_FIFO` 优先级 50 的死循环线程绑到单核 QEMU 上,会让该核上其它 `SCHED_OTHER` 任务几乎拿不到 CPU?结合第六节 `for_each_class` 的顺序答

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/sched.h:2449` 的 `struct sched_class` 是机制根本,`:2681` 的 `DEFINE_SCHED_CLASS` 宏和 `:2715` 的 `for_each_class` 看优先级链怎么靠链接器 section 拼出来,`:1119` 的 `struct rq` 和 `:1353` 的 `runqueues` per-CPU 变量看运行队列;`kernel/sched/core.c:5878` 的 `__pick_next_task`、`:6729` 的 `__schedule`、`:6961` 的 `schedule` 是主循环走读的主线;各调度类实例的 `DEFINE_SCHED_CLASS` 在 `stop_task.c:99`/`deadline.c:3362`/`rt.c:2575`/`fair.c:13978`/`ext.c:3403`/`idle.c:553`。
- 关联本站:本篇承接 [10-process-thread-kernel](../../foundations/10-process-thread-kernel.md)——KSE=线程、上下文判定是它的底座;fair 类**内部**的 EEVDF 机制(vruntime/lag/eligibility/deadline)下一篇 [02 CFS/EEVDF 机制](./02-sched-cfs-eevdf) 详讲;CFS 当年是怎么从 O(1) 演进来的、为什么 62 小时重写,看演进史 [03 CFS 诞生](./sched-evolution-03-cfs) 及同系列。
- 命令行:`man chrt`、`man taskset`、`man sched_setattr`、`/proc/sched_debug` 文档(`Documentation/scheduler/sched-debug.rst`),是把抽象机制看活的日常工具。
