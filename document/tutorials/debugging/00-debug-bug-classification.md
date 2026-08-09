---
title: "调试先认路:Bug 分类与工具全景图"
slug: debug-bug-classification
prerequisites:
  - kernel-module-hello
next:
  - debug-printk
difficulty: beginner
tags: [debugging, bug-classification, methodology, toolmap, lockdep, kasan]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_debugging/ch02_2.md
  - notes: document/notes/linux_kernel_debugging/ch02_3.md
maturity: drafting
related:
  - /tutorials/debugging/01-debug-printk
  - /tutorials/debugging/03-debug-kasan
  - /tutorials/debugging/05-debug-oops
  - /tutorials/debugging/06-debug-ftrace
  - /tutorials/debugging/07-debug-kcsan
  - /tutorials/debugging/09-debug-kgdb
---

> 🔨 **整理中** · 这一篇是调试藤的**序章/导航图**——不教某个具体工具,而是先把"Bug 有哪几类、每类该用哪个工具"这张地图讲清楚,再把我们这藤已有的 9 篇工具教程(printk/oops/kprobes/ftrace/kasan/slub/kgdb/kcsan/panic)标到地图上,让你读任何一篇都不迷路。素材从读书笔记 ch02 的 bug 分类与调试方法论整理;具体的 CONFIG 选项以 6.19 为准,但绝大多数工具的"选型逻辑"是版本无关的。

## 做什么

很多人一上来要"调试内核",第一反应就是抓起 `printk` 一通乱加,或者急着上 KGDB。说实话,这么干经常事倍功半,甚至越调越糊涂。原始素材里有一句反直觉但很扎心的话:**大多数调试失败,不是因为工具不好用,而是因为在一开始就误判了 Bug 的性质**——用治感冒的办法去治骨折,只会把病人折腾得更惨。内核这种去中心化、并发运行、还没有安全网的系统里,误判的代价尤其大:你盯着一个像是竞态的现象加了一堆日志,结果真正的元凶是块坏内存条;你以为是逻辑错误想单步调试,结果系统早已被 OOM 拖垮。

所以这一篇我们不上手任何具体工具,而是退一步,先把两件事讲清楚:**Bug 按性质能分成哪几类**,以及**面对每一类、每一个调试阶段,我们手里有哪些武器**。读完它,你脑子里会有一张"对症下药"的速查表,再配合本藤各篇具体的工具教程,就不会出现"系统都 panic 了才想起加 printk"(太晚了,系统停摆了)或"生产环境想上 KGDB"(会暂停整个业务)这种错配。

## 要了解什么

### 一、Bug 分类:四个视角看同一只虫子

同一个 Bug,从不同视角看会显出不同的样子,我们用四个视角轮流看一遍,这样面对真实故障时能快速"挂号"。

**经典视角(教科书分类)** 把 Bug 按出错机理拆开:逻辑或实现错误(差一、死循环、算术精度丢失/溢出/除零)、语法缺陷(`=` 写成 `==` 这种,现代编译器多数能警告)、资源泄漏与通用缺陷(这是 C 的重灾区——NULL 指针解引用、未初始化读取 UMR、内存泄漏、双重释放、释放后重用 UAF、越界 OOB,另外别忘了硬件故障这层——坏内存条、DMA 发疯、数据对齐问题都伪装成软件 bug)、竞态条件(数据竞争、死锁/活锁、中断风暴)、性能缺陷(对齐导致缓存低效、API 选错导致内部碎片、I/O 瓶颈)。

**内存视角** 把内存当 X 光片——几乎所有灾难性的 C 语言 Bug 最终都表现为内存损坏,所以这一视角特别有用:错误的内存访问(UMR/越界/UAF/双重释放,这些在 C 标准里统统属于**未定义行为 UB**——一旦触发,程序"做什么都是对的",用户态给你个 segfault,内核态就是 panic)、内存泄漏(注意**泄漏 ≠ 碎片**:泄漏是借了不还的 bug,碎片是分配机制的副作用,内部碎片是分配单元大于需求、外部碎片是空隙太多凑不出大块)、数据竞争(本质上也是内存一致性 bug)。

**安全视角** 把 Bug 看成漏洞:这里有两个安全报告里必出现的缩写——**CVE**(通用漏洞披露,每个公开漏洞的唯一编号,好比"病历号")和 **CWE**(通用弱点枚举,对漏洞**类型**的分类,好比"病种名称")。很多听起来很高大上的攻击,拆到底就是一个我们写代码时犯的低级内存错误——比如栈溢出攻击对应 **CWE-120**,本质就是"经典视角"里说的缓冲区上溢,攻击者精心构造输入越过数组边界、覆盖栈上返回地址劫持执行流。所以别把安全问题想得太神秘,它们就是被别有用心的人利用的低级错误。

