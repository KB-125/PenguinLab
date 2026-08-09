---
title: "Dynamic Debug:运行时开关任何 pr_debug,还几乎零开销"
slug: debug-dynamic-debug
prerequisites:
  - debug-printk
  - kernel-module-params
next:
  - debug-ftrace
difficulty: intermediate
tags: [debugging, dynamic-debug, pr_debug, dev_dbg, debugfs, dyndbg, static_key]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_debugging/ch03_4.md
maturity: drafting
related:
  - /tutorials/debugging/01-debug-printk
  - /tutorials/debugging/00-debug-bug-classification
  - /tutorials/foundations/09-kernel-module-params
---

> 🔨 **整理中** · 这一篇专讲内核的动态调试设施(Dynamic Debug / dyndbg)——运行时随手开关任何一句 `pr_debug()`/`dev_dbg()`,不用重编、不用重启,而且关闭时几乎零开销。素材从读书笔记 ch03_4 整理,所有 flags、`struct _ddebug`、control 文件都对照本仓库 `third_party/linux/` 的 6.19.9 校订过;尤其校出一处笔记(基于 5.10)没覆盖的:6.19 的 flag 位比当年多了 `s`(源文件名)和 `T`(栈)。control 文件的命令输出在 QEMU 亲手验过之前标"待亲测"。

## 做什么

还记得我们在 [模块参数](../foundations/09-kernel-module-params.md) 那篇里,特意把示例代码的日志全用 `pr_info` 而不是 `pr_debug` 吗?当时留了句"pr_debug 留给 dynamic-debug 主场去讲"——现在就是那个主场。`pr_debug()` 这个宏有个让人又爱又恨的脾气:**默认它什么都不输出**。你得么在编译时 `#define DEBUG`、要么开 `CONFIG_DYNAMIC_DEBUG`,否则它就是一句沉默的空操作。这个设计不是为了折腾人,而是为了让"调试打印"在生产代码里也能安心常驻——平时不开销、要查的时候随时唤得醒。

可"编译时开关"本身很笨重:线上跑着的内核发现某个驱动有 bug,你想看看它的 `pr_debug` 输出,难道要重新编译、重启?那业务早凉了。这一篇要讲的 **Dynamic Debug(dyndbg)** 就是解决这个矛盾的——它让你在**运行时**精准地开关内核里**任意一句** `pr_debug()`(还有 `dev_dbg()` 等),按文件、按函数、按行号、按格式字符串去"狙击",开关的代价还几乎为零。读完这一篇,你就从"拿着 printk 到处乱敲的维修工"升级成"带着精密探针、不停机就能透视内核的工程师"。

## 要了解什么

### 一、前奏:模块参数方案,以及它为什么不够用

在 dyndbg 普及之前,内核开发者最常用的运行时调试开关就是我们在 [模块参数](../foundations/09-kernel-module-params.md) 里讲的那招——声明一个 `debug` 参数,代码里到处 `if (debug) pr_debug(...)`。经典的 i8042 键盘控制器驱动就这么干(`drivers/input/serio/i8042.c`):

```c
static bool i8042_debug;
module_param_named(debug, i8042_debug, bool, 0600);
```

加载后操作 `/sys/module/i8042/parameters/debug` 就能动态开关,看着挺完美。但这招有个致命缺点——**性能开销**:哪怕 `debug=0`(关),CPU 每次跑到那个 `if` 还是得做一次判断。如果这个函数一秒被调一百万次(内核里很常见),你就做了一百万次无效判断;而且代码会被 `if (debug > x)` 这种语句弄得又丑又难维护。我们想要的是"**像模块参数那样动态开关、关闭时却零开销**"——这正是 dyndbg 被称为"大杀器"的原因。

### 二、dyndbg 的哲学:不是加 if,是改代码本身

