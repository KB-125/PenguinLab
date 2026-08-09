---
title: "VFS:一个 open() 怎么变成 ext4 或 procfs 的具体操作"
slug: fs-vfs
prerequisites:
  - virtual-address-space
  - process-thread-kernel
next:
  - fs-procfs
difficulty: intermediate
tags: [filesystem, vfs, inode, dentry, super_block, file_operations, dcache, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/filesystems/vfs.html
  - source: third_party/linux（6.19）include/linux/fs.h、include/linux/dcache.h、fs/*.c
maturity: drafting
related:
  - /tutorials/foundations/11-virtual-address-space
---

> 🔨 **整理中** · 这一篇是 fs 藤的**地基**——后面四篇(procfs/sysfs/page-cache/ext4)都挂在 VFS 这套抽象上。素材以 6.19 源码为权威、kernel.org 的 [VFS 文档](https://docs.kernel.org/filesystems/vfs.html)(Richard Gooch 原作)做叙事框架,本藤无读书笔记、靠现查原料。所有结构体行号对照 `third_party/linux/` 校订;`/proc/mounts`、`ls -li`、debugfs 看 dcache 这些观察手段在 QEMU 亲手验过之前标"待亲测"。

## 做什么

我们每天都在敲 `open("/etc/hosts")`、`cat /proc/cpuinfo`、`echo > /sys/...`,好像"文件"是个天经地义的东西。可稍微一想就会冒出一堆问题:`/etc/hosts` 躺在 ext4 磁盘分区上,`/proc/cpuinfo` 是内核现造的、根本没落盘,`/sys/class/...` 又是另一套——它们仨底层实现完全不同,为什么用户态用同一套 `open/read/write/close` 就能操作?一个 `open()` 进了内核,内核怎么知道该调 ext4 的代码、还是 procfs 的代码、还是 sysfs 的代码?

答案就是 **VFS(Virtual File System)**——也叫 Virtual Filesystem Switch,"虚拟文件系统切换器"。它是内核里的一层软件:向上给用户态提供**统一**的文件系统接口(那几个系统调用),向下用一套**抽象对象 + 回调表**包容各种不同的文件系统实现,让它们能共存。这一篇我们就把这套抽象拆透:VFS 用哪几个核心对象代表"一个文件系统、一个文件、一次打开",又用哪几张"操作表"把统一的系统调用**分派**到具体文件系统的代码去。读懂这一篇,后面读 procfs、sysfs、ext4 的源码,你都知道它们各自的实现是在填 VFS 哪几个格子。

## 要了解什么

### 一、VFS 是什么:用户态的统一接口,内核态的抽象层

先搬 kernel.org 那篇 VFS 文档开篇的定义:**VFS 是内核里的一层软件,它把文件系统接口提供给用户态程序;同时在内核内部提供一层抽象,让不同的文件系统实现能共存。** `open(2)`、`stat(2)`、`read(2)`、`write(2)`、`chmod(2)` 这些系统调用都从进程上下文进入 VFS,VFS 再往下分派。

这句话的两个方向都要记住:**向上统一**(不管底下是 ext4 还是 procfs,用户态都是 `open/read/write` 这一套)、**向下包容**(每种文件系统各写各的实现,VFS 用统一的抽象对象去对接它们)。VFS 之所以叫 "Switch"(切换器),正是因为它在中间做这个"按挂载点把请求切到对应文件系统"的活——和之前讲过的调度类(`for_each_class` 把请求切到对应调度类)是同一种"用一张表分派"的思路,只不过一个切 CPU 调度策略、一个切文件系统操作。

### 二、四大核心对象:`super_block` / `inode` / `dentry` / `file`

VFS 用四个核心结构体代表文件系统里的东西。先把它们各自"代表什么、存在哪、谁拥有"分清楚,这是 VFS 全部逻辑的地基。

**`super_block`——一个"已经挂载的文件系统实例"的化身**(定义在 `include/linux/fs.h`)。你每挂载一个文件系统(`mount -t ext4 /dev/sda1 /mnt`),内核就生成一个 `super_block`,它记录这个文件系统实例的全局信息:块大小、魔数、挂载选项、它是什么文件系统类型、以及最重要的——一组 `super_operations` 回调(见第四节)。它代表的是"**这一整个文件系统树**",不是单个文件。

**`inode`——一个"文件系统对象"**(定义在 `include/linux/fs.h:765`)。注意这里的"文件"是广义的——普通文件、目录、符号链接、FIFO、设备节点,在内核眼里都是一个 `inode`。它存这个对象的**稳定属性**:大小、权限、时间戳、inode 号、数据块的位置。磁盘文件系统(ext4)的 inode 落在磁盘上、用时读进内存改、再写回;伪文件系统(procfs/sysfs)的 inode 只活在内存、现造现用。**一个 inode 可以被多个 `dentry` 指向**——这就是硬链接的物理实现:同一个 inode,多个名字。它的关键字段(`include/linux/fs.h:765` 起)我们抓出来对一下:

```c
struct inode {
    ...
    const struct inode_operations  *i_op;       /* 这个 inode 的"目录/属性操作"表 */
    struct super_block             *i_sb;        /* 所属的超级块(哪个文件系统实例) */
    struct address_space           *i_mapping;   /* 页缓存地址空间(关联 mm,见第六节) */
    ...
    const struct file_operations  *i_fop;        /* 打开它时默认用的"文件操作"表 */
    struct address_space           i_data;       /* 这个 inode 自己的地址空间 */
    ...
};
```

`i_op`/`i_fop` 这两个回调指针是 VFS 分派的关键,下一节细说;`i_sb` 把它挂回所属的文件系统实例;`i_mapping`/`i_data` 把它和页缓存绑在一起。

**`dentry`——一个"目录项"(directory entry)**(定义在 `include/linux/dcache.h:92`)。它代表的是"**路径里的一个名字分量**",把名字和 inode 连起来:比如 `/etc/hosts` 解析时会产生 `etc` 和 `hosts` 两个 dentry,各自指向对应的 inode。**dentry 只在内存、不落盘**——它是内核为了加速路径解析而造的缓存对象,代表"一次路径绑定的临时结果"。所有 dentry 组成 **dcache**(dentry cache),下一节展开。

**`file`——一个"打开的文件实例"**(定义在 `include/linux/fs.h:1258`)。注意它和 inode 的区别:`inode` 是"文件本身"(全局唯一,代表那个对象),`file` 是"**某次打开**"(进程级,每 `open` 一次就新建一个,存这次打开的**动态状态**:当前读写位置 `f_pos`、打开模式 `f_mode`、用的是哪个 `file_operations`)。同一个文件被两个进程打开,就有一个 inode、两个 file。它的关键字段:

```c
struct file {
    ...
    const struct file_operations  *f_op;        /* 这次打开用的"文件操作"表 */
    struct address_space          *f_mapping;    /* 页缓存(通常 = inode 的 i_mapping) */
    struct inode                  *f_inode;      /* 指回底层那个唯一的 inode */
    ...
    loff_t                         f_pos;        /* 当前读写偏移(每次打开各管各的) */
    ...
};
```

记住这条区分,后面就不会绕:`inode`=文件(稳定、唯一),`file`=打开实例(动态、每 open 一个);`dentry`=路径分量(缓存、指 inode);`super_block`=整个文件系统实例(挂载级别)。

### 三、dcache:路径解析的加速器

`open("/etc/hosts")` 进了内核,第一件事是**路径解析**——把字符串 `/etc/hosts` 翻译成目标 dentry(进而拿到 inode)。如果每次都从根目录一层层去磁盘查,慢得不可接受。所以内核维护了 **dcache(dentry cache)**:所有最近用过的 dentry 组成一张巨大的哈希树,绝大多数路径解析能在 dcache 里直接命中、根本不碰磁盘。

dcache 还有个更深的含义——kernel.org 文档原话:dentry 缓存是"你整个文件空间的一个视图"。多数机器没法把全部 dentry 塞进内存,所以 dcache 里有"缺口":命中就快拿,没命中时 VFS 沿路径逐级**调父目录 inode 的 `lookup()` 方法**造出新的 dentry、再读入对应 inode。也就是说,**路径解析的本质是"dcache 命中 → 直接拿;未命中 → 调具体文件系统的 `lookup` 把缺口补上"**。这就是为什么"第一次 `ls` 一个大目录慢、第二次快"——dentry 被造出来进了 dcache,之后就是内存命中。

> 💡 **dentry 只活在内存**
> 一个容易混淆的点:dentry **从来不会落盘**。磁盘上"目录项"的物理表示(ext4 的目录项块)和内存里的 `struct dentry` 是两回事——后者只是前者在内存里的缓存化身,加上一些内核管理用的字段(`d_parent`、`d_subdirs`、引用计数等)。关机断电,dcache 全部消失,重启后按需重建。这一点和 inode 不同(inode 在磁盘 fs 里是落盘的)。

### 四、四张 operations 表:VFS 分派的 vtable

讲完四大对象,现在讲 VFS 真正的精髓——**分派**。四大对象各自身上挂着一组**操作表**(`*_operations`),本质都是函数指针表(vtable)。VFS 的系统调用代码不直接知道 ext4/procfs,它只对这些 vtable 里的回调发问:"请帮我打开这个文件"、"请帮我读这个 inode 的属性",具体文件系统在自己的 vtable 里填好实现,VFS 调过去就完成分派。四张表:

**`file_operations`**(`include/linux/fs.h:1918`)——挂在 `file.f_op` 和 `inode.i_fop` 上,管"**已打开文件**能做什么":`read`/`write`/`read_iter`/`write_iter`、`open`、`release`(关闭时)、`mmap`、`poll`、`iterate_shared`(读目录)、`llseek`。这是用户态 `read/write` 直接命中的那张表,绝大多数方法签名你能在 `fs.h:1918` 起的定义里看到。

**`inode_operations`**(`include/linux/fs.h:1988`)——挂在 `inode.i_op` 上,管"**对 inode 本身**的操作",主要是目录层的活:`lookup`(路径解析时找子项)、`create`(创建文件)、`link`/`unlink`(硬链接/删除)、`mkdir`/`rmdir`/`rename`、`permission`(权限检查)、`getattr`/`setattr`(取/改属性)。注意 `lookup` 在这里——上一节说的"未命中 dcache 时调 `lookup` 补缺口",调的就是父目录 inode 的 `i_op->lookup`。

**`super_operations`**(`include/linux/fs.h`)——挂在 `super_block.s_op` 上,管"**这个文件系统实例**怎么管理自己的 inode 和超级块":`alloc_inode`/`destroy_inode`/`free_inode`(分配/释放 inode)、`evict_inode`(inode 被踢出时,磁盘 fs 要把脏数据写回、伪 fs 只是释放内存)、`write_inode`(把 inode 写回磁盘)、`put_super`(卸载时清理)、`statfs`(文件系统统计)、`drop_inode`(引用计数归零时的处理)。

**`dentry_operations`**(`include/linux/dcache.h:151`)——挂在 `dentry.d_op` 上,管"**这个目录项**的个性化行为":`d_revalidate`(路径解析时要不要重新校验,网络 fs 常用)、`d_hash`/`d_compare`(自定义哈希和比较,大小写不敏感的文件系统会用)、`d_delete`/`d_release`(生命周期)。多数文件系统不碰它,用默认行为。

> 💡 **和调度类的类比**
> VFS 这套"对象 + vtable"的设计,和 [调度器框架](../sched/01-sched-overview.md) 里 `sched_class` 那张函数指针表是同一种思路:核心代码只对抽象的 vtable 发问,具体实现在各模块自己填的回调里。只不过调度器的"分派轴"是**调度类优先级链**(谁先应答),VFS 的"分派轴"是**挂载点**(路径前缀决定走哪个文件系统)。理解了这种"用函数指针表解耦"的范式,内核里一大半子系统(VFS、调度、crypto、网络协议栈)的骨架你都眼熟。

### 五、一次 `open()` 的旅程:把分派走一遍

把前四节缝起来,跟着一个 `open("/etc/hosts", O_RDONLY)` 走一遍,你就彻底理解 VFS 在做什么:

1. **系统调用进入 VFS**:用户态 `open()` 触发系统调用,进入内核 VFS 层(进程上下文)。
2. **路径解析**:VFS 从当前进程的根/工作目录 dentry 出发,沿 `/etc/hosts` 逐级解析。每一级先查 **dcache**——命中就直接拿到下一级 dentry;未命中就调**父目录 inode 的 `i_op->lookup()`**,让具体文件系统(ext4)去自己的目录项块里找、造一个新的 dentry 返回。一路解析到 `hosts` 这个 dentry,通过它拿到目标 **inode**。
3. **分配 `file` 结构**:VFS 分配一个新的 `struct file`,把 `file.f_inode` 指向刚拿到的 inode,`file.f_op` 设为 `inode->i_fop`(inode 默认的文件操作表——ext4 文件就指向 ext4 的 `file_operations`)。
4. **调用具体 fs 的 `open`**:VFS 调 `file.f_op->open(inode, file)`,如果具体文件系统(ext4_file_operations)实现了 `open` 回调,它就跑自己的打开逻辑;很多文件系统用通用的 `generic_file_open`,啥也不干。
5. **分配 fd 并返回**:VFS 把这个 `file` 挂到当前进程的打开文件表里,分配一个文件描述符(fd),返回给用户态。

之后用户态 `read(fd, buf, n)` 进来,VFS 拿 fd 找到那个 `file` 结构,直接调 `file.f_op->read`(或 `read_iter`)——这一步就分派到了 ext4 的读实现。**整个分派链条的"路由器"就是 `f_op`/`i_op`/`s_op` 这几个函数指针**:用户态看到的统一 `open/read/write`,内核里靠它们切到具体文件系统的代码。

### 六、`address_space`:VFS 和页缓存的接口

四大对象之外,VFS 还有一个横跨"文件系统"和"内存管理"的关键结构——**`address_space`**(`include/linux/fs.h:470`),它和它 的 `address_space_operations`(`:403`)是 VFS 与**页缓存(page cache)**的接口。我们刚才看到 `inode.i_data` 和 `inode.i_mapping` 都是指向 `address_space` 的——它的核心作用是:**把"这个文件(或这个 inode)的内容"和"缓存它的那些物理页"绑定起来**,让 `read`/`write`/`mmap` 能走页缓存这条路(读时先查页缓存命中没、没命中再从磁盘读进来;写时先写页缓存、标记脏、择机写回)。

`address_space_operations` 里的核心方法是 `read_folio`/`readpage`(读)、`writepage`/`writepages`(写回)、`write_begin`/`write_end`(写入)、`migrate_folio`(页迁移)、`direct_IO`(绕过缓存直接 I/O)。这套机制为什么重要?因为它是**所有磁盘文件系统共用**的页缓存基础设施——ext4、xfs、btrfs 不用各自重写一遍"页缓存",它们填好 `address_space_operations` 几个回调,就接上了 VFS 提供的通用页缓存。这一块我们会在 [fs-page-cache](./04-fs-page-cache.md) 单独展开,这里先记住"`address_space` 是 VFS 与 mm 的桥"。

### 七、现代 mount:`fs_context`(6.x 新 mount API)

最后补一个容易踩到的版本差异。老资料讲 VFS mount 时,经常引用一套 `mount_sb`/`fill_super` 的旧 API。但**自 5.1 起,Linux 引入了新的 mount API**,到 6.19 已经是主流:现在挂载一个文件系统,走的是 `struct fs_context`(`include/linux/fs_context.h:90`)这套,文件系统类型提供 `init_fs_context` 回调,在里头设置"怎么获取超级块"——块设备文件系统用 `get_tree_bdev()`(`fs_context.h:172`)、无块设备的伪文件系统(procfs/sysfs)用 `get_tree_nodev()`(`:153`)。

这套新 API 的好处是把"挂载配置"和"超级块生成"解耦了,支持挂载参数的重新配置(remount 变得更干净)、更好的命名空间集成。读 6.19 的文件系统源码时,看到 `get_tree_bdev`/`get_tree_nodev` 就是新 API 的标志——别拿老资料的 `mount_sb` 去对,会对不上。

## 动手试试

> 这一篇的 example 偏观察,用 `/proc`、`ls`、debugfs 把抽象对象看成具体数据。

1. `cat /proc/mounts` 列出所有挂载点——每行一个**已挂载文件系统实例**,对应 VFS 里一个 `super_block`;注意每行的文件系统类型(ext4/proc/sysfs/tmpfs...)和挂载选项,体会"一个 super_block = 一个 fs 实例"
2. `ls -li /etc/hosts /etc/hosts`(或任意两个硬链接文件)看 inode 号——硬链接的两个名字 inode 号相同,验证"一个 inode 多个 dentry"
3. 进阶(需 CONFIG_DEBUG_FS):`ls /sys/kernel/debug/` 看 dcache 统计,或用 `cat /proc/sys/fs/dentry-state` 看 dcache 里 dentry 的总数/未用数——直观感受 dcache 规模
4. 写一个极简的"伪文件系统"模块骨架(用 `get_tree_nodev` + 填一个 `super_operations` + `inode_operations` + `file_operations`,在 `/proc` 或独立挂载点暴露一个只读文件)——把本篇四张 ops 表亲手填一遍,体会"填格子 = 实现一个文件系统"
5. 思考题:`cat /proc/cpuinfo` 和 `cat /etc/hosts` 走的是同一套 `read()`,但前者不碰磁盘、后者要(首次)读 ext4。结合本篇第四节,这个"分派到不同实现"发生在哪一步?(提示:`f_op->read` 指向不同的回调)

## 延伸阅读

- kernel.org:[Overview of the Linux Virtual File System](https://docs.kernel.org/filesystems/vfs.html) 是 VFS 的官方权威文档(Richard Gooch 原作),逐个讲四对象、四 ops 表的每个方法签名与语义——本篇的框架就来自它,深入到单个回调时必查。
- 源码(本仓库 `third_party/linux/`,6.19.9):四大对象在 `include/linux/fs.h`——`struct inode :765`、`struct file :1258`、`struct file_operations :1918`、`struct inode_operations :1988`、`struct address_space :470`、`struct address_space_operations :403`,`struct super_block`/`struct super_operations` 也在同文件;dentry 在 `include/linux/dcache.h:92`/`:151`;新 mount API 在 `include/linux/fs_context.h:90`(及 `get_tree_bdev :172`/`get_tree_nodev :153`);VFS 的系统调用分派主代码在 `fs/open.c`、`fs/read_write.c`、`fs/namei.c`(路径解析)。
- 关联本站:本篇的 VFS 抽象与 [调度器框架](../sched/01-sched-overview.md) 的"对象+vtable"是同一设计范式;`address_space` 桥到的页缓存与 mm 子系统,底座在 [虚拟地址空间](../../foundations/11-virtual-address-space.md);fs 藤后续:procfs/sysfs 是 VFS 的"伪文件系统"应用,ext4 是"磁盘文件系统"应用,page-cache 专讲 `address_space`。
- 经典纸面参考:LDD3(Linux Device Drivers 3)第 14 章《块设备》之前的"文件系统"相关章节讲 VFS,但部分 API 是 2.6 时代的,结合 6.19 源码和新 mount API 看。