**内核视角** 回到我们写 Linux 驱动时的现实,Sergio Prado 把内核 Bug 归结为五类:导致死锁或系统挂起的缺陷(系统还在但没反应了,调度器停了或某个自旋锁死循环)、导致崩溃或 panic 的缺陷(最严重,内核主动停机)、逻辑或实现缺陷(功能不正常但没搞挂系统)、资源泄漏缺陷(内存慢悠悠地漏直到 OOM Killer 出来杀人)、性能问题(能用但慢)。

> 💡 **为什么要分这么细**
> 你不用背完每一类,但要建立"先挂号、再开药"的反射。看到现象先在脑子里过一遍这四个视角:"这是内存踩坏了?还是锁死了?还是单纯慢?"——挂号挂对了,下一步选工具就是顺水推舟;挂错了,后面所有努力都在南辕北辙。

### 二、调试四阶段:同一个工具,不同阶段是两种命运

光知道 Bug 类型还不够,还得看你**处于哪个阶段**——同一个工具在开发阶段是利器、到了生产环境可能就是事故。原始素材把内核生命周期划成四个调试阶段,每个阶段的"可用工具集"差异极大。

**第一阶段:开发阶段——上帝视角**。你在自己的开发板或虚拟机上写代码,随时能让它崩、随时重启,追求的是**可见性**。这时最原始的代码级插装(`printk`/`pr_debug`/动态调试/`dump_stack`/`BUG_ON`/`WARN_ON`)往往最有效;想设断点、单步、看改变量,可以上 **KGDB**(代价是触发断点时整个内核暂停、网络丢包、watchdog 可能咬人,所以**仅限开发阶段**)。

**第二阶段:测试与 QA——自动化体检**。代码要交给用户前,靠自动化工具把隐患尽可能挖出来。这一层的主力是**动态分析**:内存检查器 **KASAN**(越界/UAF/双重释放,代价是显著拖慢、内存翻倍)、未定义行为检查器 **UBSAN**(整数溢出、错误位移)、锁调试器 **Lockdep**(动态追踪锁依赖,抓死锁和潜在死锁);加上**静态分析**(Sparse 查用户/内核指针混用、Coccinelle 跑语义补丁)和**覆盖率分析**(Gcov/Lcov,确认测试跑到了多少代码)。

**第三阶段:生产与运行时——只看不摸**。系统在跑线上业务,首要原则是**不要停业务**,所以 KGDB 这种暂停系统的手段一律禁用,需要的是**非侵入式**监控:追踪基础设施 **Ftrace**(函数调用图/耗时)、**Perf**(热点/缓存命中/上下文切换)、**eBPF**(在内核里跑沙盒程序,监控网络/文件/系统调用)、**Kprobes**(在代码里动态埋"地雷",jprobe 拦入口、kretprobe 拦返回);再加 **softlockup/hardlockup 检测**(CPU 卡在内核循环里就报警)、**Magic SysRq**(`Alt+SysRq+命令`,系统假死时的最后手段,`t` 看任务、`p` 看寄存器、`c` 强制 crash 配合 kdump)。

**第四阶段:事后分析——尸检报告**。系统已经崩了重启,你只剩一个 `vmcore` 转储(或一张屏幕照片)。这时像法医一样做尸检:**Oops 分析**(对着 Oops 文本里的 IP/寄存器/栈回溯定位源码行)、**Kdump 生成 + Crash 工具分析**(`bt` 看崩溃栈、`ps` 看当时进程、`kmem` 看内存结构,服务器标配但嵌入式因内存受限可能用不起)、以及最基础的 **`dmesg`/日志回顾**(疑难杂症的最后线索常在 dmesg 末尾几行)。

### 三、工具选择矩阵:Bug 类型 × 对症工具(挂上本藤教程)

把前两节合成一张速查表,并把我们这藤**已有的工具教程**标进去——这样你查到某类 Bug,能直接跳到对应的那一篇深入。这张表是本篇的核心产出,值得存下来:

| Bug 类型 | 首选工具 | 次选工具 | 本藤深入教程 |
|:---|:---|:---|:---|
| **逻辑/实现错误** | `printk`/KGDB | 动态调试 | [01 printk](./01-debug-printk) · [09 KGDB](./09-debug-kgdb) · [动态调试](./10-debug-dynamic-debug) |
| **内存破坏(越界/UAF/双重释放)** | **KASAN** | SLUB debug | [03 KASAN](./03-debug-kasan) · [04 SLUB debug](./04-debug-slub) |
| **内存泄漏** | Kmemleak | KASAN | (Kmemleak 待铺) |
| **释放后空指针/致命访问现场** | Oops 解析 | — | [05 Oops 分析](./05-debug-oops) |
| **死锁/锁相关问题** | **Lockdep** | Crash 堆栈分析 | (Lockdep 待铺) · [08 Panic/挂起](./08-debug-panic) |
| **并发/数据竞争** | **KCSAN** | Lockdep/Kprobes | [07 KCSAN](./07-debug-kcsan) · [02 Kprobes](./02-debug-kprobes) |
| **性能问题/热点** | **Perf**/Ftrace | trace-cmd | [06 Ftrace](./06-debug-ftrace) · (Perf/trace-cmd 待铺) |
| **崩溃转储事后分析** | Kdump + Crash | Oops 文本 | [08 Panic](./08-debug-panic) · [09 KGDB](./09-debug-kgdb) |
| **函数调用追踪/动态埋点** | Ftrace/Kprobes | eBPF | [06 Ftrace](./06-debug-ftrace) · [02 Kprobes](./02-debug-kprobes) |

