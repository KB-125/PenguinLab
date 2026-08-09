---
title: "eBPF:在内核里跑沙盒程序"
slug: debug-ebpf
prerequisites:
  - debug-bug-classification
  - debug-kprobes
difficulty: advanced
tags: [debugging, ebpf, bpf, bcc, bpftrace, verifier, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/bpf/
  - source: third_party/linux（6.19）include/uapi/linux/bpf.h、kernel/bpf/、kernel/trace/bpf_trace.c
maturity: drafting
related:
  - /tutorials/debugging/13-debug-perf
  - /tutorials/debugging/02-debug-kprobes
---

> 🔨 **整理中** · 这一篇讲 **eBPF**(extended BPF,现在就叫 BPF)——内核里跑"用户态写的、经安全校验"的沙盒程序,能挂到 kprobe/tracepoint/socket/网络包/cgroup 等各种点做监控/过滤/统计/性能剖析。素材以 6.19 源码 + kernel.org [BPF 文档](https://docs.kernel.org/bpf/) 为权威。它是"近年内核最火的新能力",BCC/bpftrace 让"动态追踪内核"变得一句话就能写。

## 做什么

[02 kprobes](./02-debug-kprobes.md)/[13 perf](./13-debug-perf.md) 让你在"内核某些点"埋点、采样,但它们只提供"读"的能力——你看数据,不能干预。**eBPF** 更强:你写一段(经校验安全的)小程序,挂到内核的某个点(kprobe/tracepoint/socket 收包/XDP/cgroup),内核每次到那个点就**调你的程序**——程序可以读上下文、做统计、修改包、过滤、返回决策。因为程序经过 verifier 校验(无环、有界、内存安全)、JIT 成本机码,**它安全又快**,所以 eBPF 成了内核"可编程扩展"的统一载体:网络监控、性能追踪、安全过滤、调度可编程(sched-ext,见 [sched-evolution-05](../kernel/sched/sched-evolution-05-sched-ext.md))都基于它。这一篇拆 eBPF 的机制和用法。

## 要了解什么

### 一、`bpf()` 系统调用 + verifier + JIT

eBPF 的内核接口是 **`bpf(2)` 系统调用**(`include/uapi/linux/bpf.h` + `kernel/bpf/syscall.c`)。用户态把一段 BPF 字节码(用 clang 编译 C 子集得到)通过 `bpf(BPF_PROG_LOAD, ...)` 加载进内核,内核:

1. **verifier 校验**:静态分析这段程序——保证它**必然终止**(无环、指令有界)、**内存访问安全**(不越界、不访问未授权内存)、**寄存器类型正确"。校验不过直接拒绝加载。这是 eBPF "安全"的根基——内核敢跑用户代码,因为 verifier 保证它不会搞挂内核。
2. **JIT**:把 BPF 字节码编成当前架构的本机码(x86/ARM64 各有 JIT),运行时直接执行本机码,几乎无解释开销。
3. **attach**:把程序挂到某个点(kprobe/tracepoint/socket filter/...),从此该点触发时调它。

### 二、BPF 程序类型(program type)

程序类型决定"这个 BPF 程序挂哪、能调哪些 helper"。常见类型:

- **`BPF_PROG_TYPE_KPROBE`/`TRACEPOINT`**:挂 kprobe/tracepoint,做内核动态追踪(统计某函数被调多少次、参数分布)。
- **`BPF_PROG_TYPE_PERF_EVENT`**:挂 perf 事件,做采样剖析(类 perf 但可编程)。
- **`BPF_PROG_TYPE_SOCKET_FILTER`**:socket 收包过滤(早期 BPF 主战场,tcpdump 的底层)。
- **`BPF_PROG_TYPE_XDP`**:网络驱动收包最早路径(eXpress Data Path),做高性能包处理/过滤/负载均衡。
- **`BPF_PROG_TYPE_CGROUP_SKB/SOCK`**:cgroup 级网络/进程过滤。
- **`BPF_PROG_TYPE_STRUCT_OPS`**:实现某个内核 ops 表(如 [sched-ext](../kernel/sched/sched-evolution-05-sched-ext.md) 用它实现可编程调度器)。

### 三、BPF maps:内核-用户态数据交换

BPF 程序需要"把统计结果暴露给用户态、或缓存状态",这靠 **BPF maps**——内核里的一块结构化存储(array/hash/percpu 等多种),用户态用 `bpf(BPF_MAP_LOOKUP_ELEM/BPF_MAP_UPDATE_ELEM, ...)` 读写,BPF 程序用 `bpf_map_lookup_elem`/`bpf_map_update_elem` helper 读写。比如统计系统调用次数:BPF 程序在 tracepoint 处 `map[sycall_nr]++`,用户态定期 dump map 看统计。maps 是 BPF "内核执行 + 用户态观测"的桥梁。

### 四、前端:BCC 与 bpftrace

直接写 BPF C + 用 `bpf()` 加载很底层。**BCC**(BPF Compiler Collection)提供 Python 封装 + 一堆现成工具(`execsnoop`/`opensnoop`/`biolatency`/`tcplife`...)。**bpftrace** 是更轻的"一行式" DSL,几行就能写个追踪:

```bash
# 统计每个进程发起 read 的次数
bpftrace -e 'tracepoint:syscalls:sys_enter_read { @[comm] = count(); }'

# 看哪个函数被调最多
bpftrace -e 'profile:hz:99 { @[kstack] = count(); }'
```

bpftrace 的简洁让它成了"动态追踪"的瑞士军刀——想看啥现场写一行。

## 动手试试

1. 宿主机装 bpftrace,`bpftrace -e 'BEGIN { printf("hello\n"); }'` 跑最小例子
2. `bpftrace -e 'tracepoint:syscalls:sys_enter_* { @[comm] = count(); }'` 统计进程系统调用频率(Ctrl+C 看排行)
3. 装 BCC,跑 `execsnoop`(看进程创建)/`biolatency`(看磁盘 I/O 延迟分布)
4. 进阶:写一个 BPF 程序挂 kprobe 统计某函数调用次数,用 map 把结果给用户态
5. 思考题:为什么 eBPF 要有 verifier?(提示:内核敢跑用户代码的前提)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/uapi/linux/bpf.h`(bpf 命令/程序类型/map 类型/struct bpf_insn 指令集);`kernel/bpf/`(`syscall.c` 的 bpf 系统调用、`verifier.c` 校验器、`core.c`/`helpers.c`/各 map 类型);JIT 在 `arch/<arch>/net/`(`bpf_jit_comp.c`);程序类型实现散在各处(`kernel/trace/bpf_trace.c` 追踪类、`net/core/filter.c` 网络类)。
- kernel.org:[BPF Documentation](https://docs.kernel.org/bpf/)、[BPF helpers](https://docs.kernel.org/bpf/helpers.html)。
- 外部:[BCC](https://github.com/iovisor/bcc)、[bpftrace](https://github.com/iovisor/bpftrace);Brendan Gregg 的 [eBPF Tools](https://www.brendangregg.com/ebpf.html) 是实战权威。
- 关联本站:本篇是 [00 调试全景图](./00-debug-bug-classification.md) "动态追踪→eBPF"的展开;eBPF 用 kprobe/tracepoint([02 kprobes](./02-debug-kprobes.md)/[06 ftrace](./06-debug-ftrace.md));sched-ext 可编程调度器用 eBPF([演进史 05](../kernel/sched/sched-evolution-05-sched-ext.md))。