dyndbg 的设计哲学和模块参数完全不同:**它不在代码里加 `if`,而是直接修改代码的执行路径**。底层的招数是内核的**静态分支(static key / jump label)**机制——这和 ftrace 动态追踪用的是同一套"动态代码修补"手艺。简单说,每一条 dyndbg 管得到的 `pr_debug()` 调用点,内核都给它配了一个"静态分支";分支关闭时,内核把那条机器指令直接修补成 `NOP`(或跳过),CPU 跑过去几乎不要钱;分支打开时,再把它修补回真正的打印调用。开关是改几条指令,运行时开销近乎为零。

这套机制的物理载体是 `struct _ddebug`(`include/linux/dynamic_debug.h:16`)——内核里**每一个** dyndbg 管得到的打印点,都对应一个 `_ddebug` 实例,记录这个点的全部身份信息:

```c
struct _ddebug {
    const char *modname;       /* 所属模块名 */
    const char *function;      /* 所在函数名 */
    const char *filename;      /* 源文件路径 */
    const char *format;        /* 格式字符串 */
    unsigned int lineno:18;    /* 行号 */
    unsigned int class_id:CLS_BITS;  /* 分类(6.x 引入的 class 概念) */
    unsigned int flags:8;      /* 当前的 flag 状态(开/关 + 各种前缀) */
    ...
    struct static_key_true  dd_key_true;   /* ← 静态分支:零开销开关的秘密 */
    struct static_key_false dd_key_false;
};
```

末尾那对 `static_key_true`/`static_key_false` 就是上一段说的"静态分支"——它们让"这个打印点开没开"这个判断,从"每次都要读内存变量"变成"编译进指令流、可被运行时修补",这就是零开销的根。所有这些 `_ddebug` 实例在编译期被收集进一个特殊的 ELF 段,运行时 dyndbg 拿着这个表去按查询条件批量改 flags、改静态分支。

### 三、前提:CONFIG_DYNAMIC_DEBUG,以及它管哪些宏

要用上 dyndbg,内核配置里得开 `CONFIG_DYNAMIC_DEBUG`(`lib/Kconfig.debug:108`)。发行版内核一般都开了;我们这种自己裁剪的学习内核,得在 menuconfig 里手动打开。开了它会让内核镜像略大一点(约 2%);要是你对体积极其敏感,可以只开核心 `CONFIG_DYNAMIC_DEBUG_CORE`(`:180`),再在需要的模块 Makefile 里加 `ccflags-y += -DDYNAMIC_DEBUG_MODULE`,按需启用。

dyndbg 管的不是一个 `pr_debug`,而是**所有走 dyndbg 机制的打印宏**:`pr_debug()`、`dev_dbg()`、`print_hex_dump_debug()`、`print_hex_dump_bytes()`。关键在于"`pr_debug` 在开 `CONFIG_DYNAMIC_DEBUG` 时展开成什么"——看 6.19 的定义(`include/linux/printk.h:635`):

```c
#define pr_debug(fmt, ...) \
    dynamic_pr_debug(fmt, ##__VA_ARGS__)
```

开了 dyndbg,`pr_debug` 就展开成 `dynamic_pr_debug()`,后者会找到这个调用点对应的 `struct _ddebug`、按它当前的 flags 决定打不打;没开 dyndbg 时,`pr_debug` 在非 DEBUG 情况下展开成空操作(`(void)0` 那类),连 `_ddebug` 表都不生成。所以同一份源码,开不开 dyndbg 是两套完全不同的展开。

### 四、控制台:control 文件,以及它出现在哪

dyndbg 的"控制面板"是一个虚拟文件,内容是内核里**所有** dyndbg 打印点的清单(一个调试内核里动辄几千行)。它创建在 `lib/dynamic_debug.c:1396`:`debugfs_create_file("control", 0644, ...)`。根据配置,实际路径有两个可能:

- **挂了 debugfs**:`/sys/kernel/debug/dynamic_debug/control`(调试内核的默认情况)
- **禁了 debugfs**(生产加固:`CONFIG_DEBUG_FS_DISALLOW_MOUNT`):控制文件"降落"到 procfs,变成 `/proc/dynamic_debug/control`

