---
title: "虚拟化项目:搭一个能跑的 VM/容器"
slug: virt-project
prerequisites:
  - virt-qemu-kvm
difficulty: advanced
tags: [virtualization, project, kvm, qemu, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
type: project
sources:
  - source: 综合 [01-03](./) virtualization 藤 + foundations QEMU
maturity: drafting
related:
  - /tutorials/virtualization/03-virt-qemu-kvm
---

> 🔨 **整理中** · 这一篇是虚拟化藤的**综合实战项目**——把 [01-03](./) 学的"虚拟化原理"落到"搭一个真正能跑的虚拟化环境"。它是项目型节点,目标是让读者走完"从零到 VM/容器跑起来"的实战,把抽象原理变成可操作的产物。

## 项目目标

把虚拟化原理变成能跑的东西,两个可选方向(择一或都做):

**方向 A:搭一个 QEMU/KVM 虚拟机**(硬件虚拟化路线)。完整走一遍"准备 Guest 镜像 → 配 QEMU 启动 → (可选)开 KVM 加速 → 进 Guest 跑应用 → 验证隔离"。这是本站"ARM64 内核学习"环境的延伸(本站 QEMU 已经在做,这里把它系统化、加点 KVM/virtio 优化)。

**方向 B:搭一个容器**(OS 级虚拟化路线)。用 namespaces + cgroups 手工搭一个"最小容器"(不依赖 Docker,直接 `unshare` + `cgcreate`),理解容器本质;再用 Docker/Podman 对照。

## 方向 A:QEMU/KVM VM 实战

1. 准备 Guest:用 [Buildroot](../embedded/06-embed-buildroot.md) 或现成 Linux 发行版镜像,拿到内核 `Image` + rootfs
2. 配 QEMU 启动:
   ```bash
   qemu-system-<arch> -M virt -cpu <cortex-a53/host> -m 1G -smp 2 \
     -kernel Image -drive rootfs.ext4,if=virtio \
     -append "root=/dev/vda console=ttyAMA0" \
     [-enable-kvm]              # 仅 Guest=Host 架构时可加
     -netdev user,id=n -device virtio-net-device,netdev=n
   ```
3. 进 Guest,验证:CPU/内存/磁盘/网络都通;跑个应用
4. 验证隔离:Guest 里 `rm -rf /`(虚拟机内,谨慎!),Host 不受影响——体现 VM 的强隔离
5. 加 KVM 加速(同架构时)对比启动 + 运行速度;加/去 virtio 对比磁盘网络性能

## 方向 B:手工容器实战

1. **手工 namespaces**:用 `unshare` 创建一个"PID+mount+网络 namespace 隔离"的 shell:
   ```bash
   unshare --pid --fork --mount-proc --net --uts --ipc chroot rootfs/ /bin/sh
   ```
   进去后 `ps`(只看到自己)、`mount`(独立挂载)、`ip link`(独立网络栈)——体会 namespace 隔离
2. **cgroups 限制**:用 `cgcreate`/`cgset` 给上面那个 shell 加 CPU/内存限制(如 10% CPU、50MB 内存),跑个死循环看被限流
3. **Docker 对照**:`docker run -it --cpus=0.1 --memory=50m alpine sh`,看它就是上面手工 namespaces+cgroups 的封装(加镜像管理 + 易用 API)
4. 验证隔离:容器里看到自己是"PID 1",看不到宿主进程;被 cgroup 限到 50MB 内存,跑超内存被 OOM kill

## 选型与体会

两个方向做完,体会本篇 [01 总览](./01-virt-overview.md) 的对比:VM 启动慢但隔离强(各自内核),容器启动快但共享内核。这也是为什么现代云原生(Docker/Kubernetes)主推容器——密度高、快;而要跑异构系统/强隔离(Windows on Linux、安全沙箱)用 KVM VM。

## 动手试试

1. 方向 A:用 Buildroot 构建一个 ARM64 或 x86_64 的 QEMU VM,完整跑通"镜像→启动→应用"
2. 方向 A 进阶:加/去 `-enable-kvm` + `if=virtio`,系统对比启动时间和磁盘/网络吞吐(`dd`/`iperf`)
3. 方向 B:`unshare` 手工搭一个最小容器,加 cgroup 限制,对照 Docker
4. 思考题:为什么容器比 VM 启动快几个量级?(提示:没 Guest 内核启动 + 没设备仿真)

## 延伸阅读

- 关联本站:本篇综合 [01 总览](./01-virt-overview.md)/[02 KVM](./02-virt-kvm.md)/[03 QEMU+KVM](./03-virt-qemu-kvm.md);[05 QEMU 启动](../foundations/05-qemu-first-boot.md) 本站 QEMU 基础;[06 Buildroot](../embedded/06-embed-buildroot.md) 构建 Guest;namespaces/cgroups 见 [05](./05-virt-namespaces.md)/[06](./06-virt-cgroups.md)。
- 外部:[QEMU](https://www.qemu.org/)/[KVM](https://www.linux-kvm.org/)/[Docker](https://docs.docker.com/);`unshare`/`cgcreate` 的 man page。
