---
title: "Buildroot:自动化构建整套嵌入式 Linux 系统"
slug: embed-buildroot
prerequisites:
  - embed-rootfs
next:
  - embed-bsp-project
difficulty: intermediate
tags: [embedded, buildroot, rootfs, buildsystem, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - source: Buildroot 项目(本仓库不含),官方文档
maturity: drafting
related:
  - /tutorials/embedded/05-embed-rootfs
---

> 🔨 **整理中** · 这一篇专讲 **Buildroot**——上一片说"手搓 rootfs 拼不齐应用和库,有 Buildroot 自动化构建"。**本仓库只覆盖 Buildroot 工具的使用层**(选板/配置/构建/产物部署);**项目级构建后端的完整实现——自定义 defconfig、新增 package、镜像变体管理——归本站独立项目 *-forge 维护,不在本仓库展开**。Buildroot 是小到中型嵌入式系统的首选构建器。

## 做什么

[05 rootfs](./05-embed-rootfs.md) 讲了手搓 BusyBox rootfs 的局限——只能拼最小系统,加个应用/库就要手编、手配。**Buildroot** 把整个嵌入式 Linux 系统的构建**自动化**:你描述目标(架构/工具链/内核版本/库/应用/init 系统),它 `make` 后自动交叉编译一切、打包成 deploy-ready 的镜像(内核 + rootfs + bootloader,各种格式)。不用手编每个组件、手拼 rootfs。这一篇讲 Buildroot 的工作流、定制点、输出。

## 要了解什么

### 一、核心流程:defconfig → menuconfig → make

```bash
# 1. 选一个目标板/场景的预设配置(Buildroot 自带几百个 defconfig)
make qemu_aarch64_virt_defconfig          # 选 QEMU ARM64 virt 的预设

# 2. 定制(类似内核 menuconfig)
make menuconfig                            # 改架构/工具链/内核/包/init 系统/...

# 3. 一键构建(几分钟到几十分钟,自动下源码 + 交叉编)
make

# 4. 产物在 output/images/
ls output/images/                          # Image(内核)/rootfs.ext4/rootfs.cpio/initramfs.cpio.gz/...
```

Buildroot 的 `menuconfig` 分几大块:`Target options`(架构/ABI/CPU/浮点)、`Build options`(并行度/编译优化)、`Toolchain`(用内部构建工具链 or 外部预编)、`System configuration`(主机名/root 密码/init 系统/登录)、`Kernel`(内核版本/配置/打补丁)、`Target packages`(几百个可选应用/库——BusyBox/dropbear/openssh/SQLite/Python/...)、`Filesystem images`(cpio/ext4/squashfs/ubi 选哪些)、`Bootloaders`(U-Boot/grub/...)。

### 二、构建产物与部署

`make` 后 `output/images/` 下是一套 deploy 镜像:

- `Image`/`zImage`(内核)、`*.dtb`(设备树)
- `rootfs.ext4`/`rootfs.cpio`/`rootfs.squashfs`/`rootfs.ubifs`(各种格式的 rootfs)
- `u-boot.bin`/`boot.scr.uimg`(bootloader + 启动脚本,若开了)

直接拿这套镜像刷进板子(QEMU `-kernel Image -drive rootfs.ext4`、或 dd 进 SD/eMMC)就能跑。Buildroot 还能生成 SDK(`make sdk`)——给应用开发者用的交叉工具链 + 目标 sysroot,让他们独立编应用而不重编整个系统。

### 三、定制/扩展(归 *-forge,本仓库不展开)

"自定义 defconfig(`configs/myboard_defconfig` + `make savedefconfig` 精简)、新增 package(`package/<name>/Config.in` + `*.mk`)、镜像变体管理"这类**项目级构建后端实现**,本站放在独立项目 **\*-forge** 维护,本仓库不展开——本篇只讲 Buildroot 工具的使用层。想看本站具体怎么定制 Buildroot,转 *-forge 仓库;只想学会用 Buildroot,前面两节(核心流程 + 产物)就够跑通。Buildroot 本身的扩展机制详见官方 Manual(下节)。

### 四、Buildroot vs Yocto(再对比)

| | Buildroot | Yocto |
|:--|:--|:--|
| 学习曲线 | 陡度低,简单 | 陡,复杂 |
| 包管理 | 无(每次重编整个 rootfs) | 有(rpm/deb/ipk,可在线升级包) |
| 适合 | 单一镜像、小系统、要简单 | 多变体、产品级、需长期维护/OTA |
| 输出 | 一个 rootfs 镜像 | 一整套发行版 + SDK + 包仓库 |

简单说:学习/中小嵌入式产品用 Buildroot;手机/IoT 大规模量产需 OTA 和包管理用 Yocto。

## 动手试试

1. 下载 [Buildroot](https://buildroot.org),`make qemu_aarch64_virt_defconfig && make` 跑通(可能几十分钟),拿到 `output/images/`
2. 用产物的 `Image` + `rootfs.ext4` 跑 QEMU(`qemu-system-aarch64 -M virt -cpu cortex-a53 -kernel Image -drive rootfs.ext4 -append "root=/dev/vda console=ttyAMA0"`),进 BusyBox shell
3. `menuconfig` 改个定制(如换内核版本、加 dropbear SSH、换 init),`make` 重构,对比差异
4. 思考题:为什么 Buildroot 不支持"在线包管理"(像 apt 那样),而 Yocto 可以?(提示:构建模型——整体重编 vs 包分发)

## 延伸阅读

- 外部:[Buildroot 官网](https://buildroot.org)、[Buildroot Manual](https://buildroot.org/downloads/manual/manual.html)(含新增 package、自定义 defconfig、各 fs 格式的详尽说明)、源码 `docs/`。
- 关联本站:[05 rootfs](./05-embed-rootfs.md) 概念、[04 BusyBox](../foundations/04-busybox-rootfs.md) 手搓(对比自动化的 Buildroot);本站 `scripts/rootfs-minimal-maker.sh` 是"手搓"侧的极简版。