判断法是 `mount | grep debugfs`——有输出就用 debugfs 那条,没输出就用 procfs 那条,功能完全一样。control 文件每一行长这样,表头标得很明白:

```text
# filename:lineno [module]function flags format
drivers/powercap/intel_rapl_msr.c:151 [intel_rapl_msr]rapl_msr_probe =_ "failed to register powercap control_type.\012"
```

五个字段依次是:**源文件:行号**、**[模块名]**(内置核心代码可能没方括号)、**函数名**、**flags**(`=_` 是关键,见下节)、**格式字符串**(`\012` 是 `\n` 的八进制)。拿着这一行,你能直接跳到源码对应行核对,真正做到"控制文件里列出的每一个点,都对应源码里一句真实的 `pr_debug`"。

### 五、flags:开关 + 前缀增强(对照 6.19 校订)

第四个字段 `flags` 是 dyndbg 最核心的控制旋钮,它决定这个打印点"开不开",以及"开了的话额外带哪些前缀信息"。我们把它在 6.19 里的定义(`include/linux/dynamic_debug.h:34-41`)和字符对照拉出来:

```c
#define _DPRINTK_FLAGS_NONE         0           /* 默认:_ 啥也不干 */
#define _DPRINTK_FLAGS_PRINT        (1<<0)      /* p:真正打开打印 */
#define _DPRINTK_FLAGS_INCL_MODNAME (1<<1)      /* m:前缀含模块名 */
#define _DPRINTK_FLAGS_INCL_FUNCNAME (1<<2)     /* f:前缀含函数名 */
#define _DPRINTK_FLAGS_INCL_LINENO  (1<<3)      /* l:前缀含行号 */
#define _DPRINTK_FLAGS_INCL_TID     (1<<4)      /* t:前缀含线程/进程 ID */
#define _DPRINTK_FLAGS_INCL_SOURCENAME (1<<5)   /* s:前缀含源文件名(6.19) */
#define _DPRINTK_FLAGS_INCL_STACK   (1<<6)      /* T:前缀含栈回溯(6.19) */
```

> ⚠️ **校订:6.19 比老资料多两个 flag**
> 笔记(基于 5.10)只列了 `p/m/f/l/t/_` 六个。对照 6.19 源码,`_DPRINTK_FLAGS_INCL_SOURCENAME`(`s`,源文件名)和 `_DPRINTK_FLAGS_INCL_STACK`(`T`,打印调用栈)是后来加的——尤其 `T` 在调试"是谁触发了这条日志"时非常管用,直接把栈打出来。读到这一节,记住 flag 清单以 6.19 为准。

操作 flags 用三个运算符:**`=`** 设置(覆盖)、**`+`** 添加、**`-`** 移除。从默认 `=_` 出发,几个例子:`+p` → `=p`(打开);再 `+t` → `=pt`(打开并显示 TID);`-p` → `=t`(显示 TID 但不打印——没意义,只是说明语法);`=pflmt` → 直接设成"打开并显示函数/行/模块/TID"。注意 `p` 是"真打印"的总开关,没有 `p` 其它 flag 都不生效。

### 六、match spec:精准狙击要改哪些点

光会改 flags 还不够,你得告诉 dyndbg **改哪些打印点**——这就是 match spec。它是一组关键字,关键字之间是**与(AND)**关系,层层收紧匹配范围:

| 关键字 | 示例 | 匹配什么 |
|:---|:---|:---|
| `module` | `module miscdrv` | 模块名(支持 `*` 通配) |
| `file` | `file drivers/tty/*` | 源文件路径 |
| `func` | `func usb_submit_urb` | 函数名(支持通配) |
| `line` | `line 100-150` | 行号范围 |
| `format` | `format "DMA:"` | 格式字符串含特定子串 |

组合起来,就像对内核代码做数据库查询。下面这句只打开 `snd` 模块里、函数名含 `ctl`、且行号在 600 之前的打印点:

