---
title: "cgroups:容器资源限制的内核基础"
slug: virt-cgroups
prerequisites:
  - virt-namespaces
next:
  - virt-container-project
difficulty: advanced
tags: [virtualization, cgroups, cgroup-v2, cpu, memory, container]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch11.md
  - doc: https://docs.kernel.org/admin-guide/cgroup-v2.html
  - source: third_party/linux（6.19）kernel/cgroup/、include/linux/cgroup.h
maturity: drafting
related:
  - /tutorials/virtualization/05-virt-namespaces
  - /tutorials/kernel/sched/03-sched-rt
---

> 🔨 **整理中** · 这一篇讲 **cgroups(control groups)**——容器资源限制的内核基础。素材从 ch11 + 6.19 源码 + kernel.org [cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html) 整理。它和 [namespaces](./05-virt-namespaces.md) 配对:namespace 管"看到的隔离",cgroup 管"用量的限制"。

## 做什么

[namespaces](./05-virt-namespaces.md) 让容器"看不到别人",但不限制容器能用多少 CPU/内存/IO——一个失控容器仍能吃光宿主资源。**cgroups** 补这块:它把进程分组(cgroup),给每组**限制/统计**资源用量(CPU 配额、内存上限、IO 带宽、进程数)。容器被 namespace 隔离 + cgroup 限资源后,既看不见别人、也吃不掉别人的份额。这一篇讲 cgroup v2 的模型、常用控制器、怎么用。

## 要了解什么

### 一、cgroup v2:统一层级 + 控制器

现代 Linux 用 **cgroup v2**(4.5 起生产可用,v1 兼容但新系统用 v2)。v2 相对 v1 的核心变化是**统一层级(unified hierarchy)**——所有控制器挂在同一棵 cgroup 树上(v1 是每个控制器独立树)。文件系统类型 `cgroup2`,挂载点 `/sys/fs/cgroup`(`mount | grep cgroup2` 看)。`/sys/fs/cgroup/` 下每个目录是一个 cgroup,通过创建子目录建新 cgroup、把进程 PID 写进 `cgroup.procs` 把进程归入。

### 二、常用控制器(v2)

启用控制器:父 cgroup 的 `cgroup.subtree_control` 写 `+<controller>`,孙 cgroup 就受该控制器约束。常用:

- **cpu**:CPU 带宽配额(`cpu.max`:上限 + 周期,如 `50000 100000` = 100ms 周期内最多跑 50ms = 50% CPU);`cpu.weight` 是相对权重。
- **cpuset**:绑核(指定只能在哪些 CPU 上跑)。
- **memory**:内存上限(`memory.max`,超了触发 OOM 或拒分配);`memory.swap.max` 限制 swap。
- **io**:IO 带宽(对块设备限速,`io.max`)。
- **pids**:进程数上限(`pids.max`,防 fork 炸弹)。
- **rdma/hugetlb/misc**:其他资源。

容器(Docker `--cpus=0.5 --memory=100m --pids-limit=100`)就是把这些 cgroup 控制器配到容器的 cgroup 上。

### 三、自上而下约束 + systemd 的角色

cgroup v2 的资源**自上而下分发**:`根 cgroup` 把 CPU/内存分给子 cgroup、子再分给孙。一个 cgroup 能限制子多少的前提是它自己从父拿到了那些资源(`cgroup.subtree_control` 只能开父已开的控制器)。`systemd` 默认接管 `/sys/fs/cgroup` 的根管理,把每个 service/user/slice 建一个 cgroup、按单元文件(`CPUQuota=`/`MemoryMax=`)配资源——这就是为什么现代系统 `systemd-cgtop` 能看到所有进程的资源用量按 cgroup 分组。

### 四、容器:namespace + cgroup 组合

容器 = 进程 + 一组新 namespaces(隔离视图)+ 归入一个新 cgroup(限资源)。Docker/Podman 跑容器时,创建新 namespace(`clone CLONE_NEW*`)+ 创建新 cgroup + 写资源限制 + 把容器入口进程归入。这样容器既"看不到别人"(namespace)、又"吃不掉别人的份额"(cgroup),形成轻量隔离——比 VM 弱(共享内核),但开销小、密度高。

## 动手试试

1. `mount | grep cgroup2` 看 cgroup2 挂载;`ls /sys/fs/cgroup/` 看根 cgroup + 子目录;`cat /sys/fs/cgroup/cgroup.controllers` 看可用控制器
2. `systemd-cgtop` 看各 cgroup 的 CPU/内存/IO 用量(按 cgroup 分组)
3. 手工建一个受限 cgroup:`mkdir /sys/fs/cgroup/mytest; echo "+memory +pids" > /sys/fs/cgroup/cgroup.subtree_control; echo "50M" > /sys/fs/cgroup/mytest/memory.max; echo $$ > /sys/fs/cgroup/mytest/cgroup.procs`,然后跑个吃内存进程看被限
4. `docker run --cpus=0.5 --memory=50m busybox top`,看容器被限到 50% CPU + 50MB 内存
5. 思考题:为什么 cgroup v2 用"统一层级"(所有控制器一棵树),而 v1 是每控制器独立树?(提示:统一管理 + 一致的进程分组)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`kernel/cgroup/`(`cgroup.c` core、`cgroup-v1.c`/`cgroup-rstat.c`/各控制器在 `cgroup-v1` 外的子系统);`include/linux/cgroup.h`(`struct cgroup_subsys`/`struct cgroup`);各控制器实现散在各子系统(`kernel/sched/cpuacct.c`、`mm/memcontrol.c` memory、`block/blk-cgroup.c` io);`Documentation/admin-guide/cgroup-v2.rst` 是权威。
- kernel.org:[cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)(详尽,本篇核心素材);`man cgroups`。
- 关联本站:本篇是 [05 namespaces](./05-virt-namespaces.md) 的配对;cpu 控制器关联 [03 sched-rt](../kernel/sched/03-sched-rt.md)/[sched-overview](../kernel/sched/01-sched-overview.md) 的 CPU 调度;memory 控制器关联 mm 藤 OOM。
- 读书笔记:[ch11](../../notes/linux_kernel_programming/ch11.md) 讲 cgroups v2 + systemd。
