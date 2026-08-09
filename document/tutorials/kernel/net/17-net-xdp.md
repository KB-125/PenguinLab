---
title: "XDP:eXpress Data Path,网卡收包最早路径上的可编程点"
slug: net-xdp
prerequisites:
  - net-overview
  - debug-ebpf
difficulty: advanced
tags: [network, xdp, ebpf, high-performance, ddoos, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/networking/xdp-processing.html
  - source: third_party/linux（6.19）include/net/xdp.h、include/uapi/linux/bpf.h、net/core/xdp.c
maturity: drafting
related:
  - /tutorials/kernel/net/01-net-overview
  - /tutorials/debugging/14-debug-ebpf
---

> 🔨 **整理中** · 这一篇讲 **XDP(eXpress Data Path)**——网络包进内核的最早处理点,允许 eBPF 程序在驱动收包的瞬间(还没进协议栈、甚至还没分配 sk_buff)就处理包,实现超高性能的过滤/转发/负载均衡。素材以 6.19 源码 + kernel.org [XDP 文档](https://docs.kernel.org/networking/xdp-processing.html) 为权威。它是 net 藤的"高性能包处理"专题。

## 做什么

[net-overview](./01-net-overview.md) 讲的网络收包路径是:网卡收包 → 驱动 NAPI → 分配 `sk_buff` → 协议栈逐层处理。这条路径要走完"分配 skb + 协议栈多层",每包开销不小——高 PPS(每秒包数)场景下(CentOS DDoS 防护、L4 负载均衡),光"分配 skb + 进栈"就吃掉 CPU。

**XDP** 给了个"逃生口":它把一个 eBPF 程序挂到**网卡驱动收包最早的位置**(驱动从 RX ring 拿到包、还没分配 skb 的那一刻),程序拿到原始包数据(`xdp_buff`)就能决策——丢掉(`XDP_DROP`)、转发(`XDP_TX`)、改写后转发、或放行进协议栈(`XDP_PASS`)。因为**在 skb 分配之前 + 数据就在 driver 缓存里(零拷贝)**,XDP 处理包的速度远超传统协议栈路径,是 Linux 上 DDoS 防护/负载均衡/防火墙的核心高速数据路径。

## 要了解什么

### 一、XDP 的位置:驱动 RX 路径最早

XDP 程序不是在协议栈里跑,而是由**网卡驱动**在收包的最早期调用(`xdp_prog`)。驱动从 RX 描述符拿到包后,**立刻**调 XDP 程序(传 `struct xdp_buff`),程序返回一个动作(`enum xdp_action`),驱动按动作决定:

- **`XDP_PASS`**:放行,继续走传统路径(分配 skb + 进栈)。
- **`XDP_DROP`**:直接丢,不分配 skb、不进栈——DDoS 防护用这个,超高速丢恶意包。
- **`XDP_TX`**:从同一网卡发回去(改写后转发)。
- **`XDP_REDIRECT`**:转发到另一网卡/另一 CPU/`AF_XDP` socket(零拷贝把包送用户态)。
- `XDP_ABORTED`:程序异常,当 DROP 处理 + 报告。

### 二、`xdp_buff`:零拷贝的包数据

**`struct xdp_buff`**(`include/net/xdp.h:86`)是 XDP 程序看到的"包",它**不分配新内存**——直接指向驱动 RX 缓存里的原始包数据(带 `data`/`data_end`/`data_meta`/`data_hard_start` 指针)。程序按这些指针解析以太网/IP/TCP 头、做决策。对比传统路径的 `sk_buff`(分配 + 多层指针 + 元数据),`xdp_buff` 极轻量——这是 XDP 快的根:零分配 + 零拷贝 + 早处理。

`xdp_rxq_info`(`:62`)是"这个 RX 队列的信息"(队列 ID/绑定设备),XDP 程序拿它知道包从哪个网卡/队列来。

### 三、XDP 程序:就是 eBPF

XDP 程序的类型是 `BPF_PROG_TYPE_XDP`(关联 [debug-ebpf](../../debugging/14-debug-ebpf.md))——用 C 子集写、用 clang 编成 BPF、`bpf()` 加载、attach 到某网卡(`ip link set dev eth0 xdp obj prog.o`)。XDP 程序和别的 eBPF 一样经 verifier 校验(无环/有界/内存安全)、JIT 成本机码,**跑得快且安全**。XDP 程序能调的 helper 限于一组"包处理专用"(改包头/查转发表/调队列),它的"快"部分来自这个受限 + 早执行的模型。

### 四、AF_XDP:零拷贝到用户态

**AF_XDP** 是 XDP 家族里"把包零拷贝送到用户态程序"的机制:一个 XDP 程序用 `XDP_REDIRECT` 把包导向一个 AF_XDP socket,用户态程序(`xdpsock` 之类)直接从那个共享 ring 读包——中间**完全零拷贝**(传统 socket 路径有多次拷贝)。适合"超高频、低延迟、用户态处理包"的应用(高频交易、用户态网络栈如 DPDK 类)。

### 五、典型用途

- **DDoS 防护**:XDP 程序按规则丢弃恶意包(`XDP_DROP`),在 skb 分配前就丢,保护协议栈不被打爆。
- **L4 负载均衡**:XDP 按五元组查表、`XDP_REDIRECT` 到后端网卡/容器。
- **防火墙/包过滤**:比 iptables 早得多、快得多。
- **网络监控/采样**:统计包信息,开销极低。

## 动手试试

1. `ip link set dev <eth0> xdpdrv obj myprog.o sec .text`(若有 eBPF 程序),把 XDP 程序挂上;`ip link show` 看是否标了 `prog/xdp`
2. 读 `samples/bpf/xdp1_kern.c`/`xdp2_kern.c`(内核自带的 XDP 示例)看一个 XDP 程序长什么样
3. 写一个最简 XDP 程序(`XDP_DROP` 所有包,小心别把自己锁出网),用 `ip link set ... xdp` 挂上,观察流量变化
4. 进阶:AF_XDP 示例 `samples/bpf/xdpsock_user.c`,体会零拷贝用户态收包
5. 思考题:为什么 XDP 比 iptables 快那么多?(提示:skb 分配前 + 零拷贝 + 驱动 RX 最早 + JIT)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/net/xdp.h:86 struct xdp_buff`、`:62 struct xdp_rxq_info`、`include/uapi/linux/bpf.h`(`enum xdp_action` XDP_PASS/DROP/TX/REDIRECT/ABORTED);实现在 `net/core/xdp.c`、驱动 attach 点在各网卡驱动的 NAPI poll 里(`net/ethernet/...`);示例 `samples/bpf/xdp*_kern.c`、AF_XDP `samples/bpf/xdpsock*`。
- kernel.org:[XDP processing](https://docs.kernel.org/networking/xdp-processing.html)、[AF_XDP](https://docs.kernel.org/networking/af_xdp.html)、`Documentation/networking/xdp-*`。
- 关联本站:本篇是 [01 net-overview](./01-net-overview.md) 的高性能包路径展开;XDP 程序是 eBPF,见 [14 eBPF](../../debugging/14-debug-ebpf.md);传统收包路径(对比 XDP)见 net 藤 [02 sk-buff](./02-net-sk-buff.md)/[04 ipv4](./04-net-ipv4.md)。
