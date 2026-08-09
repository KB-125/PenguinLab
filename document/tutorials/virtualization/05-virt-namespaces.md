---
title: "namespaces:容器隔离的内核基础"
slug: virt-namespaces
prerequisites:
  - virt-overview
  - process-thread-kernel
next:
  - virt-cgroups
difficulty: advanced
tags: [virtualization, namespaces, clone, unshare, container, nsproxy]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch11.md
  - doc: https://docs.kernel.org/admin-guide/namespaces/
  - source: third_party/linux（6.19）include/linux/nsproxy.h、kernel/nsproxy.c、include/uapi/linux/sched.h
maturity: drafting
related:
  - /tutorials/virtualization/01-virt-overview
  - /tutorials/virtualization/06-virt-cgroups
---

> 🔨 **整理中** · 这一篇讲 **namespaces(命名空间)**——容器隔离的内核基础。素材从 ch11 + 6.19 源码 + kernel.org [namespaces](https://docs.kernel.org/admin-guide/namespaces/) 整理。它是 [01 总览](./01-virt-overview.md) 里"容器 = namespaces 隔离 + cgroups 限资源"的前一半。

## 做什么

容器(Docker/Podman/LXC)的"隔离"是怎么实现的?答案是 **namespaces**——内核把"某些系统资源"按 namespace 分组,同一组 namespace 里的进程看同一份视图、不同组看不同视图。一组进程套进一组 namespace,从里面看就像"我是唯一的、独立的系统"。namespace 不限资源用量(那是 [cgroups](./06-virt-cgroups.md) 的活),只做"看到的隔离"。这一篇拆 namespaces 的种类、用哪些系统调用创建、内核里的数据结构。

## 要了解什么

### 一、8 种 namespace

Linux 现在有 8 种 namespace,各隔离一类资源:

| namespace | 隔离什么 |
|:--|:--|
| **mnt** | 挂载点视图(各自的 `/proc`/`/sys` 内容) |
| **pid** | 进程号(每个 pid ns 可以有自己的 PID 1) |
| **net** | 网络栈(独立接口/路由/端口/iptables) |
| **uts** | 主机名/domainname |
| **ipc** | System V IPC/POSIX 消息队列 |
| **user** | UID/GID 映射(容器里 root 映射到宿主非 root) |
| **cgroup** | cgroup 视图(看到的 cgroup 层级) |
| **time** | 系统时钟偏移 |

一个进程的每个 namespace 都有归属,可独立切换。容器就是一组进程的所有(或大部分)namespace 都换成新建的——于是它看到的全是私有的。

### 二、系统调用:`clone`/`unshare`/`setns`

- **`clone(flags, ...)`**:创建子进程时用 `CLONE_NEW*` flags 指定"子进程新建哪些 namespace"(`CLONE_NEWPID`/`CLONE_NEWNET`/...)。`fork()` 是 `clone` 的特例(共享 ns)。
- **`unshare(flags)`**:**当前进程**切换到新 namespace(不创建子进程)——`unshare -p -f --mount-proc bash` 把自己切到新 pid+mnt ns。
- **`setns(fd, flags)`**:把当前进程**加入一个已存在的 namespace**(通过 `/proc/<pid>/ns/<type>` 的 fd)。

### 三、内核数据结构:`nsproxy` + 各 namespace 结构

`task_struct->nsproxy`(`include/linux/nsproxy.h` 的 `struct nsproxy`)是个"namespace 指针集合"——指向当前任务的 mnt/pid/net/uts/ipc/cgroup/time namespace(user ns 单独走)。每个 namespace 类型有自己的结构(`struct mnt_namespace`/`struct pid_namespace`/`struct net`/...),记录该 namespace 的私有状态。切换/新建 namespace 就是改 `nsproxy` 指向。`/proc/<pid>/ns/` 下每个 namespace 一个符号链接(指向该 namespace 的 inode),`setns` 用它打开 fd。

### 四、容器怎么用

Docker/Podman 跑一个容器,本质就是:`clone`/`unshare` 新建一组 namespace → 在里面 `chroot/pivot_root` 到镜像的 rootfs → exec 容器入口进程。从入口进程看,它在 PID 1(pid ns)、看到自己的根挂载(mnt ns)、自己的网络接口(net ns)、(可能)自己是 root 但宿主看是非 root(user ns)。这就是"容器"的全部内核侧机制——没新概念,就是 namespace 的组合。

## 动手试试

1. `lsns` 列系统所有 namespace + 进程;`ls -l /proc/self/ns/` 看当前进程的 namespace 链接
2. `unshare -U -r bash` 切到新 user ns(里面 root 映射到宿主非 root),`id` 看变化
3. `unshare --pid --fork --mount-proc --net bash` 切到新 pid+mnt+net ns,里面 `ps`(只有自己)、`ip link`(独立网络栈)
4. 读 `kernel/nsproxy.c`/`include/linux/nsproxy.h`,看 `nsproxy` 怎么组合各 namespace
5. 思考题:为什么 container 里看到自己是 PID 1?(提示:pid namespace)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/nsproxy.h`(`struct nsproxy`)/`kernel/nsproxy.c`(`dup_task_struct`/`copy_namespaces`);各 namespace 在 `fs/namespace.c`(mnt)/`kernel/pid_namespace.c`(pid)/`net/core/net_namespace.c`(net) 等;`CLONE_NEW*` flags 在 `include/uapi/linux/sched.h`;`unshare`/`setns` 系统调用在 `kernel/fork.c`/`kernel/nsproxy.c`。
- kernel.org:[namespaces](https://docs.kernel.org/admin-guide/namespaces/)、`man namespaces`/`man unshare`/`man clone`。
- 关联本站:本篇是 [01 总览](./01-virt-overview.md) 容器隔离的一半;另一半资源限制在 [06 cgroups](./06-virt-cgroups.md);`net` namespace 的深入在 net 藤 [16 net-namespace](../kernel/net/16-net-namespace.md)。
- 读书笔记:[ch11](../../notes/linux_kernel_programming/ch11.md) 讲 namespaces。
