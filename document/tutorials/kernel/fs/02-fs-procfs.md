---
title: "procfs:给内核开个 /proc 窗口,现造文件给用户态读"
slug: fs-procfs
prerequisites:
  - fs-vfs
next:
  - fs-sysfs
difficulty: intermediate
tags: [filesystem, procfs, pseudo-fs, proc_ops, proc_dir_entry, seq_file, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/filesystems/procfs.html
  - source: third_party/linux（6.19）fs/proc/、include/linux/proc_fs.h
maturity: drafting
related:
  - /tutorials/kernel/fs/01-fs-vfs
  - /tutorials/foundations/09-kernel-module-params
---

> 🔨 **整理中** · 这一篇把上一篇的 VFS 框架落到一个最简单的实例上——**procfs**(伪文件系统,文件全是内核现造、不落盘)。素材以 6.19 源码为权威、kernel.org 的 [procfs 文档](https://docs.kernel.org/filesystems/procfs.html) 做框架,本藤无读书笔记、靠现查原料。结构体行号对照 `third_party/linux/`;动手部分(写一个 `/proc/<name>` 项)在 QEMU 亲手跑过之前标"待亲测"。重要校订:6.19(自 5.6 起)procfs 用 `struct proc_ops` 而非直接传 `file_operations`,老资料的写法已过时。

## 做什么

上一篇讲 VFS 时反复说"伪文件系统的 inode 只活在内存、现造现用"——procfs 就是这句话最典型的例子。`/proc/cpuinfo`、`/proc/meminfo`、`/proc/mounts`,还有每个进程的 `/proc/[pid]/status` 这些,统统不是磁盘上的文件,而是**内核在用户态来读的那一刻现算出来的字符串**。这种设计让内核能以一种特别顺手的姿势把内部状态暴露给用户态:不用发明新的通信接口,用户用 `cat`、`grep` 就能看,程序用 `open/read` 就能取。

这一篇我们就拆开 procfs:它在 VFS 框架里是怎么挂上去的、用什么结构体代表"一个 `/proc` 项"、又怎么让内核模块自己往 `/proc` 里加文件。procfs 是 fs 藤里最简单的"应用题"——因为它不碰磁盘、不碰页缓存,纯粹是"VFS 四对象 + ops 表"的最小填法,读懂它你就掌握了"实现一个伪文件系统"的全部套路,后面写 sysfs、写自己的虚拟 fs 都是这个套路的变体。

## 要了解什么

### 一、procfs 是什么:VFS 框架下的伪文件系统

procfs(挂载在 `/proc`)是一个**伪文件系统**(pseudo filesystem)——它没有底层块设备、不往磁盘写任何东西,所有"文件"都是内核在内存里造出来的。它的根是 procfs 自己的 `super_block`(走 [VFS 那篇](./01-fs-vfs.md) 第六节讲的 `get_tree_nodev` 路线挂载),目录结构靠 `proc_dir_entry` 维护,文件内容靠每次 `read` 时回调内核函数现算。

procfs 里大致分两类内容:**进程相关信息**(每个进程一个 `/proc/[pid]/` 目录,里面有 `status`/`maps`/`cmdline` 等,内核的 `proc_pid_*` 代码负责生成)和**系统级信息**(`/proc/cpuinfo`、`/proc/meminfo`、`/proc/mounts` 这些全局项,各子系统自己注册)。我们作为模块开发者,最常打交道的是后者——**往 `/proc` 里加一个自定义文件,暴露模块的状态或调试信息**。下面几节就是围绕"怎么加这个文件、加了之后读写怎么走"展开。

### 二、`proc_dir_entry`:procfs 的目录项

procfs 不像 ext4 那样靠磁盘上的目录项块——它用自己的结构体 **`proc_dir_entry`**(`fs/proc/internal.h:31`)代表 `/proc` 树里的每一个节点(文件或目录)。我们把它关键字段抓出来:

```c
struct proc_dir_entry {
    ...
    char                       *name;       /* 这个项的名字 */
    umode_t                     mode;       /* 权限位(如 0644) */
    void                       *data;       /* 模块挂的私有数据(回调里能取到) */
    struct proc_dir_entry      *parent;     /* 父目录 */
    struct rb_root              subdir;     /* 子目录/文件(红黑树组织) */
    ...
    struct list_head            pde_openers;/* 记录谁打开了它但还没关 */
    ...
};
```

把它和 [VFS](./01-fs-vfs.md) 的 `dentry`/`inode` 对应起来理解:`proc_dir_entry` 是 procfs 内部的目录结构(类似 dentry),它挂着的 `data` + 一组操作(下一节的 `proc_ops`)共同承担了 inode 的角色。`subdir` 用红黑树组织子项——查找 `/proc/<foo>` 时就在这棵树上走,不走磁盘。这个结构体定义在 `fs/proc/internal.h`(注意是 `internal.h`,意味着它本就是 procfs 内部的、不希望外部模块直接操作字段);外部模块该用的 API 是它对外暴露的那几个创建函数(第四节)。

### 三、`proc_ops`:procfs 的 `file_operations`(5.6+ 校订)

这里有个**会让老资料翻车**的版本演进,必须先讲清楚。在 5.6 之前,procfs 文件的操作表直接就是 VFS 的 `struct file_operations`——你 `proc_create` 时传一个 `file_operations` 进去就行。但**从 5.6 起**(为加固安全、把 procfs 文件访问限制在进程上下文等考量),内核引入了**专门的 `struct proc_ops`**(`include/linux/proc_fs.h:35`),procfs 文件用这套,和普通 `file_operations` 区分开:

```c
struct proc_ops {
    int       (*proc_open)(struct inode *, struct file *);
    ssize_t   (*proc_read)(struct file *, char __user *, size_t, loff_t *);
    ssize_t   (*proc_read_iter)(struct kiocb *, struct iov_iter *);
    ssize_t   (*proc_write)(struct file *, const char __user *, size_t, loff_t *);
    loff_t    (*proc_lseek)(struct file *, loff_t, int);
    int       (*proc_release)(struct inode *, struct file *);
    __poll_t  (*proc_poll)(struct file *, struct poll_table_struct *);
    long      (*proc_ioctl)(struct file *, unsigned int, unsigned long);
    ...
};
```

注意方法名都加了 `proc_` 前缀——它和 `file_operations` 的 `read`/`open` 一一对应,只是名字不同、且 procfs 在内部把 `proc_ops` 包装回 VFS 需要的 `file_operations` 时,顺带做了一层检查(比如确保某些操作只在合适的上下文里跑)。**6.19 里你写 procfs 文件,操作表必须是 `proc_ops`,不是 `file_operations`**——拿 LDD3 或老博客的 `file_operations` 例子直接抄,会编译报错或行为诡异。这是这一篇最重要的校订点。

### 四、创建/删除 API:四件套

外部模块(包括我们自己的内核模块)要往 `/proc` 加文件,用的是 `include/linux/proc_fs.h` 里的这组 API:

```c
/* 创建一个 proc 文件,挂到 parent 下,用 proc_ops 描述行为 */
struct proc_dir_entry *proc_create(const char *name, umode_t mode,
                                   struct proc_dir_entry *parent,
                                   const struct proc_ops *proc_ops);   /* :115 */

/* 同上,但能挂一份私有数据(回调里用 pde_data() 取) */
struct proc_dir_entry *proc_create_data(const char *name, umode_t mode,
                                        struct proc_dir_entry *parent,
                                        const struct proc_ops *proc_ops,
                                        void *data);

/* 创建目录(在 /proc 下开一个子目录) */
struct proc_dir_entry *proc_mkdir(const char *name,
                                  struct proc_dir_entry *parent);

/* 移除一个 proc 项(模块卸载时必须调) */
void proc_remove(struct proc_dir_entry *pde);
```

`proc_create` 的四个参数:文件 `name`、权限 `mode`(如 `0644`)、父目录 `parent`(传 `NULL` 表示直接挂 `/proc` 根)、以及上一节的 `proc_ops`。拿到返回的 `proc_dir_entry *` 存好——模块卸载时要用它调 `proc_remove` 删掉,否则会留下悬空指针、用户态一访问就崩。

> ⚠️ **配对纪律:创建必有删除**
> 这条和内核里 `kmalloc/kfree`、`register/unregister` 是同一类铁律:`proc_create` 出来的项,模块 `exit` 时必须 `proc_remove`。漏了的话,模块卸载后 `/proc` 里那个文件还在,用户态 `cat` 它就走进一片已释放的内核内存,后果从报错到 panic 不等。把它和 [模块参数](../../foundations/09-kernel-module-params.md) 里讲的"sysfs 参数文件随模块生命周期"对照记——伪文件系统的项,生命周期必须和创建它的模块严格绑定。

### 五、读写一个 `/proc` 项:`open/read/write` + 私有数据

现在把四、五节缝起来,看一个 `/proc/penguinlab` 文件怎么从创建到被读取。模块 `init` 时:

```c
/* 模块里定义一个 proc_ops(注意是 proc_ops,不是 file_operations) */
static const struct proc_ops pl_proc_ops = {
    .proc_open    = pl_open,
    .proc_read    = pl_read,
    .proc_release = pl_release,
};

static struct proc_dir_entry *pl_entry;

static int __init pl_init(void)
{
    /* 挂到 /proc 根,权限 0444(只读) */
    pl_entry = proc_create("penguinlab", 0444, NULL, &pl_proc_ops);
    if (!pl_entry)
        return -ENOMEM;
    return 0;
}

static void __exit pl_exit(void)
{
    proc_remove(pl_entry);   /* 配对删除 */
}
```

用户态 `cat /proc/penguinlab` 时,VFS 路径解析到这个 proc 项,打开时调 `pl_open`(用 `single_open` 之类的 helper 绑定一个"序列输出函数",见下节),`read` 时调 `pl_read`(把内核里现算的字符串拷到用户态 buffer),关闭时调 `pl_release`。整个数据流完全走 [VFS 分派](./01-fs-vfs.md) 那套,只不过 `f_op` 指向的是 procfs 从 `proc_ops` 包装出来的 `file_operations`。

如果需要让每次 `read` 用上模块的私有数据,用 `proc_create_data` 挂一份 `data` 进去,回调里用 `pde_data(inode)`(6.19 的推荐 API,取代了老的 `PDE_DATA`)把它取出来——这是 procfs 给"一个文件对应一份模块状态"提供的标准挂钩。

### 六、`seq_file`:大输出和结构化数据的利器

如果 proc 文件的内容是固定一行字符串,手写 `proc_read` 用 `copy_to_user` 拷过去就行。但很多 proc 文件内容是**可变长、多行、需要迭代**的(`/proc/mounts` 列所有挂载点、`/proc/cpuinfo` 列所有 CPU、`/proc/modules` 列所有模块)——这时候手写 `read` 处理"用户 buffer 不够大要分多次读、偏移怎么维护"会非常痛苦。内核为此提供了 **seq_file** 机制(`include/linux/seq_file.h`),它是 procfs(以及后来的 sysfs、debugfs)处理结构化输出的标配。

seq_file 的用法套路是:你实现一组 `start/next/stop/show` 迭代回调(`show` 里用 `seq_printf` 往一个 buffer 里"打印"当前项),然后用 `single_open`(单条记录)或 `seq_open`(迭代多条)把它绑给 `proc_open`;`proc_read` 直接用现成的 `seq_read` helper。这样"分页读、偏移、buffer 管理"全由 seq_file 框架兜底,你只关心"每一步该输出什么"。多数 `/proc` 下的大输出文件都是这么实现的,读 procfs 源码时看到 `seq_file`/`seq_read`/`single_open` 就是它。

### 七、procfs vs sysfs:什么该放 `/proc`,什么该放 `/sys`

最后讲一个容易混淆的设计抉择。procfs 和 sysfs 都是伪文件系统,都暴露内核状态,那模块该往哪边放?惯例是:

- **`/proc`**:历史上是"什么都往里塞"的杂物间,现代内核倾向于**只放进程相关(`[pid]/`)和少数传统系统级项**;新代码如果暴露的是"某个内核子系统的状态",不建议再加 `/proc` 项。
- **`/sys`**:基于 kobject/driver model 的、**结构化的设备/驱动属性**暴露,新代码的"模块属性/设备参数"基本都走 sysfs(下一篇 [fs-sysfs](./03-fs-sysfs.md) 展开)。

所以写一个学习用的"模块状态文件",放 `/proc` 可以(简单、老派);但如果是正经驱动要暴露设备属性,走 `/sys` 更规范。这条界限记住,就不会在错的地方堆文件。

## 动手试试

> example 随亲测补到 `example/mini/`:一个创建 `/proc/penguinlab` 的模块,暴露一行(或多行)模块状态。

1. menuconfig 确认 procfs 默认开(`CONFIG_PROC_FS`,几乎总是开);QEMU 启动后 `cat /proc/cpuinfo`、`cat /proc/meminfo`、`ls /proc/self/` 先感受 procfs 的内容
2. 写一个模块:`proc_create("penguinlab", 0444, NULL, &pl_proc_ops)`,实现 `proc_open/proc_read/proc_release`(用 `single_open` + `seq_printf` 输出一句"模块已加载 + jiffies"之类);`insmod` 后 `cat /proc/penguinlab` 验证,`rmmod` 后确认它消失
3. 故意把 `proc_ops` 写成 `file_operations`(即把 `.open/.read` 而非 `.proc_open/.proc_read`),观察编译期或运行期的报错——体会本篇第三节那条 5.6+ 校订
4. 故意**漏掉 `proc_remove`**(模拟配对失误),`rmmod` 后 `cat /proc/penguinlab`,观察现象(⚠️ 这会触发访问已释放内存,可能在 QEMU 里产生 oops/panic——这正是"配对纪律"的反面教材,做这个实验前确认不怕 QEMU 崩)
5. 进阶:用 `proc_create_data` 挂一份私有数据(比如一个计数器),`proc_read` 里用 `pde_data()` 取出并递增后输出,每次 `cat` 看到计数器增长
6. 思考题:对照 [模块参数](../../foundations/09-kernel-module-params.md) 的 sysfs `/sys/module/<mod>/parameters/`,一个"模块的运行时可调参数"放 sysfs、一个"模块状态的只读快照"放 procfs,这种分工背后的设计依据是什么?(提示:sysfs 的"每个文件一个属性"约定 vs procfs 的"一个文件一份多行文本")

## 延伸阅读

- kernel.org:[The /proc filesystem](https://docs.kernel.org/filesystems/procfs.html) 讲 procfs 的设计与使用(侧重给子系统维护者的约定,以及哪些不该往 `/proc` 加);`Documentation/filesystems/seq_file.rst` 是 seq_file 机制的官方教程,本篇第六节的展开。
- 源码(本仓库 `third_party/linux/`,6.19.9):`fs/proc/internal.h:31` 的 `struct proc_dir_entry`、`include/linux/proc_fs.h:35` 的 `struct proc_ops`(5.6+ 的接口)、`:115` 的 `proc_create`、以及同文件的 `proc_create_data`/`proc_mkdir`/`proc_remove`/`pde_data`;seq_file 在 `include/linux/seq_file.h` 与 `fs/seq_file.c`;进程目录 `fs/proc/base.c`、系统级项散落 `fs/proc/` 各文件。
- 关联本站:本篇紧接 [01 VFS 框架](./01-fs-vfs.md)(procfs 是 VFS 四对象 + ops 表的最小填法);`proc_ops` 的"操作表"思路和 [模块参数](../../foundations/09-kernel-module-params.md) 的 sysfs 参数文件、[调度类](../sched/01-sched-overview.md) 的 `sched_class` 是同一套"vtable 分派";下一篇 [03 sysfs](./03-fs-sysfs.md) 讲 procfs 的"结构化表亲"。
- 经典纸面参考:LDD3 第 4 章讲 procfs,但它的例子用的是 `file_operations`(2.6 时代),6.19 必须改用 `proc_ops`——结合本篇第三节校订读。