```bash
echo -n "module snd func *ctl* line 1-600 +p" > /sys/kernel/debug/dynamic_debug/control
```

整个命令格式就是 `echo -n "<match-spec> <flags>" > <control-file>`——先匹配、再改 flag。

### 七、实战:在运行中的内核上让沉默的 dev_dbg 显形

把前几节缝起来,走一遍经典流程。场景:一个 `miscdrv_rdwr` 驱动编译时**没定义 `DEBUG`**,跑在生产内核上,它的 `dev_dbg` 全部沉默。现在出了 bug,要看它的调试日志,又不能重编重启。

```bash
# 1. 确认 control 文件路径(debugfs 没挂就用 /proc/dynamic_debug/control)
# mount | grep -w debugfs

# 2. insmod 后,先看这个模块在 control 文件里有哪些打印点(都处于 =_ 关)
# insmod miscdrv_rdwr.ko
# grep miscdrv_rdwr /proc/dynamic_debug/control | head -n1
.../miscdrv_rdwr.c:303 [miscdrv_rdwr]miscdrv_rdwr_init =_ "A sample print via the dev_dbg(): driver initialized\012"

# 3. 打开它:把该模块所有点的 flag 加上 p
# echo -n "module miscdrv_rdwr +p" > /proc/dynamic_debug/control

# 4. 再看,=_ 变成了 =p
# grep miscdrv_rdwr /proc/dynamic_debug/control | head -n1
.../miscdrv_rdwr.c:303 [miscdrv_rdwr]miscdrv_rdwr_init =p "A sample print via the dev_dbg(): driver initialized\012"

# 5. 操作设备,沉默的 dev_dbg 现在全部涌出来
# echo "test" > /dev/llkd_miscdrv_rdwr
# dmesg | tail
```

> ⚠️ **待亲测**:上面这个流程我们在 QEMU ARM64 上要照着跑一遍——给一个学习模块写几句 `dev_dbg`、编译时不定义 `DEBUG`、`insmod` 后用 control 文件开关,把真实 `dmesg` 输出贴回。尤其要验证 6.19 新增的 `T`(栈)flag 效果。

想看是哪个进程在操作设备,加 `t` flag;想要栈,加 `T`(6.19 新增):

```bash
# 关掉,换成 p + t(显示 TID)+ m(显示模块名)
# echo -n "module miscdrv_rdwr +ptm" > /proc/dynamic_debug/control
```

这种"运行时、不停机、按需点亮"的能力,在调试多线程竞态、偶发故障时是救命级别的——尤其 `t` 能让你看到每条日志是哪个 PID 触发的,`T` 能让你看到调用栈。

### 八、开机就调试:boot 参数与 modprobe.d

dyndbg 不只能给 `insmod` 后的模块用,内置模块和内核核心代码也能管。但启动阶段(比如 initcall)发生在你能敲 `echo` 之前,得换个时机下达指令:

- **内核 cmdline**(调试内置代码/核心):在启动参数里加 `dyndbg="file drivers/usb/* +pflmt"`,内核启动时就按这句打开匹配的打印点。
- **modprobe.d**(调试可加载模块的初始化):在 `/etc/modprobe.d/mydriver.conf` 写 `options mydriver dyndbg=+pmflt`,每次 `modprobe` 时自动开;或直接 cmdline 里 `mydriver.dyndbg="..."`。

顺带记几个和启动调试相关的 cmdline 神器:`initcall_debug`(打印每个 initcall 的执行时间和返回值,启动卡住时能定位卡在哪个 initcall)、`ignore_loglevel`(无视 loglevel 把所有消息刷到控制台)、`debug`(开全部内核调试消息,小心洪水)。

### 九、零开销的代价,以及 Lockdown 的拦路

