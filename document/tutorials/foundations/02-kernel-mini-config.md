---
title: "Mini Config：从零设计一份精简的内核配置"
prerequisites:
  - wsl2-env-toolchain
next:
  - kernel-build
difficulty: beginner
tags: [kconfig, allnoconfig, merge_config, arm64, kernel-config]
architectures: [arm64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch01.md
maturity: verified
---

## 做什么

这篇我们要做一件很多人不会告诉你的事——亲手设计一份精简的内核配置，而不是无脑用 `defconfig`。最终我们会得到一份只包含 QEMU virt 机器启动所需最小功能集的内核配置，它只有 442 个 `=y` 配置项，而 `defconfig` 有 952 个。

啊，你说咱们这么快就动手嘛？对啊，不然呢？哈哈！咱们自己，亲手来配置一份内核，香不香？

## 要了解什么

### defconfig 的问题

`defconfig` 是内核源码里预定义的默认配置，对于 ARM64 来说它位于 `arch/arm64/configs/defconfig`。跑一遍 `make defconfig` 就能得到一份"能跑"的内核配置，听起来很美好，问题是这份配置包含了大量真实 SoC 的驱动——GPU、音频、各种开发板的外设驱动等等。我们用 QEMU virt 机器做内核学习，根本不需要这些硬件支持，它们除了拖慢编译速度和分散注意力之外没有任何用处。

更直白地说，952 个 `=y` 项里面有超过一半是我们永远用不到的，编译出来多出的那几百个驱动在 QEMU 里也全都是 dead code。与其在一个臃肿的内核里学习，不如我们自己来裁剪。

### 三步配置流程

我们的策略是"从零开始，按需开启"，具体分三步走。

第一步，用 `allnoconfig` 生成一个几乎全关的基础配置。这个目标会让所有非必须的配置项都设为 `n`，只保留架构本身的硬性依赖。对于 ARM64 来说，生成的 `.config` 大约只有几十个选项是开着的，其他全部关闭。

```bash
cd third_party/linux
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     O=../../out/build_latest_arm64 allnoconfig
```

第二步，用 `merge_config.sh` 把我们准备好的 config fragment 合并进去。这个脚本位于内核源码的 `scripts/kconfig/` 目录下，它把 fragment 里的配置项逐条合并到基础配置中——遇到 `=y` 就开启，遇到 `=m` 就设为模块。

调用时有两个参数容易记反：`-m` 是"只合并、不跑 make"的开关，本身不带路径；决定写到哪里的是 `-O <dir>`——脚本最终把合并结果写进 `$OUTPUT/.config`，省略 `-O` 就写到当前目录的 `./.config`。第一个位置参数才是作为基础的 `.config`，后面跟着 fragment。所以正确的写法是：

```bash
scripts/kconfig/merge_config.sh -m -O ../../out/build_latest_arm64 \
    ../../out/build_latest_arm64/.config \
    ../../configs/arm64-qemu-virt-learn.config
```

注意 `-O` 不能省。如果你在 `third_party/linux` 下执行又漏了 `-O`，合并结果会写进源码树的 `.config`，而 `out/build_latest_arm64/.config` 还是那份没合并过的 `allnoconfig`；加上 `-m` 不跑 make、不做任何校验，这个错误会一路静默地带到编译和启动（见下文踩坑记录）。

第三步，用 `olddefconfig` 让内核构建系统自动补齐所有依赖。我们手写的 fragment 只列了"我们知道自己需要的"选项，但内核配置之间有大量隐式依赖——比如开启了 `CONFIG_PRINTK=y`，它可能还依赖其他几个配置项。`olddefconfig` 会遍历整个配置树，把缺失的依赖全部自动补上，同时对新出现的配置项使用默认值：

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     O=../../out/build_latest_arm64 olddefconfig
```

合并完成后先自检一眼，四个关键项缺一不可：

```bash
grep -E '^CONFIG_(SERIAL_AMBA_PL011|SERIAL_AMBA_PL011_CONSOLE|BLK_DEV_INITRD|RD_GZIP)=' \
     out/build_latest_arm64/.config
```

四项必须全是 `=y`。缺任何一项，内核要么没有串口输出、要么忽略 initrd，QEMU 启动时就只剩"卡在 Starting QEMU..."、没有任何日志。

顺带说下日志格式：fragment 里还开了 `CONFIG_PRINTK_TIME=y`，内核日志每行才会带上 `[    0.000000]` 这样的启动时间戳（下一篇的 boot log 就是这个样子）。`allnoconfig` 默认把它关掉，日志会退化成没有时间戳的裸文本——排查"卡在哪一步、每步耗时多少"时会非常难受。想在不改配置的情况下临时打开，可以给内核加命令行参数 `printk.time=1`。

三步走完之后，最终的 `.config` 从几十项膨胀到了 538 项——多出来的那些全是 `olddefconfig` 自动补齐的依赖。这个数字依然只有 `defconfig`（6.19 内核下是 3305 项）的六分之一左右，而且每一个开启的配置项都能追溯到我们 fragment 里的某个明确需求。

### Config Fragment 的设计思路

我们准备好的 fragment 文件是 [configs/arm64-qemu-virt-learn.config](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/configs/arm64-qemu-virt-learn.config)，它按功能分类组织，每一组都有注释说明"为什么需要这些配置"。当然，您可能会问这些都是啥。如果您不是很清楚——一个最好的办法就是递归下降法的查询相关的概念。我们这里快速的说一下这些内容都是啥：

先说平台基础。ARM64 架构本身是必须的，SMP（对称多处理器）也要开，因为我们后续的 QEMU 启动会配两个 CPU 核：

```
CONFIG_ARM64=y
CONFIG_64BIT=y
CONFIG_SMP=y
CONFIG_NR_CPUS=2
```

接下来是串口控制台。QEMU virt 机器用 ARM PL011 UART 做串口输出，`console=ttyAMA0` 内核启动参数指向的就是它。不开这些配置的话，内核启动后你什么都看不到——没有启动日志，没有 shell 提示符，整个世界一片寂静：

```
CONFIG_TTY=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
```

然后是 initramfs 支持。我们的根文件系统会打包成 cpio.gz 格式作为 initrd 加载，内核必须支持 gzip 解压才能解包它：

```
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
```

文件系统方面，`devtmpfs` 让内核自动在 `/dev` 下创建设备节点，`procfs` 和 `sysfs` 分别提供 `/proc` 和 `/sys` 的内核信息接口，`tmpfs` 用于内存文件系统——这四个是 BusyBox shell 能正常工作的基本前提。内核模块相关的配置让我们后续可以加载和卸载 `.ko` 模块，而调试支持那一组（`DEBUG_INFO`、`GDB_SCRIPTS`、`KALLSYMS`）是为 GDB 远程调试准备的。

整个 fragment 大概 40 行，每个配置项都有一行注释说明它的用途和依赖关系。这种"最小化 + 注释"的方式让配置文件本身就成了一份学习笔记。

### 踩坑记录

这三步流程说起来简单，但实际操作的时候我们踩了不少坑，这里把最值得记录的几个列出来。

**"The source tree is not clean"**

这是最容易遇到的问题。内核 Makefile 里面有一个检查逻辑（在 `Makefile` 的 `outputmakefile` 目标中），当你使用 `O=` 分离编译目录时，它会检测源码树根目录下是否存在 `.config` 文件、`include/config/` 目录、或者 `arch/arm64/include/generated/` 目录。只要检测到其中任何一个，就会判定"源码树不干净"然后拒绝继续。

我们碰到的更麻烦：之前用老写法跑过 `merge_config.sh`（没带 `-O`），合并结果被写进了源码树根目录的 `.config`，于是后面 `make O=... olddefconfig` 报了 "source tree is not clean"；照着报错删掉源码树的 `.config` 再跑一遍，这次通过了——但用的是构建目录里那份**从未合并过 fragment 的 `allnoconfig`**。最终编出来的内核没有串口驱动、也没有 initramfs 支持，QEMU 启动后一个字节都打印不出来。

所以根子不是"源码树脏"，而是配置根本没写进构建目录。两件事一起做：

```bash
rm -f third_party/linux/.config      # 清掉老写法留下的残留
# 再用上面带 -O 的命令重新合并，并 grep 自检四个关键项
```

预防原则：用 `O=` 分离构建目录时，`merge_config.sh` 一律带 `-O`，每次合并后立刻自检，别把"没报错"当成"配对了"。

**merge_config.sh 的参数**

最容易记反的是这两个：

- `-m` 后面**不跟**路径，它只是"只合并、不跑 make"的开关；
- `-O <dir>` 决定结果写到 `$OUTPUT/.config`，不给就默认写当前目录的 `./.config`。

第一个位置参数才是基础 `.config`（读入后作为合并起点），其余位置参数是 fragment。所以正确调用是 `merge_config.sh -m -O <output_dir> <output_dir>/.config <fragment>`，而不是 `merge_config.sh -m <output_dir>/.config <fragment>`——后者会把合并结果写进当前目录。

**忘记设 ARCH 编译成了 x86**

这个坑真的很经典。内核构建系统根据 `ARCH` 变量决定目标架构，不设就默认宿主架构（WSL2 里是 x86_64）。`CROSS_COMPILE` 不设就用本机 gcc。结果就是 `make -j14` 跑完了，输出 `arch/x86/boot/bzImage is ready`——编译了半天全是白费。

解决办法有两个：要么每一行 make 命令都带 `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`，要么在 shell 里 export 这两个变量。后者更省心，但要注意 export 只对当前 shell 会话有效，关掉终端重新开就得再设一次。

**工作目录与 make -C**

从项目根目录 `PenguinLab/` 直接跑 `make O=... Image` 会报 `No targets specified and no makefile found`，因为项目根目录没有内核的 Makefile。要么先 `cd third_party/linux` 再跑 make，要么用 `make -C third_party/linux` 显式指定源码目录。

## 动手试试

1. 确认 `third_party/linux/Makefile` 存在，如果不存在先运行 `./scripts/linux-submodule.sh init` 拉取内核源码
2. 按顺序执行三步配置流程：`allnoconfig` → `merge_config.sh` → `olddefconfig`，第 1、3 步记得带 `ARCH` 和 `CROSS_COMPILE`，第 2 步务必用 `-O` 指向构建目录
3. 用 `grep -c "=y" out/build_latest_arm64/.config` 统计最终配置项数量，6.19 内核下应该看到 538 左右
4. 用 `diff <(grep "=y" out/build_latest_arm64/.config | sort) <(grep "=y" <(make ARCH=arm64 O=../../out/build_latest_arm64 defconfig && cat ../../out/build_latest_arm64/.config) | sort)` 对比一下和 defconfig 的差距，看看我们砍掉了哪些东西

## 延伸阅读

- [Kbuild 内核构建系统文档](https://www.kernel.org/doc/html/latest/kbuild/kbuild.html) — `ARCH`、`CROSS_COMPILE`、`O=` 等变量的官方定义
- [Linux 内核构建说明](https://docs.kernel.org/admin-guide/README.html) — kernel.org 官方的编译入门指南
- [configs/arm64-qemu-virt-learn.config](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/configs/arm64-qemu-virt-learn.config) — 我们的 mini config fragment 文件，每个配置项都有注释