> 🔧 **标"待铺"的格子**
> 表里标"待铺"的几样(Kmemleak、Lockdep、Perf、trace-cmd、eBPF)在本藤还没有专门教程,它们对应的 layer-4 节点(`debug-lockdep`/`debug-perf`/`debug-ebpf`/`debug-trace-cmd` 等)仍是规划中。这一篇先把它们在地图上标出位置,后续逐个铺开时回填链接。

### 四、硬件与软件的博弈:工具选型还得看"家底"

选工具不能光看功能,还得看你这套环境的家底允不允许,这在嵌入式上尤其要命。**硬件约束**方面:Kdump 要预留一段内存,64MB 的嵌入式路由器上奢侈不起;KASAN 内存占用翻倍,内存紧张的板子开了可能直接 OOM;KGDB 要串口或网口,封闭设备根本没把口露出来。**软件约束**方面:你的 `.config` 为了性能和体积可能关掉了一堆调试选项——`CONFIG_KPROBES` 没开就用不了 kprobes,`CONFIG_KASAN` 没开 KASAN 就不存在,`CONFIG_DEBUG_INFO` 没开连 Crash 工具都看不了符号。静态分析(Sparse/Coccinelle)是少数不耗运行时资源的,只要编译时间。

> ⚠️ **QEMU + BusyBox 这套环境的约束**
> 我们这套学习环境(ARM64 QEMU + BusyBox initramfs)内存可配、调试选项可控,正好是"开发阶段"的理想沙盒——KASAN/KCSAN/KGDB/Ftrace 这些都能在 menuconfig 里开起来验证。但它毕竟不是生产系统:`systemd-cgtop`、`journalctl`、生产级的 eBPF 工具链(BCC/bpftrace)在这里大多用不上。所以本藤各篇的"动手试试"都以"`insmod` 触发 + `dmesg`/`/proc`/`/sys/kernel/debug` 观察"为主,生产场景的工具组合(Perf 采样、eBPF 监控)点到为止、标注清楚。

### 五、业余和专业的一条分界线

最后把这一篇的立意收一下。业余选手看到系统卡了,只会重启,或者盲目地加一堆 `printk`;专业选手看到系统卡了,脑子里会迅速过一遍这张全景图——是死锁吗(Lockdep 开了吗)?是内存踩了吗(KASAN 能复现吗)?还是单纯性能问题(上 Perf 看热点)?**工具本身只是招式,对场景的判断才是内功**。这一篇给的正是练这门内功的底子:分类 Bug、分类调试阶段、记牢对症矩阵。有了它,后面读本藤任何一篇具体工具教程,你都知道这把武器在整张地图上的位置、该什么时候拔出来。

## 动手试试

> 这一篇的"动手"偏认知建立,不像具体工具篇那样跑命令。建议这样用:

1. 把第三节那张"Bug 类型 × 工具"矩阵存下来(或抄到工位边),遇到真实故障时先按现象"挂号",再查表选工具
2. 翻一遍你这台开发机的 `.config`(本仓库 `configs/arm64-qemu-virt-learn.config`),对照第二节四个阶段的工具清单,看哪些 CONFIG_XXX 已经开、哪些还没开——这直接决定你当前环境能拔出哪些武器
3. 选一个本藤已有的工具教程(比如 [01 printk](./01-debug-printk) 或 [05 Oops](./05-debug-oops))读完,回头在本矩阵里找到它的位置,体会"它在哪类 Bug、哪个阶段用"
4. 思考题:线上生产服务器出现偶发卡顿、怀疑死锁,你**不能**用哪些工具(为什么)?**该**优先用哪些?(对照第二节的"生产阶段——只看不摸")

## 延伸阅读

- 读书笔记:本篇整理自 [ch02_2 Bug 类型分类](../../notes/linux_kernel_debugging/ch02_2.md) 与 [ch02_3 调试方法全景图](../../notes/linux_kernel_debugging/ch02_3.md)(含完整的四阶段工具表与对症矩阵原表)。
- 安全数据库:[NVD 国家漏洞数据库](https://nvd.nist.gov/) 查 CVE 详情;[CWE 列表](https://cwe.mitre.org/) 看漏洞类型分类——栈溢出是 CWE-120、UAF 是 CWE-416,把本篇的"内存视角"和安全视角对上号。
- 关联本站:本篇是 debugging 藤的序章,各工具的深入教程从 [01 printk](./01-debug-printk) 起;debugging 藤的节点全景见 `helpers/learning-progress/layer-4.yaml`。
