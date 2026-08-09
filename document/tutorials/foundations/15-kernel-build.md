---
title: "Kbuild 系统:内核怎么把自己编出来"
slug: kernel-build
prerequisites:
  - linux-kconfig
  - kernel-mini-config
difficulty: intermediate
tags: [kbuild, make, vmlinux, obj-m, modules, arm64]
architectures: [arm64, arm32, riscv, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch03.md
  - source: third_party/linux（6.19）Makefile、scripts/Makefile.*、Documentation/kbuild/
maturity: drafting
related:
  - /tutorials/foundations/03-kernel-build
  - /tutorials/foundations/14-linux-kconfig
---

> 🔨 **整理中** · 这一篇深入讲 **Kbuild(内核构建系统)**——内核怎么从上万源文件 + 配置,编出一个内核镜像 + 一堆模块。[03 编译内核](./03-kernel-build.md) 里我们 `make` 过,这边拆 `obj-y/m` 怎么决定编什么、vmlinux 怎么链接成 `Image`、模块怎么变 `.ko`。

## 做什么

内核源码上万 `.c`,怎么知道哪些编进内核镜像、哪些编成模块、怎么链接成最终的 `Image`?答案是 **Kbuild**——内核自己的 Makefile 框架。它用 `obj-y`/`obj-m` 这些约定变量告诉系统"编哪些",用 `scripts/Makefile.build` 等脚本驱动 `gcc`/`ld` 实际编译,最后链接 + 压缩出 `arch/<arch>/boot/Image`。这一篇拆 Kbuild 的几个关键约定,让你读得懂内核各目录的 `Makefile`。

## 要了解什么

### 一、`obj-y` / `obj-m` / `obj-n`:编什么、怎么编

每个目录的 `Makefile` 用 `obj-*` 变量声明"本目录产出什么":

- **`obj-y += foo.o`**:把 `foo.c` 编进**内核镜像**(built-in,yes)。`obj-y` 链进 vmlinux。
- **`obj-m += foo.o`**:编成**模块** `foo.ko`(可加载)。
- `obj-n`(不编)基本不写(默认就是不编)。

`obj-$(CONFIG_FOO)` 是常见写法——Kconfig 选项 `CONFIG_FOO` 是 `y`/`m`/空,直接拼成 `obj-y`/`obj-m`/无,这样配置选项和"编不编、怎么编"自动联动。

### 二、多文件聚合:`foo-y` / `foo-objs`

一个目标 `foo` 由多个 `.c` 组成时:`obj-m += foo.o` + `foo-y := a.o b.o c.o`(或老写法 `foo-objs`),Kbuild 把 a/b/c 编出 `.o`、链接成 `foo.o`、最后 `foo.ko`。这就是 [模块参数](./09-kernel-module-params.md) 那篇提过的"链接多源文件模拟库"的底层。

### 三、`core-y` / `libs-y` / `drivers-y`:顶层目录收集

顶层 `Makefile`(`Makefile:792 core-y :=` 附近)用 `core-y`/`libs-y`/`drivers-y`/`net-y` 这些变量收集"哪些顶层目录的 built-in 要链进 vmlinux"——`init/ kernel/ mm/ fs/ ipc/ security/` 进 `core-y`,`drivers/` 进 `drivers-y` 等。各子目录的 `obj-y` 产物汇总到 `built-in.a`,最后链接成 `vmlinux`。

### 四、链接链:`.c → .o → built-in.a → vmlinux → Image`

1. `gcc` 把每个 `.c` 编成 `.o`。
2. `ar` 把各目录的 `obj-y` 产物归档成 `built-in.a`(每目录一个)。
3. 上层再归档,最终 `vmlinux.a`(`Makefile:1253 vmlinux.a:`)。
4. `ld` 链接 `vmlinux.a` + 库 → **`vmlinux`**(`Makefile:1274 vmlinux:`)——这是带调试符号的完整内核 ELF。
5. `objcopy` 把 `vmlinux` 的 `.text/.data/.bss` 提取 + 压缩(gzip/lz4/xz) → **`arch/<arch>/boot/Image`**(ARM64)或 `bzImage`(x86)——这是引导加载器加载的内核镜像。

### 五、模块:`.ko` 怎么来

`make modules` 编所有 `obj-m`。每个模块:.c → .o → `.mod.c`(Kbuild 生成的元数据文件,含 `struct module` 实例 + vermagic)→ 链接成 `foo.ko`。`.ko` 是特殊 ELF(带 `.modinfo` 段存 license/param/vermagic、`.gnu.linkonce.this_module` 段存 module 结构)。`insmod` 加载它。详见 [07 模块](./07-kernel-module-hello.md)/[09 模块参数](./09-kernel-module-params.md)。

## 动手试试

1. 读 `Makefile` 顶层(`core-y`/`libs-y`/`vmlinux:` 等规则)+ `scripts/Makefile.build`(obj-$ 怎么被处理)
2. 读 `drivers/char/Makefile` 看一个目录的 `obj-$(CONFIG_*) += *.o` 实例
3. `make ARCH=arm64 V=1 Image` 打印实际命令,看 gcc/ar/ld/objcopy 链条
4. `ls -l vmlinux arch/arm64/boot/Image`,对比两者(vmlinux 巨大带符号、Image 小且压缩)
5. 思考题:`vmlinux`(ELF)和 `Image`(引导镜像)为什么要分两个?(提示:引导加载器格式 + 体积 + 调试符号)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):顶层 `Makefile`(`core-y :792`/`vmlinux :1274`/`vmlinux.a :1253`);`scripts/Makefile.build`(`obj-$` 处理)、`scripts/Makefile.modfinal`(模块链接);`Documentation/kbuild/` 各专题(makefiles.rst/modules.rst)。
- 关联本站:[03 编译内核](./03-kernel-build.md) 实战、[14 Kconfig](./14-linux-kconfig.md) 配置系统、[07 模块](./07-kernel-module-hello.md) `.ko` 机制;本站 `scripts/linux-action-scripts.sh` 封装了编译流程。
- 读书笔记:[ch03](../../notes/linux_kernel_programming/ch03.md) 讲内核构建。
