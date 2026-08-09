---
title: "SMP 负载均衡:把忙核的任务搬到空闲核"
slug: sched-load-balance
prerequisites:
  - sched-overview
  - sched-cfs-eevdf
next: []
difficulty: advanced
tags: [scheduler, smp, load-balance, sched_domain, sched_group, numa, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch10.md
  - source: third_party/linux（6.19）kernel/sched/fair.c、kernel/sched/sched.h、kernel/sched/topology.c
maturity: drafting
related:
  - /tutorials/kernel/sched/01-sched-overview
  - /tutorials/kernel/sched/04-sched-context-switch
---

> 🔨 **整理中** · 这一篇讲 SMP(多核)环境下的**负载均衡**——把忙核运行队列里的任务搬到空闲核,让各核负载尽量均匀。素材从 ch10 + 6.19 源码整理。校订增量:6.x 的负载均衡主函数改叫 `sched_balance_rq`(`fair.c:11904`),老资料讲的 `load_balance` 是它的前身。

## 做什么

[调度器框架](./01-sched-overview.md) 讲过每个 CPU 核有自己独立的运行队列(`struct rq`),调度器在单核内选下一个任务。可问题来了:多核系统里,如果某个核上的任务突然都变得繁忙(8 个 CPU 密集任务挤在核 0)、其它核闲着,调度器不能坐视不管——得把一些任务**搬到**其它核的运行队列,让负载摊开。这就是**负载均衡(load balancing)**。这一篇拆它:用什么数据结构描述 CPU 拓扑(sched_domain/sched_group)、什么时候触发均衡(周期性/idle 时)、怎么决定"搬谁、搬到哪"、以及迁移的代价(cache/NUMA 亲和性)。

## 要了解什么

### 一、为什么需要负载均衡:多核 + 独立运行队列的副作用

每核独立 `rq` 的好处是单核调度无锁、快;副作用是**各核负载可能不均**。任务一旦进了某个核的 `rq`,默认就待在那(调度器很少主动迁);可若初始分配不均、或某核上任务都变 CPU 密集、或某核上任务大量阻塞了,就会"有的核忙死、有的核闲死"。负载均衡就是补救机制——周期性地检查各核负载,把过载核的任务搬到欠载核。

### 二、`sched_domain`/`sched_group`:CPU 拓扑的层级抽象

负载均衡不能"瞎搬"——把任务从核 0 搬到和它共享 L1 cache 的核 1(SMT 兄弟),代价小;搬到另一个 NUMA 节点的核,代价大(跨节点访存慢)。所以内核用**调度域(sched_domain)层级**描述 CPU 拓扑,从"亲"到"疏"分层:

- **SMT 域**:超线程兄弟核(共享 L1,最亲)
- **MC 域**(Multi-Core):同一物理 CPU 的核(共享 L2/L3)
- **DIE 域**:同一 die
- **NUMA 域**:跨 NUMA 节点(最疏,跨节点访存慢)

每个 `sched_domain`(`include/linux/sched/topology.h` + `kernel/sched/sched.h`)里挂一串 **`sched_group`**(`sched.h:2133`,每组含若干 CPU + 容量信息 `sched_group_capacity :2116`),组之间串成环。负载均衡在**每个 domain 级别**分别做,从最亲的域(SMT)开始——亲域均衡代价小、先做;疏域(NUMA)均衡代价大、更谨慎(频率低、阈值高)。这套层级在启动时由 `kernel/sched/topology.c` 根据硬件拓扑自动构建。

### 三、`sched_balance_rq`:均衡的触发与流程

6.x 的负载均衡主函数是 **`sched_balance_rq(int this_cpu, struct rq *this_rq, struct sched_domain *sd, enum cpu_idle_type idle, ...)`**(`kernel/sched/fair.c:11904`,老资料叫 `load_balance`)。它被调用的两个主要时机:

- **周期性均衡(`PERIODIC`)**:时钟 tick 里,定期检查各域负载。每个域有自己的均衡间隔(忙核间隔短、闲核间隔长),避免过于频繁。
- **Idle 均衡(`NEWLY_IDLE`)**:某核运行队列空了、要选 idle 任务前,主动 pull 别核的任务过来(这时均衡收益最高、代价相对小,反正这核闲着)。

`sched_balance_rq` 的流程:在该域内找**最忙的 group**(负载最高)、在 group 内找**最忙的 `rq`**、从那个 `rq` 挑任务搬到 `this_rq`。挑哪个任务搬,要看它的负载贡献、cache 亲和性(优先搬"最近没跑过、cache 已冷"的任务,少损失 cache)。搬完更新负载统计。

### 四、负载指标与迁移代价

"负载"怎么衡量?fair 类用 `cfs_rq` 的一系列指标:`load`(基于 PELT 的衰减负载贡献)、`runnable_weight`、`h_nr_running` 等。**PELT(Per-Entity Load Tracking)** 是关键——每个任务/运行队列的负载贡献按时间衰减(最近的运行比历史更"重"),这样负载统计能反映"动态"负载而非平均。均衡时,内核算 group 的总负载、比较组间差异,差异超阈值才触发迁移。

迁移代价主要是 **cache 失效**(任务从核 A 迁到核 B,它在核 A 暖起来的 L1/L2 数据在核 B 全 miss,要重新预热)和 **NUMA 访存**(跨节点迁移后,任务的数据可能还在老节点的内存,访存变慢)。所以均衡不是"无脑把任务摊平",而是在"摊平负载的收益"和"迁移的 cache/NUMA 代价"之间权衡——这正是 sched_domain 分层的意义(亲域代价小可激进、疏域代价大要保守)。

### 五、亲和性约束:`cpus_ptr`

[框架那篇](./01-sched-overview.md) 讲的 CPU 亲和性位掩码(`task_struct->cpus_ptr`)是负载均衡的硬约束:一个任务只能被均衡到它的亲和性掩码允许的核上。用户态 `taskset`/cgroup cpuset 设的掩码,会限制均衡范围。所以"把任务钉在指定核"(CPU isolation)就是靠设亲和性掩码排除其它核——均衡器自然不会把它搬走。

## 动手试试

1. `cat /proc/schedstat`(需 CONFIG_SCHEDSTATS)看每个 CPU 的负载统计、迁移次数
2. 多核 QEMU 里起 N 个 CPU 密集任务(N > 核数),`mpstat -P ALL 1` 或 `top` 按 `1` 看各核负载——观察均衡器把它们摊开
3. `taskset -c 0 ./busy` 把任务钉在核 0,起多个,观察它们都挤在核 0、不被均衡到别的核(亲和性约束)
4. `perf stat -e cpu-migrations <cmd>` 看一次负载触发了多少次核迁移
5. 思考题:为什么负载均衡从 SMT 域开始、NUMA 域最谨慎?(结合本篇第二节的拓扑层级 + 第四节的迁移代价)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`kernel/sched/sched.h:2133 struct sched_group`、`:2116 struct sched_group_capacity`;`kernel/sched/fair.c:11904 sched_balance_rq`(及调用点 `:12405`/`:13042`)、PELT 负载跟踪在 `kernel/sched/fair.c` 的 `__update_load_avg_*`;拓扑构建 `kernel/sched/topology.c`、`include/linux/sched/topology.h`;亲和性 `task_struct->cpus_ptr` 见 [01 框架](./01-sched-overview.md)。
- 关联本站:本篇是 [01 调度器框架](./01-sched-overview.md) "每核独立 rq"的多核后果;迁移本身走 [04 上下文切换](./04-sched-context-switch.md) 的核间迁移路径;亲和性/cgroup cpuset 关联 [driver model](../../drivers/00-drv-model.md) 与 cgroups。
- 读书笔记:[ch10](../../notes/linux_kernel_programming/ch10.md) 讲 SMP 调度与 CPU 亲和性。
