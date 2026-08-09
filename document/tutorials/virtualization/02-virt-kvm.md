---
title: "KVM:内核里的硬件虚拟化引擎"
slug: virt-kvm
prerequisites:
  - virt-overview
next:
  - virt-qemu-kvm
difficulty: advanced
tags: [virtualization, kvm, vcpu, ept, stage2, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/virt/kvm/
  - source: third_party/linux（6.19）arch/<arch>/kvm/、virt/kvm/、include/uapi/linux/kvm.h
maturity: drafting
related:
  - /tutorials/virtualization/01-virt-overview
---

> 🔨 **整理中** · 这一篇讲 **KVM**——内核里的硬件虚拟化引擎,靠 CPU 虚拟化扩展给 Guest 提供 vCPU、加速内存。素材以 6.19 源码 + kernel.org [KVM 文档](https://docs.kernel.org/virt/kvm/) 为权威。KVM 本身只管"虚拟 CPU + 内存",设备仿真交给用户态的 QEMU([下一片](./03-virt-qemu-kvm.md))。

## 做什么

KVM 的目标是"让 Guest 跑得快"——纯 QEMU 全仿真 Guest 的每条指令(翻译执行),慢;KVM 利用 CPU 硬件虚拟化扩展(Intel VT-x、AMD-V、ARM64 VHE),让 Guest 的 vCPU **直接在物理 CPU 上跑**,只在 Guest 执行敏感指令(改中断/页表/IO)时"陷出(trap)"到 Host 处理,处理完再"陷回"继续跑 Guest。这样 Guest 的常规指令接近原生速度,只有敏感指令有切换开销。这一篇讲 KVM 的用户态接口(`/dev/kvm` + ioctl)、vCPU 怎么跑、内存怎么虚拟化。

## 要了解什么

### 一、`/dev/kvm` + ioctl:KVM 的用户态接口

KVM 作为内核模块,暴露一个字符设备 `/dev/kvm`。用户态(QEMU)通过 **ioctl** 创建并控制 VM,核心 ioctl 链(`include/uapi/linux/kvm.h`):

- `KVM_CREATE_VM` → 拿到一个 `vm fd`
- `KVM_CREATE_VCPU(vm, id)` → 给 VM 创建一个 vCPU,拿到 `vcpu fd`
- `KVM_RUN(vcpu)` → **跑这个 vCPU**(陷入 Guest 执行,直到 Guest 陷出才返回)
- `KVM_SET_USER_MEMORY_REGION(vm, ...)` → 给 VM 注册一段"Guest 物理地址 → Host 用户态内存"的映射
- `KVM_GET_REGS`/`KVM_SET_REGS`、`KVM_GET_SREGS`/`KVM_SET_SREGS` → 读写 vCPU 寄存器(初始化 Guest 状态、调试)

这套 ioctl 的设计精髓:**KVM 只管 vCPU/内存,设备仿真在用户态(QEMU)**。Guest 访问一个虚拟设备(比如读虚拟串口)→ KVM 检测到 IO 访问 → `KVM_RUN` 返回(告诉 QEMU"Guest 想读这个 IO 地址")→ QEMU 仿真设备、给出数据 → 再 `KVM_RUN` 继续 Guest。CPU/内存走 KVM(快),设备走 QEMU(灵活)。

### 二、vCPU 的运行:陷出与陷回

vCPU 跑(`KVM_RUN`)时,内核把物理 CPU 切到"Guest 模式"(ARM64 EL2 控制下进 Guest EL1),执行 Guest 代码。当 Guest 执行了需要 Host 介入的指令(如 `HLT` 等待、IO 读写、缺页、敏感寄存器访问),CPU 自动"陷出"到 KVM → KVM 决定怎么处理(IO 交给用户态 QEMU、其他内部处理)→ 处理完再回 Guest。这个"Guest ↔ Host 切换"靠硬件虚拟化扩展完成(Intel VT-x 的 VMX root/non-root 模式切换、ARM64 的 EL2/EL1 异常层级),开销比纯软件仿真小得多。

### 三、内存虚拟化:Stage2/EPT

Guest 看到的"物理地址(GPA)"不是真物理地址,要再翻译成 Host 物理地址(HPA)。两种办法:

- **影子页表(老)**:KVM 维护一张 GPA→HPA 的影子页表,MMU 直接用它——开销大(维护成本)。
- **二阶段页表(EPT/Stage2,现代)**:CPU 硬件支持二阶段翻译——Guest 自己的页表翻译虚拟→GPA(阶段 1),KVM 配置的 EPT(x86)/Stage2(ARM64)页表翻译 GPA→HPA(阶段 2)。两阶段由 MMU 硬件自动完成,没有软件翻译开销。这是现代 KVM 内存虚拟化的标准。

ARM64 的 KVM 用 VHE(Virtualization Host Extensions)把 Host 内核也跑在 EL2(以前 Host 在 EL1、KVM 在 EL2,切换开销大;VHE 让 Host 直接在 EL2,减少切换)。

### 四、KVM 的架构代码

KVM 在 `arch/<arch>/kvm/`:`arch/x86/kvm/`、`arch/arm64/kvm/`、`arch/riscv/kvm/`。每架构实现自己的 vCPU 陷出处理、Stage2 页表、寄存器虚拟化。通用部分在 `virt/kvm/`、UAPI 在 `include/uapi/linux/kvm.h`。

## 动手试试

1. `ls -l /dev/kvm`(有 = 内核 KVM 模块加载 + CPU 支持虚拟化);`lscpu | grep Virtualization`
2. `lsmod | grep kvm`(`kvm` + `kvm_intel`/`kvm_amd`/`kvm_arm`)
3. 读 `arch/arm64/kvm/` 的入口(`kvm.c`/`arm.c`/`mmu.c` Stage2),看 `KVM_RUN` 的实现路径
4. QEMU 带 `-enable-kvm` 启动 x86 Guest(同架构才可),对比不带 KVM 的速度
5. 思考题:为什么 KVM 把"设备仿真"留给用户态 QEMU,而不放进内核?(提示:内核放硬件相关 + 高频,设备多样且灵活 → 用户态)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/uapi/linux/kvm.h`(所有 `KVM_*` ioctl 号 + 结构);`virt/kvm/kvm_main.c`(通用 KVM core);架构部分 `arch/arm64/kvm/`(`guest.c`/`mmu.c` Stage2/`hyp/` hypervisor 代码,运行在 EL2)、`arch/x86/kvm/`(VMX/SVM)、`arch/riscv/kvm/`。
- kernel.org:[KVM](https://docs.kernel.org/virt/kvm/)、[KVM ARM64](https://docs.kernel.org/virt/kvm/arm/index.html)、`Documentation/virt/kvm/`。
- 关联本站:本篇是 [01 总览](./01-virt-overview.md) 的 KVM 展开;QEMU 配合在 [03](./03-virt-qemu-kvm.md);本站 ARM64 Guest 在 x86 宿主跑用 QEMU TCG(非 KVM),[05 QEMU](../foundations/05-qemu-first-boot.md)。
