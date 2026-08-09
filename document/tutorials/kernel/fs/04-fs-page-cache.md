---
title: "页缓存:为什么第二次 cat 比第一次快——VFS 与 mm 的桥"
slug: fs-page-cache
prerequisites:
  - fs-vfs
  - virtual-address-space
next:
  - fs-ext4
difficulty: advanced
tags: [filesystem, page-cache, address_space, folio, writeback, mm, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/admin-guide/mm/concepts.html
  - source: third_party/linux（6.19）include/linux/fs.h、mm/filemap.c、mm/page-writeback.c
maturity: drafting
related:
  - /tutorials/kernel/fs/01-fs-vfs
  - /tutorials/foundations/11-virtual-address-space
  - /tutorials/kernel/mm/01-mm-buddy
---

> 🔨 **整理中** · 这一篇讲**页缓存(page cache)**——磁盘文件系统(ext4/xfs/btrfs...)能跑得动的根本性能基础设施,也是 VFS 和内存管理子系统的交汇点。素材以 6.19 源码为权威、kernel.org 的 [MM 概念文档](https://docs.kernel.org/admin-guide/mm/concepts.html) 做框架。重要校订:6.19 已全面 **folio 化**(原来基于 `page` 的 API 大面积换成 `folio`),老资料的 `readpage`/`releasepage` 在 6.19 是 `read_folio`/`release_folio`;`i_pages` 也从老的 radix tree 换成了 `xarray`。动手部分在 QEMU 亲手验过之前标"待亲测"。

## 做什么

第一次 `cat /etc/hosts` 你可能会感觉到一点延迟,第二次 `cat` 几乎是瞬间——这中间发生了什么?答案就是**页缓存**:第一次读时,内核从磁盘把 `hosts` 的内容读进内存(按页为单位),顺手留在了那里;第二次读时内核先在内存里找,命中就直接拷给你,根本不碰磁盘。磁盘比内存慢几个数量级,所以"命中就别碰磁盘"这一招,就是 Unix/Linux 文件 I/O 性能的地基。

但页缓存不是孤立存在于"读"路径里的——它是横跨 VFS 和 mm 的一个完整子系统:每个 inode 通过一个 `address_space` 把"自己的内容"和"缓存它的那些页"绑起来,读靠它、写靠它(写先写缓存页、标记脏、延迟写回)、`mmap` 也靠它(把文件页映射进进程地址空间)。这一篇我们就把页缓存拆透:`address_space` 怎么组织页、`address_space_operations` 里那些回调怎么分派、一次 read 和一次 write 各自怎么走缓存、以及 6.19 的 folio 改造动了哪些 API。读懂它,你就理解了为什么"所有磁盘文件系统共用一套页缓存"——它们填好 `address_space_operations` 几个回调就接上了。

## 要了解什么

### 一、页缓存是什么:文件内容的内存化身

页缓存的核心思想一句话:**把"文件的内容"和"物理内存页"对应起来,让对文件的读写尽量落在内存页上**。每个被缓存住的文件页(在 6.19 里叫 **folio**,见下一节的版本校订),都挂在"它所属的那个 inode"名下;多个进程读同一个文件,看到的是同一批缓存页(共享,不重复占内存);进程退出、文件关闭,缓存页也不会立刻释放——只要内存够、只要还在被频繁访问,它就留着给下个使用者命中。

这套缓存的容量是"动态吃满可用内存":空闲内存多就多缓存,内存紧张时由回收机制(下一篇 mm 藤的页面回收会展开)把不常用的缓存页踢出去。所以你会发现 Linux 的 `free` 命令里 `buff/cache` 那一栏往往占掉大半内存——这不是"内存泄漏",这是内核"既然闲着也是闲着,不如拿来缓存文件"的策略,有内存压力时会自动让出来。

### 二、`address_space`:页缓存的组织单元

页缓存怎么知道"哪个文件缓存了哪些页"?靠的就是上一篇 [VFS](./01-fs-vfs.md) 第六节埋的那个伏笔——**`struct address_space`**(`include/linux/fs.h:470`)。每个 inode 里有一个 `i_data`(就是 `address_space`),`i_mapping` 指向它。`address_space` 是"一个 inode 对应的页缓存"的容器,关键字段:

```c
struct address_space {
    struct inode                  *host;          /* 拥有这批缓存页的 inode */
    struct xarray                  i_pages;       /* 缓存页树(按文件偏移索引) */
    ...
    pgoff_t                        writeback_index;
    ...
};
/* 外加 nrpages(总缓存页数)等统计字段 */
```

`host` 指回所属 inode(告诉这批页"你属于哪个文件");**`i_pages` 是核心**——它是一棵按"文件内偏移(页号)"索引的树,每个节点指向一个缓存了该偏移内容的 folio。读某个偏移时,内核拿偏移算出页号、在 `i_pages` 里查:查到就是命中,查不到就触发"从磁盘读进来并插入树"。6.19 的 `i_pages` 类型是 `struct xarray`——这是老的 **radix tree** 的现代继承者(改了实现、接口更统一),老资料里你看到的 `radix_tree_root` 在 6.x 早就换成了 xarray。

> ⚠️ **校订:6.19 全面 folio 化**
> 老资料(以及 LDD3)讲页缓存时,基本单位是 `struct page`(单页)。但从 5.16 起,内核启动了一场大规模的 **folio** 改造:`folio` 是"一个或多个连续页的组合"(对多数配置还是一个页,但类型上区分于"任意 page"),目的是消除"page 到底是不是个独立 folio 的头"这种长期歧义。到 6.19,页缓存 API 已经大面积从 `page` 版本迁到 `folio` 版本——`readpage` → `read_folio`、`releasepage` → `release_folio`、`invalidatepage` → `invalidate_folio`、`page_ops` → `folio_ops`,以及 `filemap_get_folio`、`read_cache_folio` 这些入口。读 6.19 源码时看到满屏的 `folio`,就是这场改造的结果;拿老资料的 `page` 例子去对,会对不上。这是这一篇最重要的版本增量。

### 三、`address_space_operations`:具体 fs 填的回调

`address_space` 自己只管"装页",具体"怎么从磁盘把一页读进来""怎么把脏页写回磁盘"这些**和底层文件系统相关**的活,由它挂着的 **`address_space_operations`**(`include/linux/fs.h:403`)提供——这又是一张 vtable,磁盘文件系统(ext4 等)填好它就接入了通用页缓存:

```c
struct address_space_operations {
    int     (*read_folio)(struct file *, struct folio *);     /* 读一页进缓存 */
    ...
    int     (*writepage)(struct page *, struct writeback_control *);  /* 写回一页 */
    int     (*write_begin)(const struct kiocb *, struct address_space *,
                           loff_t, unsigned, struct folio **, void **);
    int     (*write_end)(const struct kiocb *, struct address_space *,
                         loff_t, unsigned, unsigned, struct folio *, void *);
    ...
    void    (*invalidate_folio)(struct folio *, size_t offset, size_t len);
    bool    (*release_folio)(struct folio *, gfp_t);
    ssize_t (*direct_IO)(struct kiocb *, struct iov_iter *);  /* 绕过缓存的直接 I/O */
    int     (*migrate_folio)(struct address_space *, struct folio *dst,
                             struct folio *src, enum migrate_mode);
    ...
};
```

`read_folio` 是读路径的核心(文件系统怎么从磁盘读一页);`writepage`/`write_begin`/`write_end` 是写路径(写时怎么准备页、写完后怎么标记);`direct_IO` 给"直接 I/O"留口子(绕过页缓存,数据库这类自己管缓存的程序用);`invalidate_folio`/`release_folio`/`migrate_folio` 管生命周期和内存管理(CMA/内存热插拔等场景要迁移页)。这张表的精妙和 [VFS](./01-fs-vfs.md) 的其它 ops 一样——**通用页缓存代码只对 vtable 发问,各磁盘文件系统填各自的实现**,于是 ext4/xfs/btrfs 共用同一套缓存框架,各自只写"怎么从自己的磁盘格式读/写一页"。

### 四、一次 `read` 的旅程:`generic_file_read_iter` + 命中判定

绝大多数磁盘文件系统的 `file_operations.read_iter` 不自己写,直接用现成的 **`generic_file_read_iter`**(`mm/filemap.c:2956`,EXPORT 给所有 fs 共用)。一个 `read(fd, buf, n)` 走进它后,大致逻辑是:按用户要读的范围,逐页(逐 folio)在 `address_space->i_pages` 里查——

- **命中**(`filemap_get_folio` 找到了):直接把这一页的内容拷到用户 buffer,继续下一页。
- **未命中**:调 `address_space_operations.read_folio` 让文件系统从磁盘把这一页读进来、插入 `i_pages`,然后再拷给用户。同时内核往往还会**预读**(readahead)——不光读你要的这一页,还把后面一批页一起读进来,因为"既然你在顺序读,后面这些大概率马上也要"。

整个过程的本质就是"在 `address_space` 这棵缓存树里查、查不到就让底层 fs 填进来、查到了就直接用"。第二次 `cat /etc/hosts` 之所以瞬间,就是因为第一次读进来的页还在 `i_pages` 树里,第二次全是命中。

### 五、写路径:写缓存 + 标脏 + 延迟写回

写比读多一道弯,因为不能每写一个字节就刷磁盘(太慢)。`generic_file_write_iter`(`mm/filemap.c:4453`)的套路是:

1. **`write_begin`**:定位/准备要写的那一页(可能要先把它从磁盘读进来——"部分写"时需要先把整页内容读出来、再覆盖其中一段)。
2. **拷贝**:把用户 buffer 的数据拷进这一页(在内存里完成,极快)。
3. **`write_end`**:标记这一页为**脏**(dirty)——表示"我的内容和磁盘不一致了,得找时间写回去"。
4. **延迟写回**:脏页并不立即写磁盘,而是挂在脏页列表上,由内核的**写回线程**(flusher/writeback 线程)在合适时机——内存脏页比例超阈值、定时、或 `sync` 被调用——批量调 `writepage`/`do_writepages`(`mm/page-writeback.c:2587`)把它写回磁盘,然后清掉脏标记。

这种"写先落缓存、延迟批量写回"的策略,把大量小写合并成少量大写、把同步慢操作变成异步,是文件 I/O 性能的另一根支柱。代价是:突然掉电会丢掉"已在缓存但还没写回"的数据(数据库等不能容忍这个的程序,会走 `direct_IO` 或 `O_SYNC` 强制同步写)。

### 六、直接 I/O vs 缓冲 I/O:`direct_IO` 绕过页缓存

`address_space_operations.direct_IO` 是个"逃生口":用户态打开文件时加 `O_DIRECT`,或数据库这类自己管缓存的程序,可以让 `read`/`write` **绕过页缓存**直接在用户 buffer 和磁盘之间搬数据。走这条路就不经过前面那套命中/标脏/写回,性能特性完全不同(适合"一次性大批量、不重用"的 I/O;小而频繁的 I/O 走直接 I/O 反而更慢,因为少了预读和缓存合并)。常规文件读写默认是缓冲 I/O(走页缓存),直接 I/O 是需要时才显式选。

### 七、`mmap` 与页缓存:`filemap_fault` 接到缺页

最后把 `mmap` 也接上。用户态 `mmap` 一个文件后访问映射区,触发**缺页异常**,内核走 `filemap_fault`(`mm/filemap.c:3512`)——它的逻辑和 `read` 的"查 `i_pages`、命中就用、未命中就 `read_folio`"几乎一样,只不过这次不是拷到用户 buffer,而是把那一页**映射进进程的页表**(关联 [虚拟地址空间](../../foundations/11-virtual-address-space.md) 里讲的 VAS)。所以 `mmap` 文件访问、`read` 文件、甚至内核自己读 inode,共享的是**同一批页缓存页**——页缓存是"文件内容"的唯一内存化身,不管从哪条路进来都复用它。这就是 VFS↔mm 这座桥的两端:`address_space` 一头挂 inode(VFS),一头挂物理页(mm)。

## 动手试试

> 这一篇 example 偏观察,用 `free`、`/proc/meminfo`、`vmsat` 把页缓存看活。

1. QEMU 里 `free -h`(或 `cat /proc/meminfo`)看 `buff/cache`/`Cached` 一栏,先记一个基线值
2. `cat /etc/hosts > /dev/null`(第一次,触发从 rootfs 读),再看 `Cached` 是否涨(初始 initramfs 是 cpio,本身在内存,但观察机制类似);再 `cat /etc/hosts > /dev/null`(第二次),对照本篇第四节确认"命中"
3. 如果 QEMU 配了磁盘镜像(ext4),`mount` 一个 ext4 分区,`dd if=.../bigfile of=/dev/null bs=1M`(第一次,触发读+缓存)、`echo 3 > /proc/sys/vm/drop_caches`(强制清页缓存)、再 `dd` 一次,对比两次耗时——直观感受页缓存的效果
4. `cat /proc/meminfo | grep -E "Cached|Dirty|Writeback"` 看缓存页数、脏页数、正在写回页数;`sync` 后再看 `Dirty` 是否归零(对应本篇第五节的延迟写回)
5. 进阶:写一个模块打印某 inode 的 `address_space->nrpages`(缓存页数),对比 `cat` 它前后变化
6. 思考题:数据库程序为什么倾向用 `O_DIRECT`(直接 I/O)而不是默认的缓冲 I/O?(提示:它自己管缓存,走内核页缓存等于双重缓存 + 额外的拷贝开销)

## 延伸阅读

- kernel.org:[Memory Management Concepts](https://docs.kernel.org/admin-guide/mm/concepts.html) 讲页缓存、folio 在整个 mm 体系里的位置;`Documentation/core-api/mm-api.rst`、`Documentation/filesystems/locking.rst`(页缓存的锁约定)。
- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/fs.h:470 struct address_space`、`:403 struct address_space_operations`(`read_folio`/`writepage`/`write_begin`/`write_end`/`direct_IO`/`invalidate_folio`/`release_folio`/`migrate_folio`);页缓存主代码在 `mm/filemap.c`——`generic_file_read_iter:2956`、`generic_file_write_iter:4453`、`filemap_fault:3512`、`read_cache_folio:4130`;写回在 `mm/page-writeback.c`(`do_writepages:2587`);folio 基础设施在 `include/linux/folio.h`、`mm/folio-compat.c`(老 page API 的兼容包装,能看出迁移痕迹)。
- 关联本站:本篇是 [01 VFS 框架](./01-fs-vfs.md) 第六节埋的 `address_space` 的展开;缓存页的物理底座是 [伙伴系统](../mm/01-mm-buddy.md)(页怎么来的);`mmap` 把缓存页映射进进程地址空间,关联 [虚拟地址空间](../../foundations/11-virtual-address-space.md);内存紧张时缓存页怎么被回收,属于页面回收(后续 mm 藤节点)。
- 经典纸面参考:LDD3 第 16 章讲页缓存,但全是 `page` 时代的 API,6.19 已 folio 化——结合本篇第二节校订读。
