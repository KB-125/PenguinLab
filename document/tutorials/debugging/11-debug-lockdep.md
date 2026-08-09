---
title: "lockdep:在死锁发生前抓住它"
slug: debug-lockdep
prerequisites:
  - debug-bug-classification
  - drv-sync
next: []
difficulty: advanced
tags: [debugging, lockdep, deadlock, lock-dependency, prove-locking, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/locking/lockdep-design.html
  - source: third_party/linux（6.19）include/linux/lockdep.h、kernel/locking/lockdep.c
maturity: drafting
related:
  - /tutorials/debugging/00-debug-bug-classification
  - /tutorials/drivers/07-drv-sync
---

> 🔨 **整理中** · 这一篇讲 **lockdep**——内核的锁依赖检查器,运行时追踪所有锁的获取顺序、在**死锁还没真正发生**时就报警(可能的 AB-BA 反转)。素材以 6.19 源码 + kernel.org [lockdep 设计文档](https://docs.kernel.org/locking/lockdep-design.html) 为权威。它是 [00 调试全景图](./00-debug-bug-classification.md) 矩阵里"死锁 → Lockdep"那一格的展开。开启它有性能开销,所以是"开发/QA 必开、生产关闭"的典型工具。

## 做什么

[drv-sync](../drivers/07-drv-sync.md) 讲了 mutex/spinlock 怎么保护临界区,可一旦代码复杂、多处持多个锁,就可能埋下**死锁**隐患:路径 A 按"先锁 X 再锁 Y"的顺序,路径 B 按"先锁 Y 再锁 X"——多数时候两者不会同时跑到,代码看着没问题;可一旦某次它们恰好交错,X-Y 顺序反转,就 AB-BA 死锁,系统挂死。这种 bug 在测试中很难复现,却能在生产某天突然咬人。

**lockdep** 就是治这个的。它是一个运行时检查器(`CONFIG_PROVE_LOCKING`),在你的代码**每次获取锁**时,默默记录"现在持着哪些锁、又要获取哪个锁",据此建一张**锁依赖图**;只要发现图里出现**环**(意味着存在某条"先 X 后 Y、又先 Y 后 X"的反转路径),哪怕这次执行根本没真正死锁、环上两段还没同时跑过——它也立刻报警(带完整栈),把"潜在死锁"在它变成"真死锁"前揪出来。这种"在 bug 变成事故前暴露"的能力,是 lockdep 被称为"内核神器"的原因。

## 要了解什么

### 一、lockdep 的核心:锁类(lock class)与依赖图

lockdep 不追踪"每个锁实例",而是追踪**锁类(lock class)**——按锁**初始化的位置**分类,同一处初始化的锁算同一类(因为它们的获取顺序约束相同)。每个锁类对应一个 `struct lock_class`(lockdep 内部),由 `lockdep_map`(`include/linux/lockdep.h`,每个锁对象都内嵌一个)指向。

每次 `lock_acquire`(lockdep 的核心钩子,所有 `mutex_lock`/`spin_lock` 内部都调它)发生时,lockdep 做两件事:**记录当前任务持有的所有锁**(`held_locks`,每个任务一份),**并据此在依赖图里建边**——"持有 X 时获取 Y" 就画一条 `X → Y` 的边。这样随着内核运行,一张全局的锁依赖图逐渐长出来,反映"内核里所有锁的真实获取顺序"。

### 二、环 = 死锁:为什么能"预测"

图论上,**有环的依赖图 = 存在死锁可能**。比如图里同时有 `X → Y`(某处先 X 后 Y)和 `Y → X`(另一处先 Y 后 X)两条边,就形成环——意味着这两段代码若恰好交错执行,会死锁。lockdep 在每次新加边后,检查图里有没有产生新环(`check_noncircular`);一有,就报警,附带**两段反序的栈**(先 X 后 Y 的栈 + 先 Y 后 X 的栈),让你直接看到是哪两段代码冲突。

这就是 lockdep 的精髓:**它不需要真正死锁就能报警**——只要"两段代码的加锁顺序有矛盾"这件事在运行中被观察到(哪怕没同时执行),环就建出来、警报就响。所以 lockdep 报的是"**possible deadlock**"——可能的、潜在的死锁,提前于真实死锁暴露。

### 三、能抓什么:典型警告类型

lockdep 能抓的死锁/锁误用类别,常见的有:

- **AB-BA 反转**:上面讲的,两段代码锁顺序矛盾。
- **递归加锁(safe self-deadlock)**:同一个任务在持有锁 X 时又获取 X(非递归锁会死锁)。
- **错误的 IRQ 上下文**:在进程上下文拿了锁 X、又在中断里拿同一个锁——如果 X 是 spinlock,中断里拿可能和"持着 X 的进程"形成自死锁。lockdep 会警告"`inconsistent lock state`"、要求加正确的 `_irqsave` 变体。
- **lock inversion**:类似 AB-BA,跨不同子系统的锁顺序冲突。

每类警告都带详尽的栈和"加锁历史",基本一看就知道哪两段代码冲突、该怎么改(通常:统一加锁顺序、或用更细粒度的锁、或修正 IRQ 上下文的锁变体)。

### 四、开启与代价:CONFIG_PROVE_LOCKING

lockdep 由 `CONFIG_PROVE_LOCKING`(在 menuconfig `Kernel hacking → Lock debugging → Lock dependency engine`)开启,它会自动连带开启 `CONFIG_LOCKDEP`。开启后**性能损耗明显**(每次 `lock_acquire` 都要做图操作、每个锁对象多占 `lockdep_map` 空间),所以**开发/QA 内核必开、生产内核关闭**。这和 KASAN、UBSAN 是同一类"开发期开、上线关"的调试工具([00 调试全景图](./00-debug-bug-classification.md) 第二节"测试阶段"那栏)。

`/proc/lockdep`、`/proc/lockdep_stats`、`/proc/lockdep_chains` 是 lockdep 的观察接口——前者列所有已知的锁类、中间的看统计(多少次获取/多少个类)、后者看检测到的锁链。

### 五、读 lockdep 警告

lockdep 警告的格式相对固定:头部一句 `possible deadlock`、然后两段栈对应"两段反序的加锁路径"、外加"已持有的锁"列表。调试时关键是看**这两段栈的加锁顺序**,判断哪个该改(让全局加锁顺序统一)。社区约定:子系统间的锁顺序冲突是内核 bug,必须修;修法通常是调整加锁顺序或拆锁。

## 动手试试

1. menuconfig 开 `CONFIG_PROVE_LOCKING`,重编内核进 QEMU;`cat /proc/lockdep_stats` 看锁类/依赖条数,确认 lockdep 在工作
2. 故意写一个触发 AB-BA 的模块(路径 A 先锁 X 后 Y、路径 B 先 Y 后 X),`insmod` 触发——观察 lockdep 立刻报 `possible deadlock` 带两段栈(即使这次没真死锁)
3. 故意写"在进程上下文拿 spinlock、又在 ISR 里拿同一个 spinlock"(不用 `_irqsave`),观察 lockdep 报 `inconsistent lock state`,改成 `spin_lock_irqsave` 后警告消失
4. `cat /proc/lockdep` 看内核所有锁类(列很长,能直观感受"内核里锁有多少类")
5. 思考题:为什么 lockdep 报的是"possible"而非"actual"?它怎么能在没真死锁时报警?(结合本篇第二节的依赖图 + 环检测)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/lockdep.h`(`struct lockdep_map`、`lockdep_init_map :145`、`lock_acquire`/`lock_release` 宏声明、`lockdep_reset_lock :90`);实现 `kernel/locking/lockdep.c`(`lock_acquire`/`check_noncircular` 环检测/`struct lock_class`/`held_lock`);观察接口 `/proc/lockdep*`;触发点:`mutex_lock`/`spin_lock` 等所有加锁原语内部调 `lock_acquire`。
- kernel.org:[Lockdep design](https://docs.kernel.org/locking/lockdep-design.html) 讲 lockdep 的设计原理(锁类/依赖图/状态机);`Documentation/locking/lockdep-design.txt`。
- 关联本站:本篇是 [00 调试全景图](./00-debug-bug-classification.md) "死锁 → lockdep"的展开;锁的基础(为什么 AB-BA 会死锁、spinlock 的 IRQ 变体)在 [07 drv-sync](../drivers/07-drv-sync.md);"开发期开、上线关"的同类工具有 [03 KASAN](./03-debug-kasan.md)、[07 KCSAN](./07-debug-kcsan.md)。
