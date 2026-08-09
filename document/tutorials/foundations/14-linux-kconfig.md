---
title: "Kconfig 系统:内核配置语言与 defconfig 流程"
slug: linux-kconfig
prerequisites:
  - kernel-mini-config
  - kernel-build
difficulty: intermediate
tags: [kconfig, build, defconfig, merge_config, menuconfig]
architectures: [arm64, arm32, riscv, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch02.md
  - source: third_party/linux（6.19）Kconfig、scripts/kconfig/、Documentation/kbuild/kconfig.rst
maturity: drafting
related:
  - /tutorials/foundations/02-kernel-mini-config
  - /tutorials/foundations/03-kernel-build
---

> 🔨 **整理中** · 这一篇深入讲 **Kconfig 系统**——内核配置背后的语言和流程。[02 mini config](./02-kernel-mini-config.md) 里我们实战用过 `allnoconfig + merge_config + olddefconfig`,这篇拆开 Kconfig 语言本身(config/menuconfig/choice/depends on/select)、defconfig 流程、`.config` 到 `autoconf.h` 的转换。它和 [02](./02-kernel-mini-config.md) 实战互补:那边"怎么用",这边"为什么这么用"。

## 做什么

内核有上千个配置选项(`CONFIG_*`),它们怎么定义、怎么互相约束、怎么从"人写的 defconfig"变成"编译时 C 宏"?答案就是 **Kconfig** ——内核自己的配置描述语言 + 一套生成器(scripts/kconfig/)。这一篇拆 Kconfig 语言的语法、配置流程的几个阶段(`menuconfig` → `defconfig`/`olddefconfig`/`syncconfig`)、以及 `.config` 如何转换成编译时可见的 `autoconf.h`。

## 要了解什么

### 一、Kconfig 语言:config/menuconfig/choice/source

Kconfig 源文件遍布源码树(各 `Kconfig` 文件),顶层是 `Kconfig`(`mainmenu "Linux/..."`),用 `source "..."` 把各子系统的 `Kconfig` 串进来(如 `source "init/Kconfig"`)。核心语法:

- **`config NAME`**:定义一个配置项。下面 `bool`/`tristate`/`int`/`hex`/`string` 定类型、`prompt "desc"`/`default y`/`depends on X`/`select Y`/`help`。
- **`menuconfig`**:带子菜单的 config(进入子菜单看子项)。
- **`choice`**:多选一(一组互斥选项,如 CPU 型号)。
- **`depends on`/`select`/`imply`**:依赖关系——`depends on X`(X 没开则此项不可见)、`select Y`(开此项自动开 Y,强拉)、`imply Y`(弱拉,可被关掉)。
- **`if`/`endif`**/`menu`/`endmenu`:批量约束。

tristate 是 Kconfig 特有的三态:`y`(编进内核)/`m`(模块)/`n`(不开)——很多驱动选项是 tristate,决定它编进 vmlinux 还是独立模块。

### 二、配置流程:defconfig / oldconfig / syncconfig

- **`make defconfig`**:生成架构默认配置(`arch/<arch>/defconfig`)。
- **`make menuconfig`**(ncurses 菜单)/`xconfig`(Qt)/`gconfig`(GTK):交互式改配置。
- **`make oldconfig`**:有新选项时逐个问;**`olddefconfig`**:对新增项用默认值(不问)——[02](./02-kernel-mini-config.md) 里我们 `merge_config.sh` 后用它。
- **`make syncconfig`(自动触发)**:`.config` 改了之后,同步它和"实际生效配置"(增量编译时自动跑,生成 `include/config/auto.conf` + `autoconf.h`)。
- **`make savedefconfig`**:把当前 `.config` 精简成最小 defconfig(只记非默认项),版本可控。

### 三、`.config` → `autoconf.h` + `auto.conf`

`.config` 是人/工具维护的配置文本(`CONFIG_X=y`/`=m`/`# CONFIG_X is not set`)。编译时 `syncconfig` 把它生成两个东西:

- **`include/generated/autoconf.h`**:C 头(`#define CONFIG_X 1`/`#define CONFIG_X_MODULE 1`),C 源码 `#ifdef CONFIG_X` 用它。
- **`include/config/auto.conf`**:Make 用(`CONFIG_X=y` 给 Kbuild Makefile 用,如 `obj-$(CONFIG_X) += x.o`)。

所以改了 `.config`,触发 `syncconfig` 重生这两个,后续编译才用新配置。`auto.conf` 是 Make 层、`autoconf.h` 是 C 层——两边都对齐。

### 四、merge_config.sh:fragment 合并

`scripts/kconfig/merge_config.sh`([02](./02-kernel-mini-config.md) 用过)把几个"配置片段(fragment,`.config` 片段)"合并到基础 `.config`:它本质是逐个 `cat` fragment + 跑 `olddefconfig` 让依赖关系自洽。用途:把"通用配置 + 板子特化 + 调试选项"几个 fragment 叠加,生成完整 `.config`,避免维护一份巨大的 defconfig。内核 CI 和发行版广泛用它。

## 动手试试

1. `make ARCH=arm64 menuconfig` 进交互菜单,找几个 `config`(如 `CONFIG_PREEMPT`),看它的 prompt/depends/select/help
2. 读 `init/Kconfig`(几百个核心选项)或 `drivers/char/Kconfig` 看 Kconfig 语法实例
3. `make savedefconfig` 把当前配置精简成最小 defconfig,对比全 `.config` 的体积
4. `cat include/generated/autoconf.h | head` 看 `.config` 怎么变成 C 宏
5. 思考题:tristate 的三态(y/m/n)为什么比 bool 更适合内核配置?(提示:模块化)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):顶层 `Kconfig`(`mainmenu`/`source`);`scripts/kconfig/`(Kconfig 解析器,`confdata.c`/`menu.c`/`expr.c`);`scripts/kconfig/Makefile`(defconfig/olddefconfig/syncconfig 目标);`Documentation/kbuild/kconfig.rst` 是 Kconfig 语言官方规范。
- 关联本站:[02 mini config](./02-kernel-mini-config.md) 实战用 merge_config + olddefconfig、[03 编译内核](./03-kernel-build.md) defconfig 流程;本站 `configs/` 是 merge_config 的 fragment 实践。
- 读书笔记:[ch02](../../notes/linux_kernel_programming/ch02.md) 讲内核配置。
