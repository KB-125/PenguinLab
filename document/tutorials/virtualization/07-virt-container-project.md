---
title: "容器项目:从零搭一个最小容器"
slug: virt-container-project
prerequisites:
  - virt-namespaces
  - virt-cgroups
  - virt-project
difficulty: advanced
tags: [virtualization, container, project, namespace, cgroup, docker]
architectures: [arm64, x86_64]
kernel_version: "6.19"
type: project
sources:
  - source: 综合 [01-06](./) virtualization 藤 + ch11
maturity: drafting
related:
  - /tutorials/virtualization/05-virt-namespaces
  - /tutorials/virtualization/06-virt-cgroups
---

> 🔨 **整理中** · 这一篇是虚拟化藤的**容器综合实战项目**——用 [05 namespaces](./05-virt-namespaces.md) + [06 cgroups](./06-virt-cgroups.md) **手工搭一个最小容器**(不依赖 Docker),把"容器本质 = 隔离 + 限资源"理解到骨子里,再对照 Docker/Podman。它是项目型节点,也是整藤的收官。

## 项目目标

很多开发者天天用 Docker,但把容器当"轻量虚拟机"黑盒用,不真正理解它。"容器"在内核侧没有任何新机制——它就是**一组进程 + 套上一组新 namespace(隔离视图) + 归入一个新 cgroup(限资源) + pivot_root 切到自己的 rootfs**。这个项目让你**手工**把这套搭出来:不装 Docker,只用 `unshare`/`cgcreate`/`chroot`/`pivot_root`,跑出一个隔离的、受限的"容器",看清容器其实就是几个系统调用的组合。

## 项目流程

**1. 准备 rootfs**:容器需要一个"根文件系统"(镜像的内容)。最简——宿主 `apk`/`debootstrap` 弄个 alpine/debian rootfs,或解压 busybox。设 `$ROOTFS=/path/to/rootfs`。

**2. 隔离 namespace**(`unshare` + `pivot_root`):

```bash
# 新建 pid/mnt/net/uts/ipc/user namespace + fork + 切 rootfs
unshare --pid --fork --mount --mount-proc --net --uts --ipc --user --map-root-user \
        bash -c '
          mount --bind '$ROOTFS' '$ROOTFS' &&
          cd '$ROOTFS' &&
          pivot_root . ./$OLD_ROOT &&   # 切根:新根 .,旧根挂 $OLD_ROOT
          exec /bin/sh
        '
```

进去后验证隔离:`ps`(只有自己,PID 1)、`mount`(独立挂载)、`ip link`(独立网络栈)、`hostname mycontainer`(改了不影响宿主)。

**3. cgroup 限资源**(宿主另开一终端):

```bash
mkdir /sys/fs/cgroup/myctr
echo "+memory +pids +cpu" > /sys/fs/cgroup/cgroup.subtree_control
echo "100M"        > /sys/fs/cgroup/myctr/memory.max   # 限 100MB 内存
echo "100"         > /sys/fs/cgroup/myctr/pids.max     # 限 100 进程
echo "<容器的PID>"  > /sys/fs/cgroup/myctr/cgroup.procs # 容器主进程归入
```

容器里跑个吃内存进程(`yes | head -c 100M`),超 100MB 被 OOM kill——验证限制生效。

**4. 对照 Docker**:同样的事用 Docker 一行:`docker run -it --memory=100m --pids-limit=100 alpine sh`。Docker 帮你做了上面 1-3 步的全部(加镜像管理 + 易用 API + 网络/卷管理)——但**内核侧机制完全一样**,就是 namespaces + cgroups + pivot_root。

## 完整容器还差什么

上面的最小容器"能跑、隔离、限资源",但离"生产容器"还差几样(这些 Docker 帮你管):

- **镜像管理**:分层 overlay 文件系统(overlayfs)叠加镜像层 + 可写层——上面用了 bind mount 单层,简化了。
- **网络**:net namespace 默认只有 `lo`,要 `veth`/bridge 连到宿主网络、配 NAT——Docker 的 `bridge`/`host`/`overlay` 网络模式管这个。
- **卷**:把宿主目录挂进容器(`-v`),持久化数据。
- **安全**:seccomp(限系统调用)、AppArmor/SELinux、capabilities 裁剪——加固隔离。

## 动手试试

1. 跑上面的手工最小容器流程,验证每一步的隔离效果(`ps`/`mount`/`ip link`)
2. 加 cgroup 限制,验证容器被限(吃内存超限 OOM、fork 超 100 失败)
3. 对照 `docker run -it --memory=100m --pids-limit=100 alpine sh` 跑同样场景,体会"内核侧完全一样、Docker 只是封装"
4. 进阶:给手工容器配 veth 网络(宿主一端 + 容器一端 + bridge + NAT),让它能 ping 通宿主/外网
5. 思考题:为什么说"容器没有新内核机制,就是 namespaces+cgroups 的组合"?(结合本项目的全部步骤)

## 延伸阅读

- 关联本站:本篇综合 [05 namespaces](./05-virt-namespaces.md) + [06 cgroups](./06-virt-cgroups.md) + [04 VM/容器项目](./04-virt-project.md);net namespace 细节在 [16 net-namespace](../kernel/net/16-net-namespace.md);overlayfs 镜像层关联 [VFS](../kernel/fs/01-fs-vfs.md)。
- 外部:[Docker 文档](https://docs.docker.com/)、[Podman](https://podman.io/)、[LXC](https://linuxcontainers.org/);经典博客 [Julia Evans: "What is a container"](https://jvns.ca/blog/2016/10/26/what-is-a-container/) 讲容器本质;`man unshare`/`cgcreate`/`pivot_root`。
- 读书笔记:[ch11](../../notes/linux_kernel_programming/ch11.md) 讲 namespaces/cgroups,本篇把它落到容器实战。
