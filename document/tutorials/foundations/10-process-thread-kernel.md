---
title: '"我在谁的上下文里跑":进程、线程与 task_struct'
prerequisites:
  - kernel-module-hello
  - kernel-module-params
next:
  - virtual-address-space
difficulty: beginner
tags: [process, thread, task_struct, current, context, arm64, qemu]
architectures: [arm64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch06.md
maturity: drafting
related:
  - /tutorials/foundations/07-kernel-module-hello
  - /tutorials/foundations/09-kernel-module-params
---

## 做什么

上一篇我们给模块装上了"旋钮",写起驱动来终于像点样子了。可模块代码一旦复杂起来,马上会撞上一类特别阴险的 bug——代码明明编译没错、逻辑看着也对,可系统就是说挂就挂、说死锁就死锁,`dmesg` 里留下一串让人摸不着头脑的 call trace。这种 bug 十有八九不是"逻辑错",而是栽在了一个更底层的问题上:**你在内核里写的这段代码,究竟是在"谁的"上下文里执行?** 同样一句"分配点内存"、"睡一会儿等个事件",在进程上下文里天经地义,换到中断上下文里就是一记直奔 panic 的自杀。

所以要往内核深处走,第一个绕不过的概念就是**进程上下文与中断上下文的区别**,以及内核用来描述"一个执行流"的终极结构体 `task_struct`。这一篇我们把这几件事一起拆透:为什么 Linux 是"单内核"意味着"进程自己跑内核代码"、怎么用 `current` 宏知道"我现在是谁"、内核栈到底有多小、以及 `task_struct` 这个庞然大物里装了些什么。和前几篇一样,这里贴的命令输出还是"按代码逻辑应当产生"的预期版本,我们坐到 QEMU 前亲手跑过之后再升级锤炼。

## 要了解什么

### 一、单内核的真相:没有"内核守护进程",是你自己动手

很多人(包括写过不少用户态代码的我们)脑子里都有一张模糊的图:用户进程想干点特权的事,就"通知"一下内核,然后某个神秘的**内核守护进程**跳出来替你把活干了,干完再把结果还给你。这张图非常符合直觉,但在 Linux 上它是**错的**。

Linux 是**单内核**(monolithic)架构,这句话的字面后果是:当你发起一个系统调用(比如 `write`),并不是哪个内核线程出来代劳,**而是你自己的进程切入了内核模式,亲自执行那段内核代码**。CPU 从 EL0(用户态,ARM64 的 Exception Level 0)切到 EL1(内核态),指令指针跳到内核里系统调用的入口,但寄存器里、栈上的"身份"还是你这个进程——`current` 宏指的还是你,你的 `pid` 没变。等你把内核代码跑完、返回用户态,才算是"还魂"回到用户进程。

这件事最戏剧化的展示场景,恰恰就是我们前几篇一直在做的 `insmod`。你在 BusyBox shell 里敲下 `insmod hello.ko`, BusyBox 的 `insmod` 进程发起 `finit_module` 系统调用切入内核,内核解析 `.ko`、加载段、最后**调用你写的 `module_init` 函数**——注意,这个 `init` 函数此刻是在 `insmod` 进程的上下文里跑的,`current` 指向的就是 `insmod` 进程本身,不是什么"内核加载器守护进程"。我们待会儿的实战模块会把这件事亲眼验给你看。

> 这也是为什么内核代码常说自己在"借来的上下文"(borrowed context)里干活——代码是你的,但执行的"躯体"是某个用户进程(或者一个内核线程,或者干脆不属于任何进程的中断)。搞清楚"借的谁的躯壳",是写内核代码最基本的安全意识。

### 二、进程上下文 vs 中断上下文:能不能睡,是生与死的界限

如果仅仅是"进程自己跑内核代码",事情还不算复杂。麻烦的是,内核代码并不都在进程上下文里执行。还有一种执行场景叫**中断上下文**——网卡收到一个包、定时器到期、磁盘完成了一次 DMA,硬件会拉起一根中断信号,CPU 不管此刻在跑什么(哪怕正在内核里跑别的代码),都得立刻暂停、保存现场、跳去执行**中断处理程序**(ISR)。这段 ISR 运行所处的环境,就是中断上下文。

这俩上下文最要命的区别只有一条,但它是生与死的界限:

- **进程上下文**:有"宿主"进程(`current` 有效)。你困了可以睡觉——`msleep`、`mutex_lock`、`GFP_KERNEL` 分配内存,这些会让出 CPU 的操作都允许,调度器会把 CPU 借给别人,稍后再回来唤醒你。
- **中断上下文**:不属于任何进程。你不能睡——一旦你试图睡眠或阻塞,调度器想把你挂起却"找不到一个可以挂起的进程",直接死锁或 panic。

为什么中断里禁止睡觉?原理很直白:调度器切换出去再切换回来,靠的是"恢复某个进程的上下文"。可中断上下文根本不是进程,没有可以保存/恢复的进程上下文,调度器无从下手,系统就僵死了。所以中断处理程序必须**速战速决**,做完事就退出,绝不阻塞。

> ⚠️ **不是"在不在中断里"这么简单**
> 还有一类隐形的中断上下文叫**软中断 / tasklet / 持自旋锁期间**。哪怕你身处一个普通进程发起的系统调用里(看起来是进程上下文),只要你**持有了自旋锁**,你就被算作"原子上下文"的一部分——这时候照样不能睡。判定原则记死一条:**拿锁的时候别睡,中断里别睡**。只要心里没底是不是能睡,就用下一节的宏先查一下。

### 三、怎么查自己在哪种上下文:`in_task()` / `in_atomic()`

好在你不用靠"人肉推理"判断上下文,内核给了现成的宏。我们把 6.19 里这几个宏的定义翻出来:

```c
/* include/linux/preempt.h:130 (6.19) */
# define in_task()   (!((preempt_count() & (NMI_MASK | HARDIRQ_MASK)) | in_serving_softirq()))
```

`in_task()` 返回真,意味着此刻既不在硬中断、也不在软中断、也不在 NMI 里——也就是"**进程上下文**"(task context)。它的判断依据是 `preempt_count()` 这个每 CPU 计数器:内核每进入一层"不可抢占"的上下文(硬中断、软中断、持锁),都会把对应的位标记进去,`in_task()` 就是检查这些位全是 0。

判定"能不能睡"更宽口径的宏是 `in_atomic()`:

```c
/* include/linux/preempt.h:184 (6.19) */
#define in_atomic()   (preempt_count() != 0)
```

`in_atomic()` 返回真,意味着 `preempt_count` 非零——**任何**让抢占失效的因素(硬中断、软中断、NMI、**自旋锁**)都算。所以 `in_atomic()` 比 `in_task()` 覆盖面更广:持自旋锁时 `in_task()` 可能还是真(没进中断),但 `in_atomic()` 已经是真了——它更接近"能不能睡"的真实答案。

这俩宏在写驱动时用处很大:你写了一段可能被多种路径调用的代码,想稳妥地决定"这里能不能 `kmalloc(GFP_KERNEL)`",就 `if (in_atomic())` 兜底走 `GFP_ATOMIC`。不过要提醒一句——`in_atomic()` 不是万能判据,它**不覆盖"持有 mutex 但能睡"**这种场景(mutex 会让任务可调度),但在"能不能用 GFP_KERNEL"这个最常见问题上它够用了。

> 🕳️ **差点踩中的坑**
> 整理这一篇时,我们第一次用 `grep '#define in_task\b'` 查这个宏,没匹配到,差点判定"`in_task()` 在 6.19 已移除"写进版本演进。多 grep 一次全仓才发现:`in_task()` 是条件编译定义,`#` 和 `define` 之间有缩进空格(`# define in_task()`,preempt.h:130),正则限太死就漏了。**6.19 里它健在**。这件事本身是个教训——"对照源码校订"不能只 grep 一次就下结论。

### 四、`task_struct`:内核眼里的"身份证"

那么内核用什么东西来描述"一个执行流"?答案是那个大到离谱的结构体 **`task_struct`**。内核眼里,每一个活着的线程——不管是用户进程的主线程、多线程进程的子线程,还是一个纯粹的内核线程(`kworker`、`ksoftirqd` 那些)——都对应**一个** `task_struct` 实例。

注意上面那句话里"线程"这个词。Linux 内核**不区分**进程和线程:**线程才是调度和管理的基本单位**,所谓"进程"在内核看来不过是"共享了地址空间和文件描述符表的一组线程"。每个线程一个 `task_struct`,一个进程里的所有线程各自有自己的 `task_struct`,只是它们指向同一份内存描述符(`mm_struct`)。

`task_struct` 这个结构体有多大?我们拿 6.19 源码量了一下:它的定义从 `include/linux/sched.h:820` 开始,一直延伸到第 1915 行才结束——**光是字段定义就将近 1100 行**。这里头什么都有:PID/TGID、调度信息(vruntime、优先级、策略)、内存描述符指针(`mm`)、打开的文件表指针(`files`)、信号处理、CPU 时间统计、cgroup 归属、甚至"这个线程最近是不是经常在睡觉"……它是内核对"一个执行流"能想到的全部属性的集合。

> 为什么这个结构体长成这样?因为它本质上是**操作系统对现实世界执行流的一个抽象**。当我们在代码里写下 `current->pid`,我们其实是在向内核询问:"现在正在 CPU 上跑的那个执行流,它的编号是多少?"——抽象层级越高,结构体越胖,这是必然代价。

### 五、`current` 宏:"我是谁",一查便知

既然内核里同时挂着成百上千个 `task_struct`(一个跑着 BusyBox 的 QEMU 虚拟机里也有几十个),我的内核代码此刻正在跑,我怎么知道"我自己"是哪一个?内核给了一个宏:`current`。

```c
#include <linux/sched.h>

current->pid;        /* 当前执行流的 PID(内核语义,其实是线程 ID) */
current->comm;       /* 当前执行流的名字(可执行文件名,截断到 16 字节) */
current->mm;         /* 当前(进程)的内存描述符 */
```

你可以把 `current` 理解成 C++ 里的 `this` 指针,只不过它指向的不是对象,而是"**当前正在 CPU 上跑的这个执行流**的 `task_struct`"。

这个宏怎么实现?**严重依赖架构**。x86_64 用的是 per-CPU 变量(每个 CPU 核各有自己的一份 `current`,访问几乎不要钱);ARM64 更狠,我们直接看 6.19 的实现(`arch/arm64/include/asm/current.h`):

```c
static __always_inline struct task_struct *get_current(void)
{
	unsigned long sp_el0;

	asm ("mrs %0, sp_el0" : "=r" (sp_el0));

	return (struct task_struct *)sp_el0;
}

#define current get_current()
```

这段代码短小精悍,信息量却极大。它干的事是:读 ARM64 的 `SP_EL0` 寄存器,直接当成 `task_struct *` 返回。`SP_EL0` 是"EL0(用户态)的栈指针寄存器"——可内核跑在 EL1,用 `SP_EL1` 当自己的栈指针,那 `SP_EL0` 这个寄存器在 EL1 时干嘛用?**ARM64 内核把它挪用成了一个"当前任务指针"的专用寄存器**:每次内核调度切换任务时,调度器会把新任务的 `task_struct` 指针写进 `SP_EL0`,于是内核里任何代码想拿 `current`,一条 `mrs` 指令读寄存器就行,连内存访问都不用,快到极致。

这就是原始素材里那句"ARM64 专门腾出一个通用寄存器来存 `current`"的精确含义——具体腾的是 `SP_EL0`(它在内核态闲置,正好废物利用),而这个设计的代价是内核得保证:调度切换时维护好 `SP_EL0`、中断进入时保存它、中断退出时恢复它。这是架构与内核的一份默契。

### 六、每个线程都有**两个**栈,而且内核栈小得吓人

特权级的划分带来一个容易被忽略的后果:**一个用户空间线程,其实同时拥有两个栈**。

一个是**用户栈**,跑用户代码时用,你在 C 函数里定义的局部变量就压在这里。另一个是**内核栈**,一旦线程通过系统调用陷入内核、或触发异常(比如缺页),CPU 切到内核态,栈指针就换成这个内核栈,此后所有内核函数调用、内核里的局部变量,都压在这块小得多的栈上。唯一的例外是**纯内核线程**(`kworker` 那种),它们从出生就在内核,没有用户空间,所以只有内核栈。

那内核栈有多大?小到让人紧张。我们查 6.19 ARM64 的定义(`arch/arm64/include/asm/memory.h`):

```c
#define MIN_THREAD_SHIFT   (14 + KASAN_THREAD_SHIFT)   /* 14,开 KASAN 时 +1 */
...
#if (MIN_THREAD_SHIFT < PAGE_SHIFT)
#define THREAD_SHIFT       PAGE_SHIFT
#else
#define THREAD_SHIFT       MIN_THREAD_SHIFT
#endif
...
#define THREAD_SIZE        (UL(1) << THREAD_SHIFT)
```

这段逻辑翻译过来:`THREAD_SHIFT = max(PAGE_SHIFT, 14)`。ARM64 的页大小可配(4KB / 16KB / 64KB):4KB 页(`PAGE_SHIFT=12`)时,`THREAD_SHIFT = max(12, 14) = 14`,`THREAD_SIZE = 1 << 14 = 16KB`;16KB 页时同样是 16KB;只有 64KB 页时栈才会涨到 64KB。所以在最常见的配置下,**ARM64 内核栈就是 16KB**——四个页。

16KB 在内核里要塞下整个系统调用的调用链、所有内核函数的栈帧、中断嵌套、可能还有异常处理,空间紧得难以想象。这条铁律的直接后果是:

> ⚠️ **内核里绝不放大数组**
> 写用户态程序时,在函数里随手 `char buf[4096];` 是家常便饭。**在内核里这是自杀**——一个 4KB 的局部数组就吃掉内核栈的四分之一,稍微深一点的调用链加上中断嵌套,栈瞬间爆掉,覆盖掉栈底的 `thread_info` 或相邻关键数据,后果是难以排查的崩溃或数据损坏。内核里需要大块内存,**必须**用 `kmalloc`/`kzalloc`/`vmalloc` 从堆上分配,绝对不能在栈上贪便宜。这也是为什么你看内核代码里到处是 `GFP_KERNEL` 分配——栈不够用是写在基因里的约束。

### 七、中断还有自己的栈:IRQ Stack

那既然内核栈这么小,中断处理程序(ISR)又往往来得急、嵌套深,万一 ISR 自己也很吃栈,把被中断进程的内核栈踩塌了怎么办?内核对此有专门设计:**很多架构给每个 CPU 核心单独配了一个独立的中断栈(IRQ stack)**,ISR 进入时切到这个栈上执行,执行完再切回去,这样 ISR 的栈消耗就不会侵犯无辜进程的内核栈。x86_64 和 ARM64 都有这套机制(具体是否启用取决于配置,比如 ARM64 的 `IRQ_STACKS`)。

所以一个 CPU 核上,实际的"栈"其实是一摞:当前进程的内核栈(进程上下文时)、每核的 IRQ 栈(硬中断时)、还有软中断自己的栈、NMI 栈……它们各管一段,内核靠 `preempt_count` 和上下文切换逻辑保证不会串台。从我们"写模块"的角度,记住一条就够:**你写的普通驱动函数大多跑在进程上下文(用进程内核栈);中断处理程序跑在中断上下文(用 IRQ 栈),两者都小,都禁不起大数组。**

### 八、查看与遍历:`/proc/PID/stack` 与 `for_each_process`

调试时,"栈"几乎是命根子。想知道一个进程此刻卡在内核哪一步?读它的内核栈回溯:

```bash
~ # cat /proc/<pid>/stack
[<0>] do_wait+0x184/0x340
[<0>] kernel_wait4+0xaf/0x150
[<0>] __do_sys_wait4+0x89/0xa0
[<0>] __x64_sys_wait4+0x1e/0x30
[<0>] do_syscall_64+0x5c/0x90
[<0>] entry_SYSCALL_64_after_hwframe+0x63/0xcd
```

> ⚠️ **待亲测**:上面这段是 x86_64 上的典型样例,我们会在 QEMU ARM64 上 `cat /proc/<某个 BusyBox 进程>/stack`,把 ARM64 的真实回溯贴回(函数名会是 `el0_svc`→`invoke_syscall` 那一套)。`[<0>]` 是 KASLR 把地址清零防泄露,不是 bug。

读法是**从下往上**:最下面 `entry_SYSCALL_64...` 是入口,最上面 `do_wait` 是它现在正卡在的函数。`+0x184/0x340` 表示"停在这个函数内部偏移 `0x184` 处,整个函数总长 `0x340`"。

那如果想反过来——从内核代码里主动遍历系统所有线程呢?内核提供了宏(`include/linux/sched/signal.h`):

```c
#include <linux/sched/signal.h>

struct task_struct *p, *t;

/* 只遍历每个进程的"主线程"(线程组组长) */
for_each_process(p) { ... }                 /* signal.h:639 */

/* 遍历系统里所有线程,包括每个进程的子线程 */
for_each_process_thread(p, t) { ... }       /* signal.h:662 */
```

注意 `for_each_process` 严格来说只走"线程组的组长"(用户空间意义上的"进程"),想覆盖所有线程(包括多线程进程的子线程)得用 `for_each_process_thread`。这个区别引出了下一个话题。

### 九、PID 和 TGID:内核的"PID"其实是线程

这里有个让新手懵圈的术语错位,必须讲清楚。在内核数据结构里:

- **`pid`(内核语义)**:每个 `task_struct` 都有一个独一无二的编号——这是**线程**的 ID。哪怕一个进程里有 10 个线程,它们就有 10 个不同的 `pid`。
- **`tgid`(Thread Group ID)**:线程组 ID。同一个进程里的所有线程共享一个 `tgid`,等于主线程(组长)的 `pid`。

而我们用户空间用 `ps`、`kill` 看到的"进程 ID",其实对应的是**`tgid`**,不是内核的 `pid`!用户空间的"线程 ID"(比如 `ps -L` 里的 `LWP`/`TID`)才对应内核的 `pid`。

所以读内核代码遇到 `current->pid`,要意识到它说的是**线程**编号;想拿用户空间意义上的"进程号",得读 `current->tgid`(或用 `task_tgid_nr(current)` 这个 helper)。一个单线程进程里,组长就是唯一线程,`pid == tgid`,两者相等,看着没区别;一旦多线程,这个区分就关键了。原始素材提到 `ps -LA` 第一列其实是 TGID、第二列 LWP 才是内核 PID,正是这个道理。

### 十、实战:`current_affairs` 模块

讲了一通理论,该上手验了。我们写一个极简模块,在 `init` 和 `exit` 里各打印一次"我现在在什么上下文、我是谁"——把前几节的抽象概念落到可观察的现象上:

```c
#include <linux/init.h>
#include <linux/module.h>
#include <linux/printk.h>
#include <linux/sched.h>
#include <linux/preempt.h>

static void show_ctx(const char *tag)
{
    if (in_task()) {
        /* 进程上下文:打印当前执行流的名字、内核 pid、用户空间看到的 tgid */
        pr_info("%s: process context :: comm=%s pid=%d tgid=%d\n",
                tag, current->comm,
                task_pid_nr(current), task_tgid_nr(current));
    } else {
        /* 中断上下文:本模块的 init/exit 不该走到这里 */
        pr_alert("%s: interrupt context! (unexpected)\n", tag);
    }
}

static int __init current_affairs_init(void)
{
    show_ctx("init");
    return 0;
}

static void __exit current_affairs_exit(void)
{
    show_ctx("exit");
}

module_init(current_affairs_init);
module_exit(current_affairs_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab");
MODULE_DESCRIPTION("explore current / task_struct / in_task");
```

模块逻辑很简单:`init` 和 `exit` 各调一次 `show_ctx`,后者用 `in_task()` 判定上下文,再用 `current` 打印身份。`task_pid_nr()` 和 `task_tgid_nr()` 是访问 `current->pid`/`current->tgid` 的推荐 helper(比直接读字段更稳,跨命名空间也正确)。Makefile 沿用本藤套路,`obj-m += current_affairs.o` 加 `include ../../common/Makefile.arch` 即可。

加载它,看 `dmesg`:

```bash
~ # insmod current_affairs.ko
~ # dmesg | tail -1
[   10.441233] current_affairs: init: process context :: comm=insmod pid=58 tgid=58

~ # rmmod current_affairs
~ # dmesg | tail -1
[   17.802516] current_affairs: exit: process context :: comm=rmmod pid=61 tgid=61
```

> ⚠️ **待亲测**:上面的 `dmesg` 输出是按预期整理的(具体 pid/tgid 数字视运行环境而定)。我们会拿到 QEMU ARM64 上跑一遍,贴回真实的 `comm` 和编号。

注意 `comm` 那一栏——`init` 时打印的是 **`insmod`**,`exit` 时是 **`rmmod`**!这正是第一节"单内核真相"的实锤:`init` 函数执行那一刻,`current` 指向的是发起系统调用的 `insmod` 进程本身,根本没有别的"内核守护进程"代劳;`exit` 时同理指向 `rmmod`。一句 `current->comm`,把"进程自己跑内核代码"这件事验得明明白白。两个上下文判定都落在 `process context` 分支,也符合预期——`init`/`exit` 本来就是进程上下文里跑的,不可能进中断分支。

## 动手试试

> example 骨架随亲测落到 `example/mini/current_affairs/`,结构同 `00-kernel_module_hello/`。下面是 QEMU 上要逐条验的清单。

1. 写本篇第十节的 `current_affairs.c` 与 `Makefile`,`make` 出 `.ko` 并塞进 QEMU
2. `insmod current_affairs.ko`,`dmesg` 确认 `init` 打印的是 `comm=insmod`、且上下文是 `process context`——验证"单内核:进程自己跑 init"
3. `rmmod current_affairs`,`dmesg` 确认 `exit` 打印 `comm=rmmod`、上下文仍是 `process context`
4. 在 QEMU 里 `cat /proc/<pid>/stack` 看一个 BusyBox 进程的内核栈回溯,对照第八节学读栈(从下往上、`+offset/size` 含义)
5. 进阶:在 `init` 里用 `in_atomic()` 替换 `in_task()` 重新编译加载,观察在 `init` 这种进程上下文(未持锁)里两者输出是否一致(预期一致,因为 `preempt_count` 此时为 0)
6. 进阶:给 `current_affairs` 加一个 `for_each_process_thread(p, t)` 遍历,打印系统里所有线程的 `comm`/`pid`/`tgid`,验证"多线程进程里 pid 各异、tgid 相同"这条结论(可对照 BusyBox 的 `ps -LA`)
7. 思考题:为什么在 `init` 函数里定义一个 `char buf[8192];`(8KB 局部数组)是个坏主意?结合第六节的内核栈尺寸算一下它占了 ARM64 16KB 内核栈的多大比例

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,Linux 6.19.9):`include/linux/sched.h:820` 的 `struct task_struct` 定义是认识执行流的根本;`arch/arm64/include/asm/current.h` 看 `current` 宏如何用 `SP_EL0` 实现;`include/linux/preempt.h:130/184` 看 `in_task()`/`in_atomic()` 的判定;`include/linux/sched/signal.h:639/662` 看 `for_each_process`/`for_each_process_thread`;`arch/arm64/include/asm/memory.h:121` 看 `THREAD_SIZE` 的推导(为什么 ARM64 内核栈至少 16KB)。
- 命令行:`man ps` 看 `-L`(显示线程/LWP)与 `-A` 的输出列含义,对照理解内核 `pid`/`tgid` 与用户空间 PID/TID 的对应;`cat /proc/<pid>/stack` 与 `cat /proc/<pid>/status` 看进程在内核里的身份与状态。
- 关联本站:本篇的 `current_affairs` 模块依赖 [07-kernel-module-hello](07-kernel-module-hello.md) 里打通的模块开发链路(`.ko` 编译、`insmod`/`dmesg` 验证);"中断上下文不能睡"的更多后果——`GFP_ATOMIC` vs `GFP_KERNEL`、原子上下文里的打印纪律——会贯穿后续驱动与调试藤(如 [debug-printk](../debugging/01-debug-printk.md));而 `task_struct` 里和内存描述符 `mm_struct` 相关的字段,下一篇 [virtual-address-space](11-virtual-address-space.md) 会接着展开。
