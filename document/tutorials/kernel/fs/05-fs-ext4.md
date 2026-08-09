---
title: "ext4:磁盘文件系统怎么把"文件"真正落进盘里"
slug: fs-ext4
prerequisites:
  - fs-vfs
  - fs-page-cache
difficulty: advanced
tags: [filesystem, ext4, disk-fs, superblock, inode, extent, journal, block-group, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/filesystems/ext4/
  - source: third_party/linux（6.19）fs/ext4/、fs/jbd2/
maturity: drafting
related:
  - /tutorials/kernel/fs/01-fs-vfs
  - /tutorials/kernel/fs/04-fs-page-cache
---

> 🔨 **整理中** · 这一篇是 fs 藤的压轴,也是整条藤最"硬"的一篇——讲一个真正的**磁盘文件系统** ext4 怎么把"文件"组织到块设备上。前四篇(procfs/sysfs/page-cache/vfs)里的 inode 多半是内存造的伪 inode,这一篇的 inode 是**真落盘**的:关机断电还在,重启后原样读回。素材以 6.19 源码(`fs/ext4/`)为权威、kernel.org 的 [ext4 文档](https://docs.kernel.org/filesystems/ext4/) 做框架。结构体行号对照 `third_party/linux/`;journal(jbd2)、多块分配器(mballoc)等子系统只点到、不深入(标"深入待补")。

## 做什么

前面四篇我们把 VFS 抽象、procfs/sysfs 伪文件系统、页缓存都过了一遍,但一直刻意没碰"文件到底怎么存到磁盘上"这件事——因为那是磁盘文件系统的专属问题,而且复杂得多。一个 ext4 文件系统,要在块设备(磁盘、eMMC、QEMU 的 virtio-blk)的一堆扇区上,组织出"目录树、文件、权限、大文件的千千万万个数据块",断电后还能毫发无损地读回来——这套组织就是 ext4 的磁盘格式。这一篇我们拆三件事:ext4 在磁盘上**长什么样**(超级块、块组、inode 表、数据块)、它怎么用 **extent tree** 取代老式间接块来管理大文件、以及它怎么**接入 VFS**——把 [fs-vfs](./01-fs-vfs.md) 那套四对象 + ops 表"填上 ext4 自己的实现",从而让 `read/write` 最终落到磁盘块上。

## 要了解什么

### 一、磁盘文件系统的本质:磁盘格式 + 内存化身

先把磁盘文件系统和伪文件系统最根本的区别刻死:**磁盘文件系统有一套"磁盘上的字节布局"**。ext4 在块设备上的每一字节都有约定的含义:最开头是超级块,然后是一堆块组,每个块组里有 inode 位图、块位图、inode 表、数据块。这套布局是"**磁盘格式**",关机后留在盘上,下次开机 ext4 驱动按这套格式把它读回来。

与此对应,内核内存里还有一套"**内存化身**":ext4 把磁盘超级块读进 `struct ext4_sb_info`(`fs/ext4/ext4.h:1538`)、把磁盘 inode 读进 `struct ext4_inode_info`(`:1040`)——这两个"内存结构"在 VFS 的 `super_block`/`inode` 基础上**扩展**了 ext4 特有的字段(ext4 的状态、预分配信息、extent 缓存等)。读到这一节记住一条对应关系:

| 磁盘格式(落盘) | 内存化身(VFS 对象的扩展) |
|:--|:--|
| `struct ext4_super_block`(`ext4.h:1345`) | `struct ext4_sb_info`(`:1538`),包在 VFS `super_block` 里 |
| `struct ext4_inode`(`:804`) | `struct ext4_inode_info`(`:1040`),包在 VFS `inode` 里 |

VFS 那篇讲的 `super_block`/`inode` 是"通用抽象",ext4 这两个 `*_info` 是"通用抽象 + ext4 私有数据"——用 C 的面向对象方式(`container_of` 拿回私有数据)挂在一起。这是所有磁盘文件系统的通用范式:xfs 有 `xfs_sb`/`xfs_inode`,btrfs 有自己的,组织方式都是"磁盘格式 + 内存 info 结构包在 VFS 对象里"。

### 二、ext4 磁盘布局:超级块 + 块组

ext4 把整个分区划成一个个**块组(block group)**(早期叫 group),每个块组是一段连续的块,内部结构相同。一个块组里依次是:超级块的备份(只在部分块组,稀疏存储)、组描述符表、块位图(这一组里哪些块用了)、inode 位图(哪些 inode 用了)、inode 表(这一组的 inode 数组)、然后是数据块。这种"分块组 + 每组自管位图/inode"的设计,让分配器能"就近"在同一个块组里给一个文件分配 inode 和数据块,减少磁头寻道(机械盘时代的关键优化,SSD 上仍保留这套结构)。

整个分区最核心的那个**超级块**(`struct ext4_super_block`,`fs/ext4/ext4.h:1345`)在分区偏移 1024 字节处,字段我们抓几个关键的:

```c
struct ext4_super_block {
/*00*/  __le32  s_inodes_count;      /* 文件系统里 inode 总数 */
        __le32  s_blocks_count_lo;   /* 块总数 */
        ...
        __le32  s_log_block_size;    /* 块大小 = 1024 << s_log_block_size(0=1K,2=4K) */
        ...
        __le32  s_rev_level;         /* 修订级别(OLD/动态) */
        ...
        /* 魔数在固定偏移,s_magic == 0xEF53 */
        ...
};
```

挂载时 ext4 先读这个超级块,校验魔数(`0xEF53`)确认"这确实是个 ext4",拿到块大小、inode 大小(`EXT4_INODE_SIZE`,老版本 128 字节、现代默认 256)、inode 总数、块总数等全局参数,据此初始化内存的 `ext4_sb_info`。`EXT4_GOOD_OLD_INODE_SIZE = 128`(`ext4.h:2073`)是老 ext2/3 时代的 inode 大小,现代 ext4 默认 256 字节(多出来的空间存纳秒时间戳、扩展属性等)。

### 三、磁盘 inode:文件的元数据落盘

ext4 的每个文件(广义:普通文件/目录/符号链接...)在 inode 表里占一项——`struct ext4_inode`(`ext4.h:804`),它存这个文件的**元数据 + 数据块定位信息**:

```c
struct ext4_inode {
    __le16  i_mode;         /* 文件类型 + 权限 */
    __le16  i_uid;          /* owner uid(低 16 位) */
    __le32  i_size_lo;      /* 文件大小(低 32 位) */
    __le32  i_atime;        /* 访问时间 */
    __le32  i_ctime;        /* inode 改变时间 */
    __le32  i_mtime;        /* 数据修改时间 */
    __le16  i_gid;          /* group(低 16 位) */
    __le32  i_blocks_lo;    /* 已用块数(以 512 字节计,不是块大小!) */
    __le32  i_flags;        /* 标志(含"用 extent"的 EXT4_EXTENTS_FLG) */
    ...
    __le32  i_block[EXT4_N_BLOCKS];  /* ← 数据块定位(老:间接块;新:extent 根) */
    ...
};
```

注意 `i_blocks_lo` 是以 **512 字节扇区**为单位,不是块大小——这是个经典陷阱(查"文件占了多少 4K 块"时要换算)。`i_block[15]` 这 60 个字节是关键——它怎么解读,取决于 `i_flags` 里有没有 `EXT4_EXTENTS_FLG`:有就走 extent tree(下一节),没有就走老 ext2/3 的"直接块 + 间接块"映射。现代 ext4 默认建文件就开 extent,只剩极少数历史遗留文件还在用间接块。

### 四、extent tree:大文件的 B+ 树定位

老 ext2/3 用"直接块指针 + 一级/二级/三级间接块"定位文件数据块——文件越大,间接层级越深,定位一个块要读多次磁盘。ext4 用 **extent** 取代了这套:`i_block` 那 60 字节存的是一棵 extent tree 的根。一个 **extent** 描述"**一段连续的逻辑块 → 一段连续的物理块**"的映射(`struct ext4_extent`):逻辑起始块号 `ee_block`、长度 `ee_len`(最多 32768 个块)、物理起始块号 `ee_start`。一个 1GB 的连续文件,可能只需一个 extent 就描述完("逻辑块 0~262143 全在物理块 100000~362143")——比间接块的"一个指针一个块"省了海量元数据。

大文件或碎片化文件,extent 多到根放不下,就长成树:根是 `ext4_extent_header`(`eh_magic = 0xF30A` 即 EXT4_EXT_MAGIC、`eh_depth` 表示深度、`eh_entries` 表示条目数);`eh_depth = 0` 是叶子,直接存 `ext4_extent`(数据映射);`eh_depth > 0` 是索引层,存 `ext4_extent_idx`(`ei_block` 逻辑块、`ei_leaf` 指向下一层节点所在的磁盘块)。整棵树是 B+ 树的变种,查找一个逻辑块对应的物理块是 O(log n)。这套机制让 ext4 处理大文件的元数据又紧凑又快,是它相对 ext2/3 最显著的进步之一。

### 五、接入 VFS:ext4 的 ops 表

ext4 怎么接到 [VFS](./01-fs-vfs.md) 那套抽象上?靠的就是填四张 ops 表——这正是 fs-vfs 那篇讲的"vtable 分派"的具体落地。我们把 ext4 在 6.19 里填的几张表列出来:

```c
/* fs/ext4/file.c:963 —— 普通文件的 file_operations */
const struct file_operations ext4_file_operations = {
    /* .read_iter 用 page-cache 那篇讲的 generic_file_read_iter(或 ext4 包装),
       .write_iter 同理走 generic_file_write_iter,所以 ext4 文件 I/O 自动
       接上了页缓存(address_space);mmap/poll/open/release 等也都填好 */
};

/* fs/ext4/file.c:985 ext4_file_inode_operations */
/* fs/ext4/dir.c:682   ext4_dir_operations        (目录的 file_operations) */
/* fs/ext4/namei.c:4212 ext4_dir_inode_operations (目录的 inode_operations,
                                                   含 lookup/create/mkdir/unlink...) */
/* fs/ext4/symlink.c:124 ext4_symlink_inode_operations */
```

`ext4_dir_inode_operations` 里的 `lookup`/`create`/`mkdir`/`unlink` 等回调,就是 VFS 路径解析时(`cat /mnt/foo.txt` 那条旅程)会调到的——它们在 ext4 里读目录项、按名字找 inode 号、读对应 inode 块、构造 VFS 的 `inode` + `ext4_inode_info`。而 `ext4_file_operations` 的 `read_iter`/`write_iter` 直接复用 `generic_file_read_iter`/`generic_file_write_iter`,把 I/O 交给 [页缓存](./04-fs-page-cache.md)——页缓存未命中时再调 ext4 的 `address_space_operations.read_folio` 把数据从磁盘读进来。**所以 ext4 的"读一个文件"实际是:VFS 分派到 ext4_file_operations → 走通用页缓存 → 缓存未命中调 ext4 的 read_folio → 从磁盘块读 → 填充缓存页 → 返回给用户。** 一条链把整条 fs 藤串起来了。

### 六、journal(jbd2)与 mballoc:点到为止

最后两个子系统,这一篇只点到、不深入(深入留给后续 ext4 专门节点或读者自行展开):

- **journal(日志)**:ext4 通过 **jbd2**(Journaling Block Device v2)子系统实现日志。写操作先在日志区记一笔"要做什么",数据/元数据真正落盘前日志先落盘——这样掉电时若写入未完成,重启后能根据日志重做或回滚,保证文件系统一致性。jbd2 代码在 `fs/jbd2/`,ext4 在 `fs/ext4/jbd2.c` 调它。journal 模式有 `journal`(元数据日志)、`ordered`(默认,数据先落盘再记元数据日志)、`writeback`(宽松)几种,权衡性能与安全。
- **mballoc(多块分配器)**:ext4 自己的块分配器(`fs/ext4/mballoc.c`),支持一次性分配多个连续块、延迟分配(delalloc,先把写缓存起来、真正分配时一次性给连续块,减少碎片)。这是 ext4 性能的另一根支柱。

这两个子系统让 ext4 在一致性(掉电不损)和性能(分配效率)上远胜 ext2,但它们各自都是独立的大话题,本骨架只建立"它们存在、各管什么"的认知。

## 动手试试

> 这一篇的 example 偏观察,需要 QEMU 配一个 ext4 磁盘镜像。

1. 给 QEMU 配一个 ext4 磁盘镜像(`dd if=/dev/zero of=disk.img bs=1M count=...`、`mkfs.ext4 disk.img`、挂载进 Guest),`mount` 确认挂上了 ext4
2. `dumpe2fs <镜像>`(宿主机上,或装了 e2fsprogs 的 Guest)看超级块和块组——直观看到 s_inodes_count/s_blocks_count/s_log_block_size/block group 信息,对照本篇第二节
3. 在 ext4 分区上建一个文件、`ls -li` 看 inode 号;`debugfs` 的 `stat <inode号>` 看这个 inode 的 extent(B+ 树),对照本篇第四节
4. 对照 [页缓存](./04-fs-page-cache.md) 那篇:`cat <大文件>` 时 `free` 看 Cached 涨、`drop_caches` 清空后再读,体会"ext4 read_iter 走页缓存、未命中从磁盘读"
5. 进阶:读 `fs/ext4/file.c:963` 的 `ext4_file_operations` 定义,逐个方法对照 [VFS](./01-fs-vfs.md) 的 `file_operations`——确认 ext4 怎么填这张表(read_iter/write_iter 用 generic、或 ext4 自己包装)
6. 思考题:同一个 `cat foo.txt`,ext4 和 procfs 的"读"在内核里走的是同一条 VFS 分派链,区别在哪一步分叉?(提示:`f_op->read_iter` 指向不同的实现——ext4 走页缓存+磁盘、procfs 走内核现算)

## 延伸阅读

- kernel.org:[ext4 Data Structures and Algorithms](https://docs.kernel.org/filesystems/ext4/) 是 ext4 磁盘格式的官方文档,详尽到每个字段(本篇的超级块/inode/extent 定义都能在这里找到完整版本);`Documentation/filesystems/ext4/` 目录下还有多个专题(special_inodes/blocks/inline_data...)。
- 源码(本仓库 `third_party/linux/`,6.19.9):磁盘格式在 `fs/ext4/ext4.h`——`struct ext4_super_block :1345`、`struct ext4_inode :804`、`struct ext4_inode_info :1040`、`struct ext4_sb_info :1538`,extent 相关结构(`ext4_extent`/`ext4_extent_idx`/`ext4_extent_header` 及 `EXT4_EXT_MAGIC`)也在同文件;VFS 接入点在 `fs/ext4/file.c:963`(ext4_file_operations)、`fs/ext4/namei.c:4212`(目录 inode_operations)等;块分配 `fs/ext4/mballoc.c`;日志在 `fs/jbd2/` 与 `fs/ext4/jbd2.c`。
- 关联本站:本篇把 [01 VFS 框架](./01-fs-vfs.md) 那套 ops 表填上了 ext4 的具体实现,把 [04 页缓存](./04-fs-page-cache.md) 的 `read_folio` 落到了"从 ext4 磁盘块读";`ext4_inode_info`/`ext4_sb_info` 这种"内存 info 结构包在 VFS 对象里"的范式,和 [chardev](../../drivers/01-drv-chardev.md) 里 cdev 包自定义数据是同一种 C 面向对象手法。
- 经典纸面参考:《Linux 内核源码情景分析》《Understanding the Linux Kernel》讲 ext2/3 的磁盘格式(ext4 的基础),对照 ext4 文档的 extent/journal 增量读。
