---
title: "虚拟化总览:KVM 硬件虚拟化 与 容器 OS 级虚拟化"
slug: virt-overview
prerequisites:
  - qemu-first-boot
  - process-thread-kernel
next:
  - virt-kvm
difficulty: intermediate
tags: [virtualization, kvm, container, namespace, cgroup, overview]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch11.md
  - doc: https://docs.kernel.org/virt/
maturity: drafting
related:
  - /tutorials/foundations/05-qemu-first-boot
---

> 🔨 **整理中** · 这一篇是虚拟化藤的**总览**——分清两条虚拟化路线:**硬件虚拟化**(KVM + QEMU,跑完整虚拟机)和 **OS 级虚拟化**(容器,共享内核 + namespace/cgroup 隔离)。素材从 ch11 + kernel.org [virt 文档](https://docs.kernel.org/virt/) 整理。它为后面 [KVM](./02-virt-kvm.md)/[namespaces](./05-virt-namespaces.md)/[cgroups](./06-virt-cgroups.md) 各篇搭全景。

## 做什么

虚拟化就是把"一台物理机"抽象成"多个独立的运行环境",每个环境跑自己的系统/应用,互不干扰。Linux 上有两条实现路线,这一篇先把它们分清楚:

- **硬件虚拟化(虚拟机/VM)**:KVM(内核)+ QEMU(用户态设备仿真)——给每个 Guest 模拟一整套硬件(CPU/内存/外设),Guest 跑**自己完整的内核**。隔离强(Guest 内核都能换),但开销大(CPU/内存仿真 + Guest 内核 + Guest 用户态三层)。
- **OS 级虚拟化(容器)**:Docker/Podman/LXC——所有容器**共享宿主机内核**,靠**命名空间(namespaces)**做"看到的资源隔离"(PID/网络/挂载/用户各看各的)、**cgroups**做"资源用量限制"(CPU/内存/IO 上限)。开销小(没 Guest 内核),但容器必须和宿主同内核。

这条分界记牢:VM = 模拟硬件 + 各自内核;容器 = 共享内核 + 隔离视图。后面各篇分别展开这两条。

## 要了解什么

### 一、硬件虚拟化:KVM + QEMU

- **KVM(Kernel Virtual Machine)**:内核模块(`arch/<arch>/kvm/`),利用 CPU 的硬件虚拟化扩展(Intel VT-x、AMD-V、ARM64 VHE)给 Guest 提供虚拟 CPU(`vCPU`),把 Guest 的 CPU/内存指令直接在物理 CPU 上跑(陷出敏感指令时才切回 Host)——所以 KVM Guest 性能接近原生,不像纯 QEMU 全仿真那么慢。
- **QEMU**:用户态进程,作为"VM 的外壳"——给 Guest 提供虚拟硬件(虚拟磁盘/网卡/显卡/键盘),Guest 的设备访问由 QEMU 仿真。QEMU + KVM 组合 = 高性能 VM(KVM 加速 CPU/内存,QEMU 仿真外设)。

详细在 [02 KVM](./02-virt-kvm.md)/[03 QEMU+KVM](./03-virt-qemu-kvm.md)。

### 二、OS 级虚拟化:namespaces + cgroups

- **namespaces**:让一组进程看到的某些系统资源"私有化"——PID namespace(进程号各看各的)、网络 namespace(独立网络栈/接口/端口)、挂载 namespace(独立挂载视图)、用户 namespace(UID 映射)、UTS/IPC namespace。容器(Docker)的本质就是一组进程套进一组 namespace,从里面看"自己是唯一的、独立的系统"。
- **cgroups(control groups)**:限制/统计一组进程的资源用量——CPU 配额、内存上限、IO 带宽、进程数限制。容器被 namespace 隔离 + cgroup 限资源后,既"看不到别人"也"用不掉别人的份额"。

详细在 [05 namespaces](./05-virt-namespaces.md)/[06 cgroups](./06-virt-cgroups.md)。

### 三、对比与选型

| | KVM/QEMU(VM) | 容器(namespaces+cgroups) |
|:--|:--|:--|
| 隔离 | 强(各自内核) | 中(共享内核) |
| 性能 | 中(KVM 接近原生,QEMU 仿真有损耗) | 高(几乎无损耗) |
| 镜像大小 | GB 级(含 Guest OS) | MB 级(只应用 + 库) |
| 启动速度 | 秒~分钟 | 毫秒~秒 |
| Guest 内核 | 任意 | 必须同宿主 |

选型:要跑异构系统(Windows on Linux、不同内核版本)用 KVM VM;要"轻量、快速、高密度部署应用"用容器(现代云原生主力)。

### 四、本站和虚拟化的关系

本站用 QEMU 跑 ARM64 内核学内核([05 QEMU 启动](../foundations/05-qemu-first-boot.md))——那是 QEMU 的"全系统仿真"模式(`-M virt`),可以用 KVM 加速(若宿主架构和 Guest 一致,如 x86_64 宿主跑 x86_64 Guest 用 `-enable-kvm`)。本站 ARM64 Guest 在 x86 宿主上不能开 KVM(架构不同,只能 TCG 仿真),但概念上 QEMU+KVM 是虚拟化藤的核心。

## 动手试试

1. 宿主机看自己有没有 KVM 支持:`ls /dev/kvm`(有 = 支持);`egrep '(vmx|svm)' /proc/cpuinfo`(x86 VT-x)
2. 跑个容器:`docker run --rm alpine echo hello`(若有 Docker),体会"秒起、毫秒级"的容器;对比 `qemu-system-x86_64 -enable-kvm ...` 启 VM 的速度
3. `lsns`(列所有 namespace)/`cat /proc/<pid>/cgroup`,直观看到容器/进程的 namespace 和 cgroup 归属
4. 思考题:为什么容器比 VM 启动快那么多?(提示:没 Guest 内核启动)

## 延伸阅读

- 关联本站:本篇是虚拟化藤入口;KVM 细节 [02 KVM](./02-virt-kvm.md)、namespaces/cgroups [05](./05-virt-namespaces.md)/[06](./06-virt-cgroups.md);本站 [05 QEMU](../foundations/05-qemu-first-boot.md) 是 QEMU 全系统仿现实战。
- kernel.org:[virt](https://docs.kernel.org/virt/) 总目录(KVM/containers/...)、[KVM](https://docs.kernel.org/virt/kvm/)、[cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)。
- 读书笔记:[ch11](../../notes/linux_kernel_programming/ch11.md) 讲 cgroups/namespaces。
