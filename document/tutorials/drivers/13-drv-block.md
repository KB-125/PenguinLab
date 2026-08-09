---
title: "块设备驱动:gendisk 与 blk-mq"
slug: drv-block
prerequisites:
  - drv-model
next:
  - drv-netdev
difficulty: advanced
tags: [driver, block, gendisk, blk-mq, bio, request_queue, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/block/blk-mq.html
  - source: third_party/linux（6.19）include/linux/blkdev.h、include/linux/blk-mq.h、block/
maturity: drafting
related:
  - /tutorials/drivers/00-drv-model
  - /tutorials/kernel/fs/05-fs-ext4
---

> 🔨 **整理中** · 这一篇讲**块设备驱动**——磁盘/eMMC/SSD/virtio-blk 这类"按块随机访问、走块 I/O 层"的设备。素材以 6.19 源码 + kernel.org [blk-mq 文档](https://docs.kernel.org/block/blk-mq.html) 为权威。现代块驱动几乎都走 **blk-mq(多队列)** 框架,老的单队列接口已废弃——这是和 LDD3 时代最大的差别。

## 做什么

[01 chardev](./01-drv-chardev.md) 讲的字符设备,用户态 `read`/`write` 直接调驱动的 `file_operations`,数据流"直来直去"。可磁盘这类设备不一样:它们按**扇区/块**随机访问、I/O 慢且要排队、要缓冲([页缓存](../kernel/fs/04-fs-page-cache.md))、要合并/排序请求——这套复杂逻辑不可能让每个磁盘驱动自己写。所以内核有专门的**块 I/O 层**(`block/`),它提供:请求合并/排序/调度(io scheduler)、页缓存集成、多队列并发(blk-mq);块驱动只需要实现"把一个 I/O 请求发给硬件"这一段,其余的块 I/O 层替你干。这一篇拆块驱动怎么接入这套框架:`gendisk` 是磁盘抽象、`block_device_operations` 是它的 vtable、`blk-mq` 是现代驱动用的多队列接口。

## 要了解什么

### 一、块设备 vs 字符设备

| | 字符设备 | 块设备 |
|:--|:--|:--|
| 访问粒度 | 字节流,任意 | 扇区(512B)/块(通常 4KB),对齐 |
| 寻址 | 顺序(大多) | 随机 |
| 缓冲 | 驱动自管 | 走页缓存 + io scheduler |
| 接口 | `file_operations` | `block_device_operations` + blk-mq |
| 例子 | 串口/输入/字符 LCD | 磁盘/eMMC/SSD/光盘 |

块设备的 I/O 单位是 **bio**(block I/O,`include/linux/blk_types.h`)——描述"读/写 这段扇区范围,buffer 在这些 page 里"。上层 fs 的 `read_folio`/`writepage`([页缓存](../kernel/fs/04-fs-page-cache.md))最终都把请求变成 bio 提交给块层。

### 二、`gendisk`:磁盘抽象

**`struct gendisk`**(`include/linux/blkdev.h:144`)是一个**磁盘**的化身——主设备号、磁盘名(`sda`/`vdb`)、容量(扇区数)、块大小、`block_device_operations`、请求队列等。每个块设备驱动注册时,核心就是分配并填充一个 `gendisk`、`device_add_disk` 把它加进系统。`/dev/sda`、`/dev/vdb` 这些块设备节点,就是从 `gendisk` 来的。

### 三、`block_device_operations`:块设备的 vtable

**`struct block_device_operations`**(`blkdev.h:1643`)是块设备的回调表,概念类似字符设备的 `file_operations`,但**不含 read/write**——因为块 I/O 走的是 bio/请求队列,不是直接的 `read`/`write` 系统调用。它有的是:`open`/`release`(打开/关闭块设备)、`ioctl`(块特有的 ioctl,如 `BLKGETSIZE`)、`compat_ioctl`、`getgeo`(老的磁盘几何)等。读写路径不在这里,在 blk-mq 的 `queue_rq`(下一节)。

### 四、blk-mq:现代多队列框架

老内核的块层是**单队列**(所有 CPU 往一个队列提交请求,锁竞争严重),现代高速设备(SSD/NVMe)受限于它。6.x 的块层已是 **blk-mq(多队列)** ——每个 CPU(或每软件队列)一个软件队列,硬件也可有多队列(NVMe 有 64K 个队列对),blk-mq 把软件队列映射到硬件队列,大幅降锁竞争。块驱动填 **`struct blk_mq_ops`**(`blk-mq.h:488` 附近,核心回调):

- **`queue_rq`**:核心——"把一个请求发给硬件"。blk-mq 把排好序/合并好的 request 调这个回调交给驱动,驱动让它 DMA。
- `init_hctx`/`init_request`:队列/请求的初始化。
- `timeout`:请求超时处理(硬件卡了)。

驱动通过 `blk_mq_alloc_tag_set`(分配 tag set,描述硬件队列数等)+ `blk_mq_alloc_disk`(分配带 blk-mq 队列的 gendisk)接入。

### 五、注册流程与 I/O 路径

一个现代块驱动的注册流程大致:

```c
struct blk_mq_tag_set set = { .ops = &my_mq_ops, .nr_hw_queues = ..., ... };
blk_mq_alloc_tag_set(&set);
struct gendisk *disk = blk_mq_alloc_disk(&set, &my_data);
disk->major = ...;  disk->first_minor = ...;
disk->fops = &my_bdev_ops;          /* block_device_operations */
disk->private_data = &my_data;
set_capacity(disk, num_sectors);
device_add_disk(parent, disk, NULL);  /* :781 注册进系统,/dev/xxx 出现 */
```

I/O 路径(读 `/dev/sda` 一段):fs/用户态构造 bio → 块层 `submit_bio` → io scheduler 合并/排序成 request → blk-mq 调驱动的 `queue_rq` → 驱动让硬件 DMA → 完成后中断回调 `blk_mq_complete_request` → bio 完成、回到上层。整条链路里驱动只管"queue_rq 怎么发硬件、完成中断怎么收"两端,中间的排队/合并/调度全在块层。

## 动手试试

1. `lsblk`/`cat /proc/partitions` 看块设备列表(每个 `gendisk`/分区一项)
2. QEMU 加一块 virtio-blk 磁盘(`-drive file=...,if=virtio`),Guest 里 `fdisk -l`/`mount`/`dd` 测试
3. 读 `drivers/block/virtio_blk.c`(本仓库 `third_party/linux/drivers/block/`)看一个真实块驱动的 `blk_mq_ops`/`block_device_operations` 怎么填
4. `cat /sys/block/<dev>/queue/scheduler` 看当前 io scheduler(mq-deadline/kyber/none)
5. 思考题:为什么块设备的 vtable 里没有 `read`/`write`?(对比字符设备,提示:bio 请求队列模型)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/blkdev.h:144 struct gendisk`、`:1643 struct block_device_operations`、`:781 device_add_disk`、`:989 register_blkdev`;`include/linux/blk-mq.h:488 blk_mq_ops`;bio 在 `include/linux/blk_types.h`;块层实现在 `block/`(`blk-mq.c`/`blk-core.c`/`elevator.c`);示例驱动 `drivers/block/virtio_blk.c`、`drivers/block/loop.c`。
- kernel.org:[blk-mq documentation](https://docs.kernel.org/block/blk-mq.html)、`Documentation/block/` 目录各专题(request, iostat, deadline-iosched...)。
- 关联本站:本篇是 [00 driver model](./00-drv-model.md) 的块设备类型;块 I/O 的上层是 [05 ext4](../kernel/fs/05-fs-ext4.md) 的 `address_space`/页缓存;块设备是 fs 的底层存储。
