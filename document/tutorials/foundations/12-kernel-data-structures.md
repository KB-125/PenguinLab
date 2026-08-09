---
title: "内核数据结构四件套:container_of、list_head、hlist、rbtree"
slug: kernel-data-structures
prerequisites:
  - process-thread-kernel
next:
  - user-kernel-boundary
difficulty: intermediate
tags: [data-structures, container_of, list_head, hlist, rbtree, intrusive, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - source: third_party/linux（6.19）include/linux/{list.h,container_of.h,rbtree.h,rbtree_types.h}
maturity: drafting
related:
  - /tutorials/foundations/10-process-thread-kernel
  - /tutorials/kernel/sched/02-sched-cfs-eevdf
---

> 🔨 **整理中** · 这一篇讲内核那套"泛型数据结构库"——`container_of`、双向链表 `list_head`、哈希链表 `hlist`、红黑树 `rbtree`。它们是写内核代码的必备基本功:你读任何子系统的源码,满眼都是 `container_of(ptr, struct foo, node)`、`list_for_each_entry(...)`、`rb_entry(...)` 这种用法——光 `list_for_each_entry` 在 `include/linux/` 下就有 28 个头文件引用。素材直接来自 6.19 源码头文件(权威、无歧义);动手部分在 QEMU 亲手跑过之前标"待亲测"。校订增量:6.19 官方建议新代码优先用 `container_of_const`(保留 const 正确性),老资料只讲 `container_of`。

## 做什么

写过用户态 C 的人, привыкший к `glibc`/`STL` 那种"容器装数据"的链表/树,头一回读内核源码都会懵:怎么到处是 `container_of`,它是干嘛的?`list_head` 只有两个指针、不带数据,这链表怎么知道它存的是什么?其实内核这套数据结构走的是另一条设计哲学——**侵入式(intrusive)数据结构**,和"容器装数据"正好反过来。一旦想通这条,内核源码里一半的"奇怪写法"你就懂了。

这一篇我们把内核最常用的四件套拆透:`container_of`(从成员指针反查宿主结构,这套哲学的基石)、`list_head`(双向链表,内核里用得最多的结构)、`hlist`(省一个指针的哈希链表)、`rbtree`(红黑树,CFS/EEVDF 调度器、内存管理都在用)。读完它,你再读 [进程线程](./10-process-thread-kernel.md) 里 `task_struct` 的 `tasks` 链表、[CFS/EEVDF](../kernel/sched/02-sched-cfs-eevdf.md) 里的红黑树,就知道那些宏在做什么了。

## 要了解什么

### 一、`container_of`:从成员反查宿主(这套哲学的基石)

整个侵入式数据结构体系建立在一个宏上:**`container_of`**(`include/linux/container_of.h:19`)。它的作用是——给你一个"某结构体里某个成员的指针",反推出"宿主结构体的指针"。我们看 6.19 里它的展开:

```c
#define container_of(ptr, type, member) ({                              \
    void *__mptr = (void *)(ptr);                                       \
    static_assert(__same_type(*(ptr), ((type *)0)->member) ||           \
                  __same_type(*(ptr), void),                            \
                  "pointer type mismatch in container_of()");           \
    ((type *)(__mptr - offsetof(type, member))); })
```

干的事很直白:`offsetof(type, member)`(`include/linux/stddef.h:16`,展开成编译器内置的 `__builtin_offsetof`)算出"成员在宿主结构里的字节偏移";把成员指针 `__mptr` 减去这个偏移,就回退到了宿主结构体的起始地址,再 cast 成 `type *`。前面那个 `static_assert` 是 6.x 加的类型校验——传进来的 `ptr` 类型得和成员类型对得上,不匹配编译期就报错,是个安全网。

这件事为什么重要?因为内核的数据结构是"**数据里嵌入一个链表/树节点**",而不是"链表节点里装数据指针"。遍历链表时,拿到的是嵌入的 `list_head` 节点的地址,要取回它所属的那个结构体,就必须 `container_of`——`list_for_each_entry`、`rb_entry`、`hlist_for_each_entry` 这些遍历宏,内部全是在调 `container_of`。可以说,**没有 `container_of`,就没有内核的泛型数据结构**。

> ⚠️ **校订:6.19 优先用 `container_of_const`**
> 6.x 给 `container_of` 加了个 const 保留版本 **`container_of_const`**(`container_of.h:35`),源码注释明说"**新代码优先用 `container_of_const()`**"——它能保留指针的 const 限定(传进 const 指针,返回 const 指针),避免无意中丢掉 const 保护。老资料和 LDD3 只讲 `container_of`,读 6.19 源码你会看到大量 `container_of_const` 调用,两者机制一样,只是后者 const-correct。

### 二、双向链表 `list_head`:内核用得最多的结构

**`struct list_head`** 是内核里最 ubiquitous 的结构,它就俩指针:

```c
struct list_head {
    struct list_head *next, *prev;
};
```

注意它**不带任何数据**——这就是侵入式设计的体现。一个"存任务的链表"不是 `list<task_struct>`,而是"`task_struct` 里嵌入一个 `list_head` 成员"(比如 `task_struct->tasks`),所有节点都是这种自治的双指针结构,串成环。要存不同类型的数据,就各自在自己的结构体里嵌入 `list_head`,共用同一套链表操作 API。这套 API 在 `include/linux/list.h`,我们抓几个最常用的:

```c
/* 初始化:可以 LIST_HEAD(name) 宏声明+初始化,或 INIT_LIST_HEAD(ptr) */
void list_add(struct list_head *new, struct list_head *head);       /* 头插:加到 head 后面 */
void list_add_tail(struct list_head *new, struct list_head *head);  /* 尾插:加到链表末尾 */
void list_del(struct list_head *entry);                             /* 删除某节点 */
void list_move(struct list_head *list, struct list_head *head);     /* 从原位置摘下,挪到 head 后 */
int  list_empty(const struct list_head *head);                      /* 判空 */
```

但光这些还不够——内核链表的精髓是**遍历宏**,它们把"`list_head` 指针 → 宿主结构指针"这一步封装好了:

```c
/* 遍历:pos 是宿主结构指针迭代器,head 是链表头,member 是 list_head 在宿主里的成员名 */
struct my_item *pos;
list_for_each_entry(pos, head, node) {
    /* 这里 pos 已经是宿主结构指针,直接用 pos->field */
    pr_info("item: %d\n", pos->value);
}

/* 遍历时可能要删除节点:用 _safe 版本(额外缓存 next) */
list_for_each_entry_safe(pos, tmp, head, node) {
    list_del(&pos->node);
    kfree(pos);
}
```

`list_for_each_entry` 内部就是 `for` 循环 + `container_of`,把"取宿主"和"推进到下一节点"包成一行。注意**遍历时删除节点必须用 `_safe` 版**(它缓存了 next,否则删了当前节点就找不到下一个了)——这是内核链表最经典的坑之一。[进程线程](./10-process-thread-kernel.md) 里讲的所有 `task_struct` 串成的 `tasks` 链表,遍历它的 `for_each_process` 宏就是这套机制。

### 三、哈希链表 `hlist`:省一个指针的变体

普通 `list_head` 的问题是:作为链表头的那个节点,也得是个完整的 `list_head`(next + prev 俩指针)。对于"哈希桶"这种"一大堆链表头"的场景,每个头都耗两个指针有点浪费。所以内核提供了 **`hlist`**(`include/linux/list.h`),区别在于**头节点和普通节点是不同类型**:

```c
struct hlist_head {
    struct hlist_node *first;     /* 头只要一个指针 */
};

struct hlist_node {
    struct hlist_node *next, **pprev;  /* 普通节点:next 指针 + 指向"上一个节点的 next 指针"的二级指针 */
};
```

普通节点用 `pprev`(指向"上一个节点里存我的那个 next 指针"的指针,即 `**`),巧妙地把"头节点和普通节点删除时都能用同一段代码"这件事解决了——这是 hlist 最骚的设计。API 用法(`hlist_add_head`/`hlist_del`/`hlist_for_each_entry`)和 `list_head` 同构,只是遍历哈希桶时用它。内核里 `pid hash`、`inode hash` 等大量哈希表都用 hlist 做桶。

### 四、红黑树 `rbtree`:CFS/EEVDF、内存管理都在用

红黑树是内核里唯一的"自平衡二叉搜索树"实现,凡是需要"按某键 O(log n) 查找/插入/删除"的场景几乎都用它:CFS/EEVDF 的运行队列([02-sched-cfs-eevdf](../kernel/sched/02-sched-cfs-eevdf.md) 里按 deadline 排)、内存管理的 VMA、ext4 的 extent 树底层思路。核心结构在 `include/linux/rbtree_types.h`:

```c
struct rb_node {
    unsigned long  __rb_parent_color;  /* 编码了"父指针 + 节点颜色"(省空间) */
    struct rb_node *rb_right;
    struct rb_node *rb_left;
};

struct rb_root {
    struct rb_node *rb_node;           /* 根 */
};

struct rb_root_cached {                /* 缓存最左节点版:O(1) 取最小 */
    struct rb_root  rb_root;
    struct rb_node *rb_leftmost;
};
```

`rb_root_cached` 缓存了最左节点——红黑树最左节点就是"键最小的",缓存它能让"取最小"变成 O(1)(CFS/EEVDF 选下一个任务要频繁取最小 deadline,正需要这个)。插入分两步:`rb_link_node` 把节点挂到正确位置(普通 BST 插入)、`rb_insert_color` 重新平衡(红黑树的旋转/重染色)。遍历靠 `rb_first`/`rb_next`(`include/linux/rbtree.h:50/44`)逐个走中序,配合 `rb_entry`(就是 `container_of` 的别名)取回宿主:

```c
struct my_node *cur;
struct rb_node *it;
for (it = rb_first(&tree.rb_root); it; it = rb_next(it)) {
    cur = rb_entry(it, struct my_node, rb_node);   /* 取回宿主 */
    pr_info("key=%lu\n", cur->key);
}
```

> 💡 **内核 rbtree 的一个设计取舍**
> 内核的 rbtree **只提供树的"骨架"操作(插入平衡/删除/遍历),不提供"比较函数"**——比较逻辑由调用方自己实现(`rb_link_node` 时传父/位置,调用方自己判断该往左还是往右)。这和 generic 库"传一个 comparator 给 tree"的思路不同,内核的选择是"让每个用户自己写那一小段比较、换来零抽象开销和最大灵活性"。这是内核数据结构库一以贯之的设计取向。

### 五、为什么是"侵入式"设计:数据嵌入节点,不是节点装数据

把四件套放一起,它们共享一个反直觉的设计哲学,值得单独拎出来说:**侵入式(intrusive)数据结构**。用户态的 STL/glibc 习惯"容器装数据"——`std::list<T>` 的节点里包着一个 `T`;内核反过来,**数据结构里嵌入一个节点成员**——`task_struct` 里有个 `tasks` 成员(类型 `list_head`),它就靠这个成员被串进"任务链表"。

这种反过来的设计有三个实在好处:**一是零内存分配开销**(节点不是单独分配的,它就躺在宿主结构体里,宿主分配了节点自然就在);**二是一个对象可以同时挂在多条链表上**(只要它嵌入多个 `list_head` 成员,比如 `task_struct` 既有 `tasks` 全局链表,又有别的链表);**三是类型无关**(同一套 `list_add`/`list_for_each_entry` 宏,任何嵌了 `list_head` 的类型都能用,靠 `container_of` 取回)。代价是语法上要用宏、用 `container_of` 反查,新手得适应一下。但想通这套"侵入 + container_of"的范式,内核里 list/hlist/rbtree/kfifo(环形缓冲)几乎所有数据结构你都能秒懂——它们都是同一个套路的不同实例。

## 动手试试

> example 随亲测补到 `example/mini/`:一个用 list_head 串几个结构、用 container_of 遍历的模块。

1. 写一个模块:定义 `struct my_item { int value; struct list_head node; }`,声明一个 `LIST_HEAD(my_list)` 头;`init` 里 `kmalloc` 几个 item、`list_add_tail(&item->node, &my_list)` 串起来
2. 用 `list_for_each_entry(pos, &my_list, node)` 遍历打印每个 `pos->value`——体会"pos 已经是宿主指针"的便利(宏内部隐含 container_of)
3. `exit` 时用 `list_for_each_entry_safe` 把所有 item `list_del` + `kfree`(体会"删除必须用 _safe 版"那条规矩)
4. 故意写成普通 `list_for_each_entry` 删除(不用 _safe),观察 `rmmod` 时的 oops/异常——理解为什么遍历删除要 _safe
5. 进阶:再定义一棵 rbtree(`struct rb_root_cached`),把上面的 item 按 `value` 作键 `rb_link_node` + `rb_insert_color` 插入,`rb_first`/`rb_next` 遍历验证"按键升序"
6. 思考题:为什么内核的 `list_head` 不带数据类型,而是让调用方在宿主结构里嵌入?对比 `std::list<T>` 这种"容器装数据"的设计,讲出侵入式那三个好处中你最看重的一个

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/container_of.h:19 container_of`、`:35 container_of_const`(新代码优先)、`include/linux/stddef.h:16 offsetof`;`include/linux/list.h` 全篇——`struct list_head`、`list_add:175`/`list_add_tail:189`/`list_del:235`/`list_move:304`/`list_empty:379`、`list_for_each_entry` 及 `_safe` 版、`struct hlist_head/hlist_node` 与 `hlist_for_each_entry:1166`;红黑树在 `include/linux/rbtree_types.h`(`struct rb_node:5`/`rb_root:12`/`rb_root_cached:26`)和 `include/linux/rbtree.h`(`rb_link_node:87`/`rb_first:50`/`rb_next:44`/`rb_entry_safe:105`)。
- 关联本站:本篇是读内核源码的基础设施——[进程线程](./10-process-thread-kernel.md) 的 `task_struct.tasks` 链表用 `list_head`、`for_each_process` 用这套遍历;[CFS/EEVDF](../kernel/sched/02-sched-cfs-eevdf.md) 的运行队列按 deadline 排红黑树(`rb_root_cached`);`container_of` 在 [chardev](../drivers/01-drv-chardev.md) 里从 `inode->i_cdev` 取回自定义设备结构时已经用过;`list_for_each_entry` 的热度可自行 `grep -r` 内核源码验证。
- 命令行:`grep -r 'list_for_each_entry' include/ | wc -l` 自己看这套宏在内核里被引用多少次(本篇整理时是 28 个头文件),直观感受它的"基础设施"地位。
