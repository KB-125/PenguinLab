---
title: "MTD 子系统:flash 存储(NAND/NOR/SPI-NOR)的统一抽象"
slug: drv-mtd
prerequisites:
  - drv-platform
  - fs-vfs
difficulty: advanced
tags: [driver, mtd, nand, nor, spi-nor, ubi, ubifs, jffs2, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/mtd/
  - source: third_party/linux（6.19）include/linux/mtd/、drivers/mtd/
maturity: drafting
related:
  - /tutorials/drivers/10-drv-platform
  - /tutorials/kernel/fs/05-fs-ext4
---

> 🔨 **整理中** · 这一篇深入讲 **MTD(Memory Technology Device)** 子系统——NAND/NOR/SPI-NOR flash 存储在内核里的统一抽象。素材以 6.19 源码 + kernel.org [MTD 文档](https://docs.kernel.org/mtd/) 为权威。它和块设备(ext4 那种)很不一样:flash 不能随便覆盖写、要按块擦除、NAND 还有坏块——所以有专门一层。

## 做什么

flash(NAND/NOR/SPI-NOR)是嵌入式的主力非易失存储:U-Boot + 内核 + rootfs + 配置全躺在 flash 上。可它和磁盘/SD 卡(块设备)有三个根本区别,导致它不能直接套块设备框架:

1. **写前必须擦除**:flash 的物理特性是"只能把 1 写成 0",要把 0 改回 1 必须先擦除整个块(把块全置 1),擦除粒度远大于写粒度(NAND 典型:写 4KB page / 擦 256KB eraseblock)。
2. **擦除次数有限**:每个块只能擦几万~十万次(NAND ~10万、NOR ~10万),到点就坏——必须做**磨损均衡(wear leveling)**,把写均匀分散到各块。
3. **NAND 有坏块**:出厂就有坏块、用中还会产生新坏块,要**坏块管理(BBM)**标记/避开。

MTD 子系统(`drivers/mtd/`)就是为这套特性设计的存储层。它上面挂文件系统(JFFS2/UBIFS——专为 flash 设计的"日志结构"fs),下面接各 flash 控制器驱动(NAND/eMMC/SPI-NOR/OneNAND...)。这一篇拆 MTD 的三层结构、`mtd_info` 核心结构、NAND vs NOR 差异、以及 UBI/UBIFS 怎么在 MTD 上解决磨损均衡和坏块。

## 要了解什么

### 一、MTD 的三层结构

```
┌─────────────────────────────────────┐
│  文件系统层:JFFS2 / UBIFS / ...      │  ← 专为 flash 设计的 fs
├─────────────────────────────────────┤
│  UBI(Unsorted Block Images)         │  ← 可选:在 raw NAND 上做卷管理+磨损均衡
├─────────────────────────────────────┤
│  MTD 核心(drivers/mtd/mtdcore.c)    │  ← 统一抽象 mtd_info
├─────────────────────────────────────┤
│  flash 类型驱动                      │
│  NAND(drivers/mtd/nand/)/           │
│  NOR(drivers/mtd/maps/)/            │
│  SPI-NOR(drivers/mtd/spi-nor/)/     │
│  SPI-NAND(drivers/mtd/nand/spi/)    │
└─────────────────────────────────────┘
   flash 控制器硬件(NAND/eMMC/SPI 控制器)
```

最底层是 **flash 控制器驱动**(管硬件时序、DMA),它向上注册成 `mtd_info`;MTD 核心提供 `/dev/mtdN`(字符接口,直接读/写/擦)、`/dev/mtdblockN`(块接口,凑合用)、IOCTL;再上面是文件系统(直接挂 raw MTD 用 JFFS2,或先过 UBI 再挂 UBIFS)。

### 二、`struct mtd_info`:一个 MTD 设备的化身

**`struct mtd_info`**(`include/linux/mtd/mtd.h:238`)是 MTD 核心。关键字段 + 回调:

```c
struct mtd_info {
    u_char type;              /* MTD_NANDFLASH / MTD_NORFLASH / MTD_RAM */
    uint32_t flags;           /* MTD_WRITEABLE / MTD_NO_ERASE / MTD_BIT_WRITEABLE... */
    uint64_t size;            /* 总大小 */
    uint32_t erasesize;       /* 擦除块大小(NAND ~128-512KB,NOR ~64-128KB) */
    uint32_t writesize;       /* 写粒度(NAND page: 2-4KB,NOR ~1 字节) */
    uint32_t oobsize;         /* OOB 区大小(NAND 独有,放 ECC/坏块标记) */
    const char *name;
    ...
    int  (*_read)(struct mtd_info *mtd, loff_t from, size_t len, ...);   /* 读 */
    int  (*_write)(struct mtd_info *mtd, loff_t to, size_t len, ...);    /* 写(只能 1→0) */
    int  (*_erase)(struct mtd_info *mtd, struct erase_info *instr);       /* 擦(块置 1) */
    int  (*_read_oob)(...);    /* 读 OOB(NAND) */
    int  (*_write_oob)(...);   /* 写 OOB */
    int  (*_block_isbad)(...); /* 查坏块(NAND) */
    int  (*_block_markbad)(...); /* 标坏块 */
    ...
};
```

`type`/`erasesize`/`writesize`/`oobsize` 这些几何参数决定了"这 flash 怎么用"。`_read/_write/_erase/_read_oob/_write_oob/_block_isbad` 是 flash 类型驱动(NAND/NOR/...)填的回调,MTD 核心和文件系统通过 `mtd_info` 这些指针操作硬件,不直接碰控制器寄存器。

### 三、NAND vs NOR vs SPI-NOR

| | NOR | NAND | SPI-NOR |
|:--|:--|:--|:--|
| 读 | 随机读、像 RAM(XIP 可直接执行代码) | 顺序读快、随机慢 | 通过 SPI,慢于并行 NOR |
| 写粒度 | 单字节/bit | page(2-4KB) | page/扇区 |
| 擦除块 | 均匀 ~64-128KB | ~128-512KB | ~4-64KB |
| 容量 | 小(几 MB) | 大(几 GB) | 中(几-几十 MB) |
| 坏块 | 无 | 有(出厂+运行中) | 一般无 |
| OOB/ECC | 无 | 有(OOB 存 ECC + 坏块标记) | 一般无 |
| 典型用途 | 存 U-Boot/内核(XIP 启动) | 大容量 rootfs/数据 | 小容量固件/配置(SPI 总线挂) |

NOR 因为能像 RAM 随机读,支持 **XIP(eXecute In Place)**——CPU 直接从 NOR flash 取指令执行,不用先拷到 RAM(早期 U-Boot 就 XIP 在 NOR 上)。NAND 容量大但有坏块、要 ECC,所以 NAND 上必须用 JFFS2/UBIFS 这种"带坏块管理 + ECC + 磨损均衡"的文件系统,不能直接 ext4。

### 四、OOB 与 ECC(NAND 独有)

NAND 的每个 page 除了主数据区,还有一小段 **OOB(Out-Of-Band)** 区(几十字节)。OOB 的用途:

- **ECC(纠错码)**:NAND 读取有比特翻转(读多了/老化),OOB 存软件 ECC(Hamming/BCH/RS),读时校验+纠错(1-bit 翻转能纠正、多了报错)。现代 NAND(Bit Error Rate 高)必须用强 ECC(BCH 4/8/24-bit、甚至需要硬件 ECC 引擎)。
- **坏块标记**:出厂坏块 + 运行中坏块,在 OOB 特定位置标记(MTB 一般在 page 0/1 的 OOB)。
- **文件系统元数据**:JFFS2/UBIFS 用 OOB 存自己的节点头。

`mtd_info._read_oob`/`_write_oob`/`_block_isbad` 就是处理这套。`_read`/`_write` 对 NAND 也隐含走 OOB 的 ECC(读时校验、写时算 ECC 写 OOB)。

### 五、分区:`mtd_partition`

一块 flash 物理上常分成几段:U-Boot 分区 / 内核分区 / rootfs 分区 / 数据分区。MTD 用 **`struct mtd_partition`**(`include/linux/mtd/partitions.h:46`)描述:

```c
struct mtd_partition {
    const char *name;        /* "kernel" / "rootfs" / ... */
    uint64_t size;           /* 分区大小(MTD_PART_SIZE_SIZ 为用剩余) */
    uint64_t offset;         /* 起始偏移 */
    uint32_t mask_flags;     /* MTD_WRITEABLE(只读,保护内核/U-Boot 分区) */
    ...
};
```

分区来源:设备树(`partitions { ... }` 节点,6.x 主流 `fixed-partitions`)、或 cmdline `mtdparts=`(老式)。注册后每个分区变成独立的 `mtd_info`(`mtd0`=整片、`mtd1`=kernel、`mtd2`=rootfs...),用户态 `/dev/mtdN` 各对应一个,可独立读写擦。`mtdparts=spi0.0:1M(uboot)ro,4M(kernel),-(rootfs)` 这种 cmdline 在老内核常见,现代用设备树 `fixed-partitions`。

### 六、UBI/UBIFS:在 raw NAND 上的卷管理 + 文件系统

直接在 raw NAND MTD 上挂 JFFS2 可以,但 JFFS2 在大容量 NAND 上挂载慢、磨损均衡弱。所以有 **UBI**(Unsorted Block Images,`drivers/mtd/ubi/`):

- UBI 在 MTD 之上做**卷管理**(把物理 eraseblock 池,逻辑切成多个 UBI volume)+ **磨损均衡**(把写均匀分散到所有 eraseblock,即便某个 volume 写得多)+ **坏块管理"(跳过坏 eraseblock)。
- **UBIFS**(`fs/ubifs/`)挂在 UBI volume 上,是专为 NAND 设计的现代文件系统(支持压缩、快速挂载、断电安全)。
- 所以大容量 NAND rootfs 典型链路:`NAND 硬件 → MTD → UBI → UBIFS`。

### 七、用户态接口

- **`/dev/mtdN`(字符)**:`read/write` 直接读写(写前要 `MEMUNLOCK` + `MEMERASE` ioctl 擦除);`flashcp`/`flash_erase`/`nandwrite` 工具操作它。
- **`/dev/mtdblockN`(块)**:把 MTD 包成块设备,但**没有磨损均衡**(凑合用,不建议挂可写 fs)。
- `/proc/mtd`:列出所有 mtd 设备 + 几何(size/erasesize)。
- `mtd_debug`/`nanddump`/`nandwrite`/`flash_eraser`:MTD 工具集(mtd-utils 包)。

### 八、踩坑

- **NAND 写前必须擦**:直接 `_write` 到没擦的区域,行为未定义(可能写失败/数据错)。MTD 字符接口要求用户态先 `MEMERASE` 再 `write`;`nandwrite` 工具自动按 erase 擦。
- **NAND 坏块**:别假设"flash 所有块都好"——出厂坏块表要保留、运行中新坏块要标记。直接绕过 UBI 用 raw MTD,得自己处理坏块(难);用 UBI 它替你管。
- **`mtdblock` 不适合可写 fs**:它没磨损均衡、没坏块管理,频繁写会很快写坏某块。可写 fs 用 JFFS2/UBIFS(走 raw MTD 字符接口 + fs 自己管)。
- **ECC 强度**:老 NAND 用 1-bit Hamming 够,新 NAND(MLC/TLC、高密度)必须 BCH 8/24/40-bit 甚至硬件 ECC,配错 ECC 强度会数据损坏。

## 动手试试

1. `cat /proc/mtd`(若系统有 MTD)看 mtd 设备 + 几何;`mtdinfo /dev/mtdN` 看详细
2. QEMU 可加 `-drive if=pflash,format=raw,file=flash.img`(NOR)、或 `-machine virt` 自带的 flash,在 Guest 里看 `/dev/mtd*`
3. 读一个 SPI-NOR 驱动(`drivers/mtd/spi-nor/` 下如 `spi-nor-core.c` / `controllers/`)看 `mtd_info` 怎么填(`_read/_write/_erase` 调 SPI 传输)
4. `flash_erase /dev/mtdN 0 0` + `nandwrite /dev/mtdN image.bin`(若有 mtd-utils),体验"擦-写"流程
5. 思考题:为什么 NAND 不能直接挂 ext4(像 SD 卡那样)?结合本篇前三个根本区别答

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/mtd/mtd.h:238 struct mtd_info`、`include/linux/mtd/partitions.h:46 struct mtd_partition`;MTD 核心 `drivers/mtd/mtdcore.c`/`mtdchar.c`(`dev/mtdN`)/`mtdblock.c`(`mtdblockN`);NAND 子系统 `drivers/mtd/nand/`(raw NAND + SPI-NAND)、SPI-NOR `drivers/mtd/spi-nor/`、NOR(map-based)`drivers/mtd/maps/`;UBI `drivers/mtd/ubi/`、UBIFS `fs/ubifs/`、JFFS2 `fs/jffs2/`。
- kernel.org:[MTD](https://docs.kernel.org/mtd/)、`Documentation/devicetree/bindings/mtd/`;`mtd-utils`(用户态工具)项目。
- 关联本站:[10 platform](./10-drv-platform.md) NAND/SPI-NOR 控制器是 platform 设备、[24 spi](./24-drv-spi.md) SPI-NOR 走 SPI;UBIFS/MTD 作为存储是 [05 ext4](../kernel/fs/05-fs-ext4.md) 块设备 fs 的"flash 侧对照"。
