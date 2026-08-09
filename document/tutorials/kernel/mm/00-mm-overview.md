---
title: "mm 子系统全景:从进程地址空间到物理页"
slug: mm-overview
prerequisites:
  - virtual-address-space
  - process-thread-kernel
next:
  - mm-buddy
difficulty: intermediate
tags: [mm, mm_struct, vm_area_struct, page-table, demand-paging, maple_tree, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch07.md
  - source: third_party/linux（6.19）include/linux/mm_types.h、include/linux/mm.h、mm/
maturity: drafting
related:
  - /tutorials/foundations/11-virtual-address-space
  - /tutorials/kernel/mm/01-mm-buddy
  - /tutorials/kernel/fs/04-fs-page-cache
---

> 🔨 **整理中** · 这一篇是 mm(内存管理)藤的**入口/全景**——把进程地址空间、VMA、页表、缺页、物理内存管理串成一张地图,为后面 [buddy](./01-mm-buddy.md)/slab/vmalloc/reclaim/oom 各篇建立全局视野。素材从读书笔记 ch07 + 6.19 源码整理。重要校订:**6.x 起 `mm_struct` 用 `maple_tree`(`mm_mt`)管理 VMA,取代了老的红黑树 + 链表**——老资料讲的 `mm->mm_rb`/`mm_rb` 在 6.x 是 `mm->mm_mt`。

## 做什么

[虚拟地址空间](../../foundations/11-virtual-address-space.md) 那篇我们从用户视角看了 VAS 的"段布局",说"进程以为自己独占内存"是 `task_struct → mm_struct → 页表 → 物理页` 这条链搭起来的幻觉。这一篇我们就把这条链在内核侧拆开:`mm_struct` 是怎么描述一整个进程地址空间的、VMA 怎么描述一段段映射、页表怎么把虚拟翻译成物理、缺页异常怎么实现"按需分页",以及最后落到物理内存——由 [buddy 伙伴系统](./01-mm-buddy.md)管。这一篇不深入任何一块(那是后面各篇的活),只搭骨架,让你读 mm 子系统源码时知道每个部分在全景里的位置。

## 要了解什么

### 一、mm 子系统的两个职责

内核内存管理其实在做两件大事,先分清楚:**进程地址空间管理**(每个进程的"虚拟"视图:VMA、页表、缺页)和**物理内存管理**(全机器共享的"物理"资源:buddy/slab 分配、回收、OOM)。前者是"每个进程各看各的",后者是"全局一份 RAM 大家分"。这两条在 mm 子系统里耦合但概念上独立——[虚拟地址空间](../../foundations/11-virtual-address-space.md) 讲用户视角偏向前者,[buddy](./01-mm-buddy.md) 讲后者。这一篇把前者(进程地址空间)讲透,后者点到、留给 buddy/slab/vmalloc 各篇。

### 二、`mm_struct`:进程地址空间的化身

每个进程(更准确是每个"有用户空间的线程")内核里有一个 **`struct mm_struct`**(`include/linux/mm_types.h:1075`),它就是"这个进程的整片地址空间"的化身。[进程线程](../../foundations/10-process-thread-kernel.md) 里讲的 `task_struct->mm` 指向它(内核线程的 `mm` 是 NULL——它们没有用户空间)。关键字段:

```c
struct mm_struct {
    struct maple_tree mm_mt;        /* :1092 ← VMA 的容器(maple tree,6.x 取代 rbtree) */
    ...
    pgd_t *pgd;                     /* :1102 ← 顶级页表根(ARM64 是 TTBR0 指向它) */
    ...
    unsigned long total_vm;         /* :1190 ← 总映射页数 */
    ...
    /* 代码/数据/堆/栈的边界:start_code/end_code/start_data/end_data/start_brk/brk/start_stack */
};
```

`mm_struct` 把"这个进程的地址空间长什么样"全记住了:VMA 集合(`mm_mt`)、页表根(`pgd`)、各段边界、总占用(`total_vm`)。`fork` 时子进程得到一份拷贝(写时复制,详见 mm 藤 fork 相关)、`exec` 时整体重建。它是 mm 子系统理解进程地址空间的入口。

### 三、VMA:`vm_area_struct`,一段虚拟地址映射

VAS 不是铁板一块,它被切成一段段的 **VMA(vm_area_struct)**(`mm_types.h:904`)——每个 VMA 描述"**一段连续的虚拟地址范围,它们有相同的属性(权限/来源/映射后端)**"。一个 `mmap` 调用就建一个 VMA;代码段、数据段、堆、栈各是 VMA;加载 `.so` 各建 VMA。VMA 的关键字段:起止地址(`vm_start`/`vm_end`)、权限(`vm_flags`:`VM_READ`/`VM_WRITE`/`VM_EXEC`)、它映射的后端(`vm_file` 映射文件、或匿名)、`vm_ops`(这段 VMA 的操作回调,如 `fault`——缺页时怎么处理)。

VMA 集合存在 `mm_struct->mm_mt`(6.x 是 maple tree)。**校订增量**:6.x 之前,VMA 用"红黑树 + 双向链表"两个结构同时组织(树用于快速查找、链表用于遍历);从 6.1 起,Liam Howlett 把 VMA 管理迁到了 **maple tree**(一种 B-tree 变种,`struct maple_tree`),单数据结构、并发性更好、`mmap` 大批量操作的性能更高。所以读 6.19 源码你看到的是 `mm->mm_mt`(maple tree)和 `mas_walk`/`mas_for_each` 这些 maple tree API,而老资料讲的 `mm->mm_rb`(红黑树)已经不在了。`/proc/<pid>/maps` 那一长串 VMA,就是遍历这棵 maple tree 打印出来的。

### 四、页表:虚拟→物理的翻译表

页表是把虚拟地址翻译成物理地址的表,ARM64 通常是**四级页表**(`pgd → pud → pmd → pte → 物理页`)。`mm_struct->pgd` 指向顶级页表根,每个进程一份。MMU 硬件在每次内存访问时,拿虚拟地址逐级查页表(`pgd` 索引 → `pud` 索引 → ... → `pte` → 物理页基址 + 页内偏移),翻译不出来就触发**缺页异常**(下一节)。为加速,MMU 里有个 **TLB**(Translation Lookaside Buffer)缓存最近翻译过的条目——TLB miss 才走内存里的多级页表。

页表条目(pte)除了物理页号,还编码了权限位(可读/可写/可执行)、脏位(是否改过)、访问位等——这些位让 MMU + 内核能实现"按权限访问"、"写时复制"、"换出/换入"等机制。深入(pte 的位布局、大页 huge page)属于 mm 藤的页表专篇。

### 五、缺页异常:按需分页(demand paging)

页表一开始不是满的——新 `mmap` 一段地址只建 VMA、**不立刻分配物理页**。进程真去访问那段地址时,MMU 查不到 pte → 触发**缺页异常** → 内核的 page fault 处理函数接管:检查这个地址在不在某个 VMA 里(在 → 是合法缺页,补上;不在 → `SIGSEGV`)。补上的方式取决于 VMA 的后端:**匿名映射**就向 [buddy](./01-mm-buddy.md) 要个新页、清零、建 pte;**文件映射**就走 [页缓存](../fs/04-fs-page-cache.md) 的 `read_folio` 从磁盘把内容读进来;**写时复制**页就复制一份再给。

这套"**先建映射(VMA),访问时才填物理页(缺页)**"的机制叫**按需分页(demand paging)**——它让进程能"分配"远多于物理内存的虚拟空间(真用了才占物理页),是现代操作系统内存效率的基石。

### 六、mm 子系统分层(本藤地图)

最后把 mm 藤各篇在这张全景里定位,方便你跳读:

- **进程地址空间层**:`mm_struct` + VMA + 页表 + 缺页(本篇)
- **物理页分配层**:[01 buddy 伙伴系统](./01-mm-buddy.md)(大块页)
- **小对象分配层**:slab/slab(基于 buddy 之上,管小对象)
- **虚拟连续分配**:vmalloc(要一段虚拟连续、物理不一定连续的大块)
- **回收与压力**:页面回收(kswapd/水印线)+ OOM killer(内存耗尽时)
- **跨 VFS 的桥**:[页缓存](../fs/04-fs-page-cache.md)(文件内容缓存在物理页里,由 `address_space` 组织)

## 动手试试

1. `cat /proc/<pid>/maps`(或 `/proc/self/maps`)看 VMA 列表——每行一个 VMA,对照本篇第三节(起止/权限/映射后端),直观看到 maple tree 的内容
2. `cat /proc/meminfo` 看 `MemTotal`/`MemFree`/`Cached`/`Mapped` 等,对照 mm 子系统的物理内存 + 页缓存
3. 写一个用户态程序 `malloc(大块)` 但不访问,看 `RSS`(`/proc/<pid>/status` 的 `VmRSS`)不涨;访问后 RSS 涨——体会"按需分页"(本篇第五节)
4. 进阶:读 `mm/memory.c` 的 `handle_mm_fault` 路径,看缺页怎么从 VMA 查到、怎么走到 buddy/filemap 分配页
5. 思考题:为什么 mm 子系统 6.x 要把 VMA 从红黑树迁到 maple tree?(提示:并发性、批量 mmap 性能)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/mm_types.h:1075 struct mm_struct`(`mm_mt maple_tree :1092`/`pgd :1102`/`total_vm :1190`)、`:904 struct vm_area_struct`、`:704 struct vm_region`;`include/linux/mm.h`;VMA 管理在 `mm/mmap.c`、maple tree 在 `lib/maple_tree.c`;缺页处理 `mm/memory.c` 的 `handle_mm_fault`/`do_anonymous_page`/`do_fault`/`do_wp_page`;页表 API 在 `include/linux/pgtable.h`。
- 关联本站:本篇是 [11 虚拟地址空间](../../foundations/11-virtual-address-space.md) 用户视角的内核侧展开;物理页底座 [01 buddy](./01-mm-buddy.md);页缓存把文件内容装进物理页 [04 page-cache](../fs/04-fs-page-cache.md);maple tree 是 6.x 重要基础设施,`Documentation/core-api/maple_tree.rst` 是它的官方文档。
- 读书笔记:[ch07](../../notes/linux_kernel_programming/ch07.md) 讲内存管理基础。