最后补两个工程上的现实。第一,dyndbg 的"零开销"是**关闭时**的;一旦某个点被 `+p` 打开,它每次执行就会真正走一遍 `printk`,这时的开销和普通 `printk` 一样(甚至带 `t`/`T` 前缀时更高)。所以调试完记得 `-p` 关回去,别在生产上长期开着高频路径的打印点。

第二,生产内核若开了 **Kernel Lockdown**(`CONFIG_LOCK_DOWN_KERNEL`,常见于开了 Secure Boot 的系统),可能会拦住模块加载或 dyndbg 操作——Lockdown 的本意就是连 root 都不许加载未签名模块、改内核内存。系统管理员要在启动时临时放开,得在 bootloader(GRUB)的 `linux` 行末尾加 `lockdown=none` 启动一次。⚠️ 这会降低安全性,调完务必改回来。

## 动手试试

> example 随亲测补到 `example/mini/`:写一个带几句 `dev_dbg` 的小模块(编译时不定义 `DEBUG`)。

1. menuconfig 开启 `CONFIG_DYNAMIC_DEBUG`(本仓库学习 config 默认可能没开),重编内核进 QEMU
2. `mount | grep debugfs` 判断 control 文件路径;`wc -l` 看它列了多少个打印点,`head` 看格式(`filename:lineno [module]function flags format`)
3. `insmod` 一个带 `dev_dbg` 的模块,先确认它的打印点是 `=_`(沉默);`echo "..." > /dev/xxx` 触发,确认 `dmesg` 没有 dev_dbg 输出
4. `echo -n "module <你的模块> +p" > .../control`,grep 同一行确认 `=_` 变 `=p`;再次触发设备,确认 dev_dbg 输出涌出
5. 玩 flag 组合:`+ptm`(显示 TID/模块名)、`+T`(6.19 栈回溯),观察 `dmesg` 前缀变化;最后 `-p` 关回
6. 玩 match spec:`func <某函数> +p` 只开一个函数的打印点;`line 100-150 +p` 开一个行号范围
7. 思考题:对比 [模块参数](../foundations/09-kernel-module-params.md) 的 `if (debug) pr_debug(...)` 方案,dyndbg 在"关闭时开销"和"控制粒度"上各赢在哪?(提示:static_key 修补指令 vs 每次 if 判断;整模块/函数/行号 vs 一个全局变量)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/dynamic_debug.h:16` 的 `struct _ddebug`、`:34-41` 的 `_DPRINTK_FLAGS_*` flag 位定义(p/m/f/l/t/**s**/**T**);`lib/dynamic_debug.c:175 ddebug_change`(核心修改)、`:538 ddebug_exec_query`、`:571 ddebug_exec_queries`(查询执行)、`:858 dynamic_emit_prefix`(前缀生成)、`:1396` control 文件创建;`include/linux/printk.h:635` 看 `pr_debug` 如何在开 dyndbg 时展开成 `dynamic_pr_debug`;`lib/Kconfig.debug:108/180` 的 `CONFIG_DYNAMIC_DEBUG`/`_CORE`。
- kernel.org:[Dynamic Debug How-To](https://docs.kernel.org/admin-guide/dynamic-debug-howto.html) 是 dyndbg 的官方手册,涵盖全部 match spec 语法与 flags;`Documentation/admin-guide/dynamic-debug-howto.rst` 是其源文档。
- 关联本站:本篇的 `pr_debug`/"日志级别"底座在 [01 printk](./01-debug-printk);"按 bug 类型选 dyndbg 还是别的工具"看 [00 调试工具全景图](./00-debug-bug-classification);dyndbg 的"前奏"模块参数方案在 [09 模块参数](../foundations/09-kernel-module-params.md);dyndbg 底层用的"动态代码修补"和 ftrace 是同源,延伸到 [06 Ftrace](./06-debug-ftrace)。
- 命令行:`man dyndbg` 较少发行版提供,主要看上面那个 kernel.org howto;boot 参数 `dyndbg=`/`initcall_debug`/`ignore_loglevel` 见 `Documentation/admin-guide/kernel-parameters.txt`。
