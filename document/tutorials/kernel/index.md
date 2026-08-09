---
title: 内核子系统
description: 调度器、内存管理、文件系统、网络栈——内核核心原理
maturity: drafting
---

# 内核子系统

> 深入内核核心原理：调度器、内存管理、文件系统、网络栈。🔨 全栈整理中（机制主教程 + 演进史补充材料）。

## 调度器 🔨 整理中

### 机制主教程
- 🔨 [01 调度器框架:谁上 CPU,内核怎么拍板](./sched/01-sched-overview)
- 🔨 [02 CFS/EEVDF:fair 类内部怎么挑下一个任务](./sched/02-sched-cfs-eevdf)
- 🔨 [03 RT 实时调度:SCHED_FIFO/SCHED_RR 与带宽限制](./sched/03-sched-rt)
- 🔨 [04 上下文切换:从一个任务切到另一个发生了什么](./sched/04-sched-context-switch)
- 🔨 [05 SMP 负载均衡:把忙核的任务搬到空闲核](./sched/05-sched-load-balance)

### 演进史（补充材料）
- 🔨 [演进（一）：O(1) 调度器——从遍历到位图的跨越](./sched/sched-evolution-01-o1)
- 🔨 [演进（二）：SD/RSDL 风波——一位麻醉医生挑战内核权威](./sched/sched-evolution-02-sd-rsdl)
- 🔨 [演进（三）：CFS 诞生——62 小时重写调度器](./sched/sched-evolution-03-cfs)
- 🔨 [演进（四）：EEVDF——从虚拟公平到虚拟截止时间](./sched/sched-evolution-04-eevdf)
- 🔨 [演进（五）：sched_ext——BPF 可编程调度器的争议之路](./sched/sched-evolution-05-sched-ext)

## 内存管理 🔨 整理中

- 🔨 [00 mm 子系统全景:从进程地址空间到物理页](./mm/00-mm-overview)
- 🔨 [01 伙伴系统：内核怎么管物理页](./mm/01-mm-buddy)
- 🔨 [02 Slab 分配器：内核怎么管小对象](./mm/02-mm-slab)
- 🔨 [03 vmalloc：只要虚拟连续就行](./mm/03-mm-vmalloc)
- 🔨 [04 页面回收与 kswapd：内存紧张时怎么办](./mm/04-mm-page-reclaim)
- 🔨 [05 OOM Killer：回收也扛不住时的最后防线](./mm/05-mm-oom)

## 文件系统 🔨 整理中

- 🔨 [01 VFS:一个 open() 怎么变成 ext4 或 procfs 的具体操作](./fs/01-fs-vfs)
- 🔨 [02 procfs:给内核开个 /proc 窗口,现造文件给用户态读](./fs/02-fs-procfs)
- 🔨 [03 sysfs:kobject 的影子,把设备/驱动属性暴露成一个个文件](./fs/03-fs-sysfs)
- 🔨 [04 页缓存:为什么第二次 cat 比第一次快——VFS 与 mm 的桥](./fs/04-fs-page-cache)
- 🔨 [05 ext4:磁盘文件系统怎么把"文件"真正落进盘里](./fs/05-fs-ext4)

## 网络栈 🔨 整理中

- 🔨 [01 网络栈全景：一个包的内核漂流](./net/01-net-overview)
- 🔨 [02 sk_buff：贯穿网络栈的快递盒](./net/02-net-sk-buff)
- 🔨 [03 邻居子系统与 ARP：IP 怎么找到 MAC](./net/03-net-neighbor)
- 🔨 [04 IPv4 协议层：包的接收与发送](./net/04-net-ipv4)
- 🔨 [05 IPv4 路由子系统：包该往哪走](./net/05-net-routing)
- 🔨 [06 TCP 传输层：三次握手与收发内核视角](./net/06-net-tcp)
- 🔨 [07 UDP：无连接的轻量传输](./net/07-net-udp)
- 🔨 [08 Netfilter：网络栈的钩子框架](./net/08-net-netfilter)
- 🔨 [09 Netlink：用户态与内核的双向 socket](./net/09-net-netlink)
- 🔨 [10 ICMP：网络的诊断与控制协议](./net/10-net-icmp)
- 🔨 [11 组播路由：一对多的高效投递](./net/11-net-multicast)
- 🔨 [12 IPv6：不只是更长的地址](./net/12-net-ipv6)
- 🔨 [13 IPsec 与 XFRM：内核怎么给数据包穿装甲](./net/13-net-ipsec)
- 🔨 [14 mac80211：内核怎么管一块无线网卡](./net/14-net-wireless)
- 🔨 [15 RDMA 与 InfiniBand：绕过内核的零拷贝传输](./net/15-net-rdma)
- 🔨 [16 网络命名空间：容器网络的根基](./net/16-net-namespace)
- 🔨 [17 XDP:eXpress Data Path,网卡收包最早路径上的可编程点](./net/17-net-xdp)
