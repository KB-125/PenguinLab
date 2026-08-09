---
title: "每个进程都以为自己独占内存:虚拟地址空间 VAS 全景"
prerequisites:
  - process-thread-kernel
next:
  - kernel-data-structures
difficulty: beginner
tags: [virtual-address-space, mm_struct, memory-layout, proc, arm64]
architectures: [arm64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch06.md
maturity: drafting
related:
  - /tutorials/foundations/10-process-thread-kernel
  - /tutorials/kernel/mm/01-mm-buddy
---

## 做什么

上一篇我们搞清楚了"我在谁的上下文里跑",这一篇接着问下一个更基本的问题:**每个进程都"以为"自己独占了整个内存,这套幻觉是谁搭起来的,又是怎么搭的?** 你写用户态程序时 `malloc` 拿到的地址、函数里局部变量的地址、`printf` 调到 glibc 时访问的 `.so` 里的地址——这些地址其实都不是物理内存条上的真实位置,而是"虚拟地址"。每个进程活在自己的一套虚拟地址空间(Virtual Address Space, VAS)里,各自有各自的 `0x0000...0000` 到 `0xffff...ffff`,互不打扰。这层"骗术"是现代操作系统之所以能同时跑几百个进程而不互相踩踏的根本。

作为要往内核钻的我们,光知道"有虚拟内存"远远不够,得在脑子里建立起 VAS 的**精确地形图**:从低地址到高地址依次摆着哪些段、哪一段往哪个方向长、用户空间到哪儿为止、内核空间从哪儿开始、又是哪个内核结构体在替每个进程"记住"它这套布局。这篇我们就把这张地图彻底画清楚,该用 6.19 源码钉死的地方(`PAGE_OFFSET`、`TASK_SIZE` 那一票)都钉死。和前几篇一样,运行输出还是标注成"待亲测",坐到 QEMU 前再升级。

## 要了解什么

### 一、VAS 是个沙盒:每个进程各看各的

先刻一条铁律:**内存是沙盒化的**。一个进程从它的视角往外看,看到的是一整片连续的、独属于自己的虚拟地址空间;它**看不到**别的进程的内存,也**看不到**物理 RAM 的真实布局——更别说往"外"够别的进程了,那是根本不存在的路径。进程之间、进程与物理硬件之间,被内核和 MMU(memory management unit)用页表这套机制彻底隔开。

那物理内存去哪了?它被内核当成一份"全局共享资源",在所有进程的 VAS 之间动态分配:进程 A 的虚拟页 `0x4000` 可能落在物理内存的 `0x1_0000`,进程 B 的虚拟页 `0x4000` 可能落在物理的 `0x2_0000`——虚拟地址相同,物理位置毫不相干,全靠各自的页表翻译。这就是为什么两个进程能各自占着 `0x4000` 这个地址相安无事。

进程的这套 VAS 不是铁板一块,它被内核划分成若干个**同质的小区段**,习惯上叫**段(segment)**,更技术性的叫法是**映射(mapping)**——因为它们本质上是内核通过 `mmap` 这一类系统调用,把"某段虚拟地址"和"某种后端"(文件、匿名内存、共享库)绑定出来的产物。下面我们从低地址往高地址,把一个标准 Linux 用户进程的 VAS 挨段走一遍。

### 二、从低到高走一遍 VAS

#### 第 0 页:专门抓 NULL 的陷阱

`0x0000...0000` 附近那一小段(通常一个页,4KB)是**故意留空且不可访问**的。它存在的唯一目的,就是让空指针 `NULL` 解引用立刻炸——`*ptr` 当 `ptr` 是 0 时,MMU 一翻译就发现"这一页没映射",直接触发缺页异常,内核给你送个 `SIGSEGV`(段错误)。如果 0 地址是可用的,空指针 bug 就会悄无声息地写出脏数据,而不是当场暴毙,排查难度直接升一个数量级。所以这"第 0 页"是个**蓄意的陷阱**。

#### Text 段(代码段):只读、可执行

接下来是 **Text 段**,存的是编译出来的机器指令,指令指针(PC/`RIP`/`LR`)就在这片地址上跳舞。权限是 `r-x`(读 + 执行,**不可写**)——可写就乱套了,程序能改自己的指令,安全防线秒破。Text 段是只读的另一个好处:多个进程跑同一个程序(比如 10 个 `bash`)可以**共享同一份**物理 Text 段,内核只要把它映射到各自的 VAS 即可,物理内存省下一大笔。

#### Data 段(数据段):全局变量的家

紧跟 Text 段的是 **Data 段**,权限 `rw-`,存全局变量和静态变量。它实际上分三小块:

- **已初始化数据(Initialized Data)**:代码里写了 `int x = 5;` 这种带初值的全局/静态变量,初值编进可执行文件,加载时原样映射进来。
- **未初始化数据(BSS)**:代码里 `int y;` 这种没给初值的全局/静态变量。可执行文件里 BSS 段**不占空间**(只记个大小),加载时内核直接分配清零的页——所以 BSS 变量天生就是 0,这是内核送的性质,不是 C 语言的魔法。
- **堆(Heap)**:`malloc` 的老家。它紧跟 BSS,而且**它是整个 VAS 里唯一向高地址增长的段**。堆当前最高的合法地址叫 **Program Break**(`brk`/`sbrk` 系统调用就是动这个边界,`sbrk(0)` 可以查当前值)。注意现代 glibc 已经不只靠 `brk` 分配堆了——小于某个阈值(典型 `MMAP_THRESHOLD = 128KB`)的小块才走堆,大于阈值的分配 glibc 会改用 `mmap` 在别处单独开一块匿名映射,免得把堆顶顶得太高、产生内部碎片。

#### 共享库:夹在堆和栈之间

所有动态链接的共享库(`.so` 文件,比如 `libc.so`、`ld-linux.so`)被映射在堆和栈之间的某段区域。这就是为什么同一个 `printf` 实现能被成百上千个进程共用——物理上一份,各自 VAS 里映射到不同(或相同)虚拟地址。

#### Stack(栈):从天花板往地上长

最后是 **Stack(栈)**,函数调用、参数传递、局部变量全压在这里。和堆相反,**栈向低地址增长**——这是现代 CPU(x86、ARM)的约定,术语叫 **Fully Descending Stack**(完全递减栈)。栈"顶"逻辑上是 VAS 的最高端(用户空间的上限附近),每次函数调用栈指针往低地址挪一格、开新栈帧,`return` 时再挪回来,轻量到几乎没有分配开销。

这里藏着一个对多线程编程极其重要的细节:一个进程至少有一个线程(跑 `main` 的那个),它的栈就安在 VAS 的最顶端;可如果进程有多个线程,这些线程**共享进程的整片 VAS**(Text、Data、堆、共享库大家都能看见),**唯独栈不共享——每个线程各有自己独立的私有栈**,主线程的栈在顶端,其他线程的栈则在堆和栈之间的"空地"里由内核分配。这正是多线程编程里"局部变量天然安全、全局变量必须加锁"的物理根源:局部变量在各自私有的栈篮子里,别人看不见;全局变量在共享的 Data 段,谁都能伸手。

> 💡 **一个能记住的类比**
> 把进程的 VAS 想成一个**四合院(沙盒)**:Text/Data 是地基和承重墙,建好就不动;堆是院子里临时搭的棚子,可以往院子中心(高地址)不断扩张;栈是从天花板往下挂的篮子,东西越多绳子放得越长(往低地址走)。而**线程**是住在这个四合院里的一家人——大家共用厨房和厕所(Text、Data、堆),但每个人有自己的私房钱藏在各自的行李箱(私有栈)里,你不能去翻别人的行李箱。

### 三、堆往上、栈往下:为什么方向相反

你可能会问:为什么堆和栈非得一个往上、一个往下长,不都往一个方向?答案是为了**把中间那大片空闲区域留给将来**,两边相向增长、在中间某处碰头才用尽,空间利用率最高。如果都往一个方向长,另一端的空间永远用不上,白瞎。

- **堆增长**靠 `brk` 系统调用抬升 Program Break:进程要更多堆,内核把堆顶边界往高地址推一页(同时在新页建页表映射)。`sbrk(increment)` 是 libc 包装,正数增量=扩张,负数=收缩,`sbrk(0)`=查当前边界。
- **栈增长**则是"懒"的:栈区域在 VAS 里只规定了一个**上限**(不能越过 `TASK_SIZE - 1` 页的 guard),但实际不预先分配。函数调用时栈指针往低地址走、踩到一个还没映射的页,MMU 触发缺页异常,内核这时才**当场**分配一页给它。所以栈是"用到哪分到哪",用 `ulimit -s` 可以看到栈大小的软上限(典型 8MB),超过这个边界再踩才报栈溢出。

### 四、用户空间到哪为止、内核空间从哪开始

前面三节讲的全是**用户空间**那半边。可虚拟地址空间不止用户这一半——每个进程的 VAS 其实是"用户空间 + 内核空间"两段拼起来的(从进程视角看,内核空间就在用户空间的"正上方")。当进程切入内核(系统调用、异常),CPU 切换到内核态,地址指针就走进内核空间那半边,那里映射着内核镜像、内核数据结构、以及一大片直接映射物理内存的"线性映射区"。

用户和内核的分界线在 ARM64 上由几个宏钉死,我们查 6.19 源码:

```c
/* arch/arm64/include/asm/processor.h:56 (6.19) */
#define TASK_SIZE_64    (UL(1) << vabits_actual)

/* arch/arm64/include/asm/processor.h:76 */
#define TASK_SIZE       TASK_SIZE_64       /* (64 位任务,简化) */

/* arch/arm64/include/asm/memory.h:43,45 */
#define VA_BITS         (CONFIG_ARM64_VA_BITS)
#define PAGE_OFFSET     (_PAGE_OFFSET(VA_BITS))
```

`TASK_SIZE` 是一个进程**用户空间能寻址的上限**——它就是 `1 << vabits_actual`,即"用 `vabits_actual` 这么多位地址能表达的最大值 + 1"。`vabits_actual` 基本等于 `CONFIG_ARM64_VA_BITS`(开了 KASLR 的 52 位扩展时略有不同)。ARM64 的 `VA_BITS` 是可配的,常见 39 位(4K/16K 页的经典默认)或 48 位:

- `VA_BITS = 39` 时,用户空间上限 `TASK_SIZE = 1 << 39 = 512GB`,内核空间从 `512GB` 起到 `2^39` 之上的高位。
- `VA_BITS = 48` 时,`TASK_SIZE = 1 << 48 = 256TB`,用户和内核各得 256TB。

`PAGE_OFFSET` 则是**线性映射区(linear map / direct map)的起点**——内核把物理 RAM "平铺"映射到从 `PAGE_OFFSET` 开始的一片虚拟地址上,这样内核想访问任意物理页,只要拿"物理地址 + 一个固定偏移"就能算出对应的虚拟地址,不用建独立页表,极快。它的确切位置随 `VA_BITS` 变(定义在 `memory.h:45`)。

> ⚠️ **架构差异提醒**
> 这些数字是 ARM64 的;同一套概念在 x86_64 上对应 `TASK_SIZE_MAX`(典型 47 或 48 位用户地址)、`PAGE_OFFSET`、`__START_KERNEL_map` 等,数值和布局都不同。本藤统一以 ARM64 为准,`[x86_64]` 标注处给出对照。内核地址空间的精细布局(线性映射、vmalloc 区、模块区、VMEMMAP)这篇只点到,深入展开留给 [mm-buddy](../kernel/mm/01-mm-buddy.md) 那一藤。

### 五、`mm_struct`:谁在替进程记住这张地图

说了这么多段和边界,那么"一个进程的 VAS 长什么样"——具体由哪些映射、每段从哪到哪、什么权限——这件事在内核里是**谁**记着的?答案挂在上一篇讲的 `task_struct` 上:每个(用户)线程的 `task_struct` 里有个指针 `mm`,指向一个叫 **`mm_struct`** 的结构体(纯内核线程没有 `mm`,它们的 `mm` 是 `NULL`,因为它们不享有用户空间)。

`mm_struct` 就是"一个进程地址空间"的内核化身。它里头记着:页表根指针(`pgd`,指向顶级页表)、代码段/数据段/堆/栈的起止边界(`start_code`/`end_code`/`start_data`/`end_data`/`start_brk`/`brk`/`start_stack`)、所有 `mmap` 映射区域组成的红黑树和链表(每棵节点是一个 `vm_area_struct`,简称 VMA,描述"这一段虚拟地址对应哪种映射")、以及这块地址空间一共占了多少内存(`total_vm`)等统计。

```c
/* 关联上一篇:current 指向当前 task_struct,它的 mm 就是当前进程地址空间 */
struct mm_struct *mm = current->mm;

pr_info("code:  0x%lx ~ 0x%lx\n", mm->start_code, mm->end_code);
pr_info("heap:  brk=0x%lx\n", mm->brk);
pr_info("stack: 0x%lx\n", mm->start_stack);
```

所以"进程以为自己独占内存"这个幻觉的物理载体,就是这套 `task_struct → mm_struct → 页表 → 物理页` 的链条:每个进程一份 `mm_struct`、一份页表,MMU 按各自的页表把虚拟翻译成物理,翻译不到就缺页,翻译到了就隔离访问——沙盒就是这么筑起来的。`mm_struct` 的细节、VMA 怎么管理、页表怎么走,都属于 layer-1 内存管理藤的领地,这里先建立"它存在、它挂在 `current->mm` 上"的认知就够了。

### 六、内核地址空间简览(点到为止)

最后用一句话带过内核空间那半边的布局,免得读者心里空一块。ARM64 的内核虚拟地址空间里(从 `PAGE_OFFSET` 往上的高位)大致排着:

- **线性映射区(linear map)**:从 `PAGE_OFFSET` 起,物理 RAM 一比一平铺,内核访问物理内存的主通道。
- **`vmalloc` 区**:内核动态分配大块虚拟连续(但不一定物理连续)内存的地盘,`vmalloc()` 就往这儿要。
- **模块区**:`MODULES_VADDR ~ MODULES_END`(`memory.h:48/46`),我们加载的 `.ko` 模块就映射到这一小段——这也是为什么前面几篇的模块代码跑在这片地址上。
- **VMEMMAP**:`VMEMMAP_START`(`memory.h:50`)起,是 `struct page` 数组的家,每个物理页对应一个 `struct page`,全部排在这里供内核按页号查。
- **内核镜像(KImage)**:`vmlinux` 加载的位置,`KIMAGE_VADDR` 附近。

这些区的精确边界随 `VA_BITS` 和页大小变,展开是 mm 藤的活。本篇只让你知道"内核空间也不是一团混沌,它一样分了区,模块区是跟我们写 `.ko` 最相关的那块"。

### 七、实战观察:`/proc/<pid>/maps` 把地图摊给你看

讲了半天布局,怎么亲眼看到它?最直接的工具是 `/proc/<pid>/maps`(或 `/proc/self/maps` 看自己),它把目标进程当前所有 VMA 段逐行列出来。一个跑在 BusyBox 里的进程,`maps` 长这样:

```
00000000_aaaa0000-00000000_aaaa1000 r-xp 00000000 00:00 0  [...text...]
00000000_aaab0000-00000000_aaac0000 rw-p 00000000 00:00 0  [heap...]
...
0000ffff_xxxx0000-0000ffff_xxxx1000 r-xp ...  [共享库]
0000ffff_yyyy0000-0000ffff_yyyyf000 rw-p ...  [stack]
```

> ⚠️ **待亲测**:上面是 ARM64 `maps` 的格式示意(地址带 ARM64 64 位的高位 `0x0000_...`/`0xffff_...` 前缀)。我们会在 QEMU 里 `cat /proc/self/maps`,贴回 BusyBox 进程真实的段布局——尤其要看 Text 的 `r-xp`、Heap 的 `rw-p` 和 `[heap]` 标注、Stack 在最高地址带 `[stack]`、以及用户空间上限如何对应本篇第四节的 `TASK_SIZE`。

每行五列:起止地址、权限(`r/w/x/p`,`p`=私有、`s`=共享)、文件内偏移、设备号/inode、映射来源(文件路径或 `[heap]`/`[stack]`/`[anon:...]`)。把它从上到下读一遍,就等于把这个进程整张 VAS 地图从头走了一遍——第二节的那些抽象段,在这里全是活生生的数据行。

## 动手试试

> 这一篇概念为主,动手侧重"观察"——用现成的 `/proc` 接口把抽象布局验成具体数据。example 骨架(读 `current->mm` 的极简模块)随亲测补到 `example/mini/`。

1. QEMU 启动后,在 BusyBox shell 里 `cat /proc/self/maps`,对照本篇第二节从低到高把每一段认出来:空指针陷阱页(最低地址不可访问区)、Text(`r-xp`)、Data/BSS(`rw-p`)、`[heap]`、共享库、最高端的 `[stack]`
2. 同样 `cat /proc/self/maps` 里找到栈段,确认它在 VAS 的最高端附近(对照第四节 `TASK_SIZE`),确认堆段地址低于栈段(堆往上、栈往下)
3. 跑一个会递归很深的 BusyBox 命令(或写个简单测试程序),用 `cat /proc/<pid>/status` 里的 `VmStk`(栈大小)观察栈增长
4. 进阶(内核侧):写一个极简模块,`insmod` 时打印 `current->mm->start_code/end_code/start_brk/brk/start_stack`,与 `/proc/self/maps` 的对应字段对拍,验证"`mm_struct` 记的就是这张地图"
5. 思考题:两个 BusyBox 进程 `cat /proc/<pid1>/maps` 和 `/proc/<pid2>/maps`,它们的 Text 段虚拟地址很可能相同——但物理上是同一份吗?结合本篇第一节"共享 Text 段"和第四节"页表隔离"想清楚

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`arch/arm64/include/asm/processor.h:56` 的 `TASK_SIZE_64`、`arch/arm64/include/asm/memory.h:43-51` 的 `VA_BITS`/`PAGE_OFFSET`/`MODULES_VADDR`/`VMEMMAP_START` 是 ARM64 地址空间布局的根;`include/linux/mm_types.h` 的 `struct mm_struct` 看内核如何描述一个进程地址空间;`include/linux/sched.h` 里 `task_struct->mm` 字段(约 `:820` 起的定义中)看它怎么挂上去。
- 命令行:`man proc`,重点 `/proc/[pid]/maps`、`/proc/[pid]/status`、`/proc/[pid]/smaps` 三节,是把 VAS 看活的日常工具;`man mmap`、`man brk` 看用户态分配虚拟内存的两个底层入口。
- 关联本站:本篇承接 [10-process-thread-kernel](10-process-thread-kernel.md)——`task_struct` 是"执行流身份证",`mm_struct` 就是它怀里那张"地址地图";VAS 的内核侧细节(线性映射、页表、`struct page`、VMEMMAP)在 mm 藤展开,从 [mm-buddy](../kernel/mm/01-mm-buddy.md) 起步;而栈尺寸、内核栈的紧约束,上一篇第六节已结合 ARM64 `THREAD_SIZE` 讲过。
