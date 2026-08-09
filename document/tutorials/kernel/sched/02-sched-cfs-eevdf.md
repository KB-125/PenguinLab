---
title: "CFS/EEVDF:fair 类内部怎么挑下一个任务"
slug: sched-cfs-eevdf
prerequisites:
  - sched-overview
next:
  - sched-evolution-04-eevdf
difficulty: advanced
tags: [scheduler, eevdf, cfs, vruntime, eligibility, deadline, rbtree, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch10.md
maturity: drafting
related:
  - /tutorials/kernel/sched/01-sched-overview
  - /tutorials/kernel/sched/sched-evolution-04-eevdf
---

> 🔨 **整理中** · 这篇是调度器藤的第二篇**机制主教程**——上一篇 [01 调度器框架](./01-sched-overview) 讲清楚了"谁上 CPU"的骨架(调度类、运行队列、主循环),但留了一个洞:**`fair_sched_class` 内部到底按什么规则挑下一个任务?** 这一篇就把那个洞补上。6.19 的答案不再是很多人记忆里的"老 CFS 选 vruntime 最小者",而是自 6.6 合入、6.19 现行的 **EEVDF**(Earliest Eligible Virtual Deadline First,最早合格虚拟截止期优先)。所有源码行号对照本仓库 `third_party/linux/` 的 6.19.9 校订;`/proc/sched_debug` 的实际输出在 QEMU 亲手验过之前标"待亲测"。

## 做什么

上一篇末尾我们停在 `pick_next_task` 把球踢给 `fair_sched_class->pick_next_task` 的那一刻——主循环知道"该轮到 fair 类发言了",但 fair 类怎么从自己那一堆 `SCHED_NORMAL` 任务里挑出下一个,当时我们一句"按 EEVDF"带过了。这一篇就来把 EEVDF 这个词彻底拆开:它**为什么**取代了老的 CFS 选取逻辑?它要解决的"公平"到底是什么?那三个核心概念——**虚拟运行时间 vruntime**、**资格与欠债 lag/eligibility**、**虚拟截止期 deadline**——各自怎么算、怎么用?最后 `__pick_eevdf` 这个选择函数又把它们怎么缝到一起?读完这一篇,你应该能在 `kernel/sched/fair.c` 的源码里跟上 EEVDF 的每一次心跳,而不是对着 `update_entity_lag`、`avg_vruntime` 这些名字发呆。

## 要了解什么

### 一、为什么不是"选 vruntime 最小者"了:CFS 的老问题

先把很多老资料里的那个印象纠正掉:**6.19 的 fair 调度器不再是"维护一棵按 vruntime 排序的红黑树、永远挑最左节点"那么简单了**。这个经典 CFS 逻辑(在 [演进史 03 CFS 诞生](./sched-evolution-03-cfs) 里讲过它 2.6.23 的原始形态)在工程上踩到了几个长期痛点:

最典型的痛点是**睡眠任务的公平性**。一个任务睡很久后醒来,它的 vruntime 还停留在很久以前的旧值——往往远小于运行队列当前的 `min_vruntime`。老 CFS 为了不让它"凭借陈旧的低 vruntime 霸占 CPU 补差价",会把它唤醒后做一次 `min_vruntime` 对齐,但这种调整是启发式的、不精确的,在不同负载下要么"补偿不够"(刚醒的任务吃亏)、要么"补偿过头"(刚醒的任务抢走太多),而且对延迟敏感的任务体验很差。

EEVDF(1995 年就被提出的学术算法,Linux 在 6.6 由 Peter Zijlstra 合入替换 CFS 选取逻辑)用一套更严谨的"**资格(eligibility)+ 截止期(deadline)**"框架取代了这套启发式:它不光看"谁跑得少",还显式追踪"谁被亏欠了多少"(lag),并给每个任务一个虚拟截止期,挑人时同时考虑这两者。结果是对睡眠唤醒、CPU 密集与交互混合负载都更稳,延迟特性也更可预期。下面我们把这套框架的三个零件一个一个装上去。

### 二、vruntime:虚拟运行时间,公平的尺子

第一个零件是 **vruntime**(虚拟运行时间),EEVDF 沿用了 CFS 的这个概念。每个调度实体 `sched_entity` 里都存着一个 `vruntime`(`include/linux/sched.h` 里 `struct sched_entity` 的 `u64 vruntime` 字段),它衡量"这个任务**在公平意义下**已经消耗了多少 CPU"。

为什么不能直接用实际运行时间?因为任务有优先级(nice 值)——nice 值低(高优先级)的任务应该用同样的实际时间换更少的 vruntime 增长,这样它才"值得"被多选几次。这个"实际时间→虚拟时间"的换算就是 `calc_delta_fair()` 做的事:它按任务的权重(由 nice 值映射来的 `load_weight`)把实际运行增量缩放成虚拟增量。换算的结果是:**所有任务,无论 nice 值高低,只要 vruntime 涨得一样多,就被视为"消耗了同等公平份额的 CPU"**——只是高优先级任务用更少的 vruntime 涨幅就兑到了同样的实际运行时间。

vruntime 在哪儿被累加?在 `update_curr()`(`kernel/sched/fair.c:1285`)里。这个函数是 fair 类的"账房先生",每次时钟或调度入口都会调它,把当前任务从上次记账到现在又跑了的实际时间(`delta_exec`)折算成虚拟时间、加到 `curr->vruntime` 上:

```c
/* kernel/sched/fair.c:1285 起(简化) */
static void update_curr(struct cfs_rq *cfs_rq)
{
    s64 delta_exec = update_se(rq, curr);              /* 算出又跑了多少实际时间 */
    if (unlikely(delta_exec <= 0))
        return;

    curr->vruntime += calc_delta_fair(delta_exec, curr);   /* 折算成虚拟时间,累加 */
    resched = update_deadline(cfs_rq, curr);           /* 顺手检查时间片/截止期 */
    ...
}
```

记住这一行 `curr->vruntime += calc_delta_fair(...)`,它是 vruntime 的唯一增长点,也是后面所有公平性判断的地基。

### 三、avg_vruntime:EEVDF 的"当前公平线"

光有每个任务各自的 vruntime 还不够,得有一个"**参照系**"来判断谁跑多了、谁跑少了。EEVDF 用的参照系是运行队列的**加权平均 vruntime**,也就是 `avg_vruntime()`(`kernel/sched/fair.c:715`):

```c
u64 avg_vruntime(struct cfs_rq *cfs_rq);
```

你可以把它理解为:**把当前 cfs_rq 里所有可运行任务的 vruntime,按各自的权重加权平均,得到的一个"虚拟时钟读数"**。它代表的是"如果绝对公平,此刻每个任务的 vruntime 理论上应该停在的位置"——一条动态的"当前公平线"。

源码里有一条很关键的注释(`fair.c:704` 附近):"avg_vruntime() + 0 must result in entity_eligible() := true"——意思是,一个 vruntime 恰好等于 `avg_vruntime` 的任务,是"刚好合格"的边界。这条性质把 `avg_vruntime` 和下一节的 eligibility 判据死死绑在了一起:`avg_vruntime` 就是衡量"够不够格"的那把尺子上的零点。

> 💡 **从 min_vruntime 到 avg_vruntime**
> 老 CFS 用的是 `cfs_rq->min_vruntime`(队列里最小的 vruntime,红黑树最左节点的值)做参照,主要用途是"让新唤醒/迁移进来的任务 vruntime 不至于太离谱"。EEVDF 改用加权平均的 `avg_vruntime`,它更能反映"整体公平位置",不会因为队列里有一个 vruntime 特别低的边缘任务就把参照系拉偏。`struct cfs_rq` 里仍然保留了 `min_vruntime` 字段(用于跨核迁移等场景),但**判定资格**用的是 `avg_vruntime`。

### 四、lag 与 eligibility:谁够格上 CPU

现在有了参照系,就能定义"**资格**(eligibility)"了。每个调度实体心里记着一笔"**欠债**",EEVDF 术语叫 **lag**(或 vlag,虚拟 lag):

```c
/* kernel/sched/fair.c:767 update_entity_lag() 的核心一行(:774) */
vlag = avg_vruntime(cfs_rq) - se->vruntime;
```

这行的意思非常直白:**任务的 lag = 公平线 − 自己的 vruntime**。

- 如果 `se->vruntime < avg_vruntime`(任务跑得比公平线少),`vlag > 0`——任务被**亏欠**了,它"应得的 CPU"还没给够,理应优先补上。
- 如果 `se->vruntime > avg_vruntime`(任务跑得比公平线多),`vlag < 0`——任务**多占**了,暂时不该再被选中。

判定一个任务**够不够格(eligible)**靠的就是这个符号,落在 `entity_eligible()`(`fair.c:813`):

```c
int entity_eligible(struct cfs_rq *cfs_rq, struct sched_entity *se);
```

它返回真,意味着这个任务此刻"有资格"上 CPU。直观的判据(忽略权重的简化版)就是 **`vlag >= 0`**——亏欠或刚好持平的才够格;多占的请先让一让。

> ⚠️ **eligibility 解决了 CFS 的老毛病**
> 回到第一节那个"睡眠任务唤醒后霸占 CPU"的痛点:在 EEVDF 里,一个睡很久醒来的任务,它的 vruntime 固然是旧的低值,但它的 **lag 也因此被重新核算**——`update_entity_lag` 会在它入队时把 lag 调到合理位置,而不是任由一个陈旧 vruntime 直接去抢。如果它的 lag 算下来已经不够"亏欠"了,`entity_eligible` 直接判它不够格,它就排不上。这套机制把"睡眠补偿"从启发式调整变成了精确的 lag 追踪,这正是 EEVDF 替换 CFS 的核心收益。

### 五、deadline:虚拟截止期与时间片

资格只回答了"**能不能**上",EEVDF 还要回答"**什么时候必须让位**"。这就是第三个零件——**虚拟截止期 deadline**。

每个调度实体除了 vruntime,还存着一个 `deadline`(`struct sched_entity` 的 `u64 deadline` 字段)。它的含义可以粗略理解为"这个任务在虚拟时间轴上,**这一轮运行配额的到期点**"。每次任务被选中、跑了一段时间后,`update_deadline()`(`fair.c:1117`)会检查:当前任务的 vruntime 是不是已经推进到、甚至越过了它的 deadline——如果是,就给它打上"需要重调度"的标记(触发上一篇讲的 `TIF_NEED_RESCHED` 路径),让 `__schedule` 重新选人。

```c
/* kernel/sched/fair.c:1117 */
static bool update_deadline(struct cfs_rq *cfs_rq, struct sched_entity *se);
```

跟 deadline 配套的是**时间片 slice**(`struct sched_entity` 里的 `u64 slice`,以及 `min_slice`/`max_slice`/`custom_slice` 等约束字段)。时间片不是固定值,而是按任务的权重、以及运行队列的负载情况算出来的——高优先级(nice 值低、权重大)的任务会拿到更大的 slice,能在一次轮到它时跑得更久。deadline 在某种意义上就是把"这一轮 slice 折算成虚拟时间"后加到当前基准上得到的截止点。

这三件套——vruntime(已消耗的公平)、lag/eligibility(够不够格)、deadline(何时让位)——构成了 EEVDF 对一个调度实体的完整刻画。

### 六、`__pick_eevdf`:把三件套缝起来的选择算法

有了 vruntime、eligibility、deadline,选择下一个任务的算法就可以一句话讲完,而它正是 EEVDF 名字的字面含义——**Earliest Eligible Virtual Deadline First**:

> 在所有 **eligible**(够格)的任务里,挑 **deadline 最早**的那一个。

落地的函数是 `__pick_eevdf()`(`kernel/sched/fair.c:1010`),对外封装成 `pick_eevdf()`(`:1081`),后者就是 fair 调度类被主循环问到时,实际交出去的"挑人"实现:

```c
/* kernel/sched/fair.c:1010 起(语义简化) */
static struct sched_entity *__pick_eevdf(struct cfs_rq *cfs_rq, bool protect)
{
    /* 在红黑树里找第一个 eligible 的节点;
       eligible 集合中,deadline 由树的结构保证按升序,
       所以第一个 eligible 就是 "earliest eligible virtual deadline"。 */
    ...
}

/* :1081 */
static struct sched_entity *pick_eevdf(struct cfs_rq *cfs_rq)
{
    ... return __pick_eevdf(cfs_rq, ...);
}
```

这里有一个工程上的精妙点:6.19 的 fair 队列仍然用**红黑树**组织(`struct sched_entity` 里的 `rb_node run_node`),但**排序键改成了 deadline**(老 CFS 是按 vruntime 排)。这样红黑树的中序遍历天然就是 deadline 升序,`__pick_eevdf` 只要从中序起点开始,跳过那些不够格的(`entity_eligible` 返回假),找到的第一个 eligible 节点,天然就是"eligible 集合里 deadline 最早的"——算法名的前两个词(Earliest Eligible)和后两个词(Virtual Deadline First)在这一次查找里同时满足了。

> 💡 **算法名拆解**
> EEVDF = **E**arliest **E**ligible **V**irtual **D**eadline **F**irst。把它劈成两半:"Eligible" 是资格审查(用 lag/vlag,第四节),"Virtual Deadline First" 是在通过审查的人里按截止期排队(第五节+本节红黑树)。两道关卡,先资格后截止期,这就是 EEVDF 的全部。它比老 CFS 的"只看 vruntime 最小"多了一道资格闸门,从而精确处理了睡眠唤醒、权重悬殊等老 CFS 靠启发式勉强应付的场景。

### 七、一次 `update_curr` 的全貌:vruntime 涨、deadline 查、必要时让位

把前面几节串起来,看一个任务在 CPU 上跑时,fair 类每一次给它"记账"都发生了什么。时钟中断或调度入口会调 `update_curr(cfs_rq)`(`fair.c:1285`),它依次干这几件事:

1. `delta_exec = update_se(rq, curr)`——算出距离上次记账又跑了多少**实际**纳秒。
2. `curr->vruntime += calc_delta_fair(delta_exec, curr)`——把实际时间按权重折算,累加到 vruntime(第二节)。
3. `resched = update_deadline(cfs_rq, curr)`——检查 vruntime 是否到达 deadline(第五节);若到了,返回需要重调度。
4. 若 `resched` 为真,给当前任务打 `TIF_NEED_RESCHED`,等下一个抢占点就触发 `__schedule` → `pick_eevdf` 重新选人。

所以 vruntime 的增长、deadline 的到期、重调度的触发,全在 `update_curr` 这一次调用里串成了因果链。理解了这条链,就理解了 fair 类"为什么会换人、什么时候换人"的机理;至于"换给谁",就是上一节的 `__pick_eevdf` 按资格+截止期挑了。

### 八、`sched_entity` 字段速查

最后把这一篇涉及的 `struct sched_entity` 字段(`include/linux/sched.h`)归个总,方便读源码时对照:

| 字段 | 类型 | 含义 |
|:---|:---|:---|
| `load` | `struct load_weight` | nice 值映射来的权重,决定 vruntime 缩放与时间片大小 |
| `run_node` | `struct rb_node` | 红黑树节点,挂在 cfs_rq 的树上(按 deadline 排) |
| `vruntime` | `u64` | 虚拟运行时间,公平的尺子(`update_curr` 累加) |
| `vlag`* | `u64` | 虚拟欠债;`!on_rq` 时存的是 vlag,入队后语义切换(见字段注释) |
| `deadline` | `u64` | 本轮运行的虚拟截止期 |
| `slice` | `u64` | 本轮时间片(按权重算);`min_slice`/`max_slice`/`custom_slice` 约束其范围 |
| `on_rq` | `unsigned char` | 是否在运行队列里 |
| `rel_deadline` | `unsigned char` | deadline 相关的相对/初值标记 |

> ⚠️ **`vlag` 字段的语义会切换**
> 读源码时留意 `sched_entity` 那个看似普通的字段——它的含义随 `on_rq` 状态而变(字段注释原话大意:"!on_rq 时是 vlag;cfs_rq->curr == se 时是 vprot")。这是 EEVDF 实现里一个会让初学者困惑的细节:同一个内存位置,在不同状态下承载不同语义,以节省结构体空间。看到 `se->vlag` 时,先确认这个 `se` 当前的状态再解读其值。

## 动手试试

> 这一篇的验证主要靠 `/proc/sched_debug`(需 `CONFIG_SCHED_DEBUG`)和权重相关的 `chrt`/`nice`,把抽象的 vruntime/deadline 看成具体数字。

1. `cat /proc/sched_debug` 找到某个 `SCHED_NORMAL` 任务,看它的 `vruntime`、`exec_max`、所在 `cfs_rq` 的 `min_vruntime`/`avg_vruntime`(若已暴露),对照本节理解每个数
2. 起两个死循环任务,给其中一个 `renice -n -5`、另一个 `renice -n +5`,观察 `vruntime` 增长速率的差异(高权重 vruntime 涨得慢)、以及它们各自拿到的实际 CPU 占比(`top`)
3. 进阶:对照 `kernel/sched/fair.c:715` 的 `avg_vruntime`、`:767` 的 `update_entity_lag`、`:813` 的 `entity_eligible`、`:1010` 的 `__pick_eevdf` 通读一遍 EEVDF 选择路径,画出从"任务入队"到"`pick_eevdf` 选中它"的字段流转图(vruntime→lag→eligibility→deadline→红黑树)
4. 思考题:一个 nice 0 的 CPU 密集任务和一个刚从长睡眠醒来的同 nice 任务,在 EEVDF 下谁会先被选中?用第四节的 lag/eligibility 解释(对照老 CFS 下"睡眠者霸占 CPU"的现象,体会 EEVDF 的改进)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):EEVDF 核心全在 `kernel/sched/fair.c`——`:715 avg_vruntime`、`:767 update_entity_lag`(`vlag = avg_vruntime - se->vruntime` 在 `:774`)、`:813 entity_eligible`、`:1010 __pick_eevdf`、`:1081 pick_eevdf`、`:1117 update_deadline`、`:1285 update_curr`(`vruntime += calc_delta_fair` 在 `:1305` 附近);`struct sched_entity` 的 vruntime/vlag/deadline/slice 字段在 `include/linux/sched.h`;`struct cfs_rq` 的 `avg_vruntime`/`min_vruntime` 也在同文件。
- 关联本站:本篇紧接 [01 调度器框架](./01-sched-overview)(把 `fair_sched_class->pick_next_task` 的内部展开);EEVDF 是怎么从老 CFS 演进、6.6 合入的,看演进史 [04 EEVDF](./sched-evolution-04-eevdf);调度单元=线程的底座在 [10-process-thread-kernel](../../foundations/10-process-thread-kernel.md)。
- 算法原典:EEVDF 最早见于 Stoica 等人 1995 年的论文 *A Fair Scheduling Algorithm for Real-Time Systems*(读源码时可作为算法语义的参照,数学细节不展开);Peter Zijlstra 在 6.6 合入 EEVDF 的邮件列表讨论是理解"为什么换掉 CFS"的一手材料。
- 调试:`Documentation/scheduler/sched-debug.rst` 讲 `/proc/sched_debug` 各字段含义;`perf sched` 系列把 vruntime/切换序列可视化(宿主机上跑)。
