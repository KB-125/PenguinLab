---
title: '给内核模块装上"旋钮":module_param 与运行时调参'
prerequisites:
  - kernel-module-hello
  - kernel-module-9p-iteration
next:
  - process-thread-kernel
difficulty: beginner
tags: [kernel-module, module-param, sysfs, modinfo, qemu, arm64]
architectures: [arm64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch05.md
maturity: drafting
related:
  - /tutorials/foundations/07-kernel-module-hello
---

## 做什么

上一篇我们写 `hello.ko` 的时候，所有行为都是写死的——`pr_info` 的内容固定、加载就干这一件事、卸载就干那一件事。可真实世界里的驱动几乎不可能这么玩:网卡的调试日志要不要开、声卡的默认音量给多少、某个缓冲区分配几页、这块怪硬件的基地址到底是 `0x4000_0000` 还是 `0x4000_8000`……这些值如果全都硬编码进代码,那每改一个数字都得重新 `make` 一遍、重新 `insmod` 一遍,遇到调参调到第十八次的场景,人是要疯的。

所以内核给了我们一套体面的办法:让模块像普通程序接命令行参数一样,在 `insmod` 的时候接收一批 `名字=值` 的键值对,甚至加载完之后还能通过 `sysfs` 在运行时动态改——不用卸载、不用重编。这套机制的核心就是一个看起来平平无奇的宏:`module_param`。这篇我们就把它连同它身后那一整条"参数怎么从命令行跑到内核内存里"的链路彻底拆透,并且——和前两篇一样——所有现象都按 QEMU ARM64 + BusyBox 的实际环境来讲,只是这一篇里的命令输出我们还来不及在板子上亲手跑过,会明确标注成"待亲测",等我们坐到 QEMU 前验过再升级成锤炼版。

## 要了解什么

### 一、先想清楚:模块没有 main(),参数是怎么"进来"的

在用户空间,`main(int argc, char **argv)` 天然带着参数,shell 负责把命令行塞进去。可内核模块压根没有 `main`——它的入口是 `module_init` 注册的那个函数,签名固定、内核来调,根本没有地方让你接 `argc/argv`。那 `insmod modparams.ko mp_debug_level=2` 这句里的 `mp_debug_level=2` 到底是怎么跑到模块代码里的?

答案是一个相当巧妙的**链接器 trick**。我们分两步配合内核完成这件事:

第一步,把想暴露成参数的变量声明成一个**全局的 `static` 变量**。比如 `static int mp_debug_level;`,它就老老实实躺在模块的数据段里,有个确定的内存地址。

第二步,用 `module_param()` 宏把这个变量"登记"一下。这个宏在编译期展开后,会在模块的 ELF 里专门辟出一个叫 `__param` 的段,里面记录三件事——这个参数叫什么名字、它是什么类型、它的变量地址在哪。等到 `insmod` 的时候,内核加载器会去读这个段,拿到用户在命令行上传的 `mp_debug_level=2`,把字符串 `"2"` 解析成整数 `2`,然后**直接写到那个变量的地址上去**。

所以我们后来在 `init` 函数里读 `mp_debug_level`,读到的就已经是被内核改过的值了。本质上,**模块参数就是内核在加载你时,替你改了几个全局变量的初始值**——只不过它把这件事做得规整:有名字、有类型、有权限,还顺手在 `sysfs` 里开了个口子让你运行时再改。

> 这套机制的官方位置在 `include/linux/moduleparam.h`(Linux 6.19)。`module_param` 的定义在 `include/linux/moduleparam.h:134`,它最终会落到 `module_param_cb` 的登记逻辑里(`:183`)。下文所有内核源码引用都用 `文件:行号` 的纯文本写法,指向本仓库 `third_party/linux/` 下检出的 6.19.9 源码树。

### 二、`module_param` 的三个参数,一个都不能讲错

宏的签名很简单,就三个参数:

```c
module_param(name, type, perm);
```

可这三个参数每一个都有讲究,我们挨个拆。

**`name`——变量名**。就是你上面声明的那个全局 `static` 变量的名字,`module_param(mp_debug_level, ...)` 里的 `mp_debug_level` 得和 `static int mp_debug_level;` 严格对得上,写错一个字母链接期不会报错,但内核加载时就找不到对应地址了。

**`type`——数据类型**。不是随便写的,只能是内核预先认识的那几种。我们把 6.19 源码里 `param_ops_*` 的定义挨个翻出来,确认了这套内置类型清单(都定义在 `include/linux/moduleparam.h` 的 `:435`–`:503` 区间):

| 类型关键字 | 对应 C 类型 | 说明 |
|:---|:---|:---|
| `byte` | `u8` / `char` | 一个字节 |
| `short` / `ushort` | `short` / `unsigned short` | |
| `int` / `uint` | `int` / `unsigned int` | 最常用 |
| `long` / `ulong` | `long` / `unsigned long` | |
| `bool` | `bool` | 接受 `0/1`、`y/n`、`Y/N` |
| `invbool` | `bool` | 逻辑反转,传 `n` 反而为真(`:500`) |
| `charp` | `char *` | 字符串指针,内核会替你 `kstrdup` 一份 |

其中最容易让新手卡住的是字符串——传字符串要写 `charp`(`char pointer` 的缩写),不是 `char *` 也不是 `string`。内核见到 `charp` 之后,会把命令行上 `=` 后面那段字符串单独分配一份内存、把地址塞给你的指针,所以你拿到的永远是一个合法的、以 `\0` 结尾的字符串。

**`perm`——权限位**。这是三个参数里概念最"反直觉"的一个,也是新手最容易踩坑的地方。它**不是**"这个参数对谁可见"那么简单,而是**这个参数要不要在 `sysfs` 里建一个对应的文件、建出来的文件是什么权限**。具体地说,只要 `perm` 非 0,内核就会在 `/sys/module/<模块名>/parameters/<参数名>` 这个路径下创建一个文件,文件权限就是你给的 `perm`(八进制,比如 `0660` 表示 owner 和 group 可读写);如果 `perm` 给 0,那这个参数就只在 `insmod` 时能传一次,加载完之后用户空间完全看不见、也改不了。

内核社区有个偏好值得我们记一下:`perm` 直接写八进制数字 `0660`、`0644`,而不是写 `S_IRUSR | S_IWUSR | ...` 这种宏的或运算。理由很实际——`scripts/checkpatch.pl` 看见你用宏写法会甩一个警告,嫌它啰嗦。所以老老实实写数字,既短又不会挨骂。

> ⚠️ **perm 的坑预警**
> 别下意识地把 `perm` 写成 `0777`。参数文件不需要执行位,写 `0777` 不仅没意义,`checkpatch` 还会唠叨你。常用的就是 `0644`(所有人可读、owner 可写)和 `0660`(owner/group 可读写)。另外,真正要"运行时能改"的参数才给非零 `perm`;那种"只在加载瞬间决定、之后绝不能动"的参数(比如硬件基地址),给 `0` 才对,建出来一个能随便 echo 的文件反而危险。

### 三、把 hello 改造成带参数的模块

道理讲完了,上手写。我们就把上一篇的 `hello.c` 改一改,加两个参数:一个 `int` 型的调试级别,一个 `charp` 型的字符串。新建一个 `modparams.c`:

```c
#include <linux/init.h>
#include <linux/module.h>
#include <linux/printk.h>

/* ===== 两个模块参数 ===== */
static int mp_debug_level = 0;                       /* 默认 0:不打调试日志 */
module_param(mp_debug_level, int, 0660);
MODULE_PARM_DESC(mp_debug_level, "debug level [0-2]; 0 => quiet, 2 => verbose");

static char *mp_strparam = "default";                /* 默认值会随模块一起编进 .ko */
module_param(mp_strparam, charp, 0660);
MODULE_PARM_DESC(mp_strparam, "a demo string parameter");

static int __init modparams_init(void)
{
    pr_info("loaded: mp_debug_level=%d mp_strparam=%s\n",
            mp_debug_level, mp_strparam);

    /* 调试级别 >= 2 时走详细分支 */
    if (mp_debug_level >= 2)
        pr_info("verbose: entering init, doing the heavy work...\n");

    return 0;
}

static void __exit modparams_exit(void)
{
    pr_info("unloaded: mp_strparam was '%s'\n", mp_strparam);
}

module_init(modparams_init);
module_exit(modparams_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab");
MODULE_DESCRIPTION("a module_param demo");
```

我们把这段和 `hello.c` 逐行对比一下,看清楚改了什么。两个 `module_param` 是新加的,它们各自上面的 `static int` / `static char *` 就是"被登记的变量"——注意这里特意给了默认值(`= 0` 和 `= "default"`),这个默认值会被编译进 `.ko`,如果用户 `insmod` 时不传这个参数,变量就保持默认值;只有用户显式传了 `mp_debug_level=2`,内核才会去覆盖它。`init` 函数里只是把两个变量的当前值打出来——这一刻它们已经是"被内核改过之后"的值了。

紧跟在每个 `module_param` 后面的 `MODULE_PARM_DESC` 是给"人"看的信息,它把参数描述也塞进 `.ko` 的元数据,用户用 `modinfo` 就能查到——这是我们下一节要验的事,先记住它和 `module_param` 总是成对出现。

`pr_debug` 这里我们故意没用,而是用了 `pr_info`。原因是 `pr_debug` 默认根本不输出——上一篇 debug-printk 那条线我们会专门讲,这里先把一个直觉留下:`pr_debug` 要么得开 `CONFIG_DYNAMIC_DEBUG`,要么得在编译时 `#define DEBUG`,否则你哪怕把 `mp_debug_level` 传成 10 它也一声不吭。所以现阶段我们用 `pr_info` 保证输出一定看得见,把"动态调试"留给它的主场去讲。

Makefile 跟 `hello` 一模一样,只把目标名换掉就行,这里不重复贴了——`obj-m += modparams.o` 加 `include ../../common/Makefile.arch`,具体可以照着 [example/mini/00-kernel_module_hello/Makefile](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/example/mini/00-kernel_module_hello/Makefile) 抄。

### 四、modinfo:参数也是模块元数据

编译完拿到 `modparams.ko`,在加载之前我们先用 `modinfo` 把它的"身份证"看一眼。`modinfo` 加 `-p` 只看参数:

```bash
$ modinfo -p modparams.ko
parm:           mp_debug_level:debug level [0-2]; 0 => quiet, 2 => verbose (int)
parm:           mp_strparam:a demo string parameter (charp)
```

> ⚠️ **待亲测**:上面这段 `modinfo` 输出是按 6.19 的格式预期整理的,我们在宿主机上交叉编译后、塞进 QEMU 之前会实际跑一遍 `modinfo modparams.ko`,把真实输出贴回来。

看,`MODULE_PARM_DESC` 写的描述、`module_param` 第二个参数的类型,`modinfo` 全给你列出来了,末尾括号里还标了类型(`(int)` / `(charp)`)。这件事的实用价值在于:你拿到一个别人写的 `.ko`,不用扒源码,一条 `modinfo -p` 就能知道它接受哪些参数、分别是什么类型、默认行为是什么。BusyBox 里也带了精简版的 `modinfo`,QEMU 里同样能用。

### 五、加载与传参:看内核替你改了变量

接下来是真正的验证时刻。我们先按默认值加载一次,再卸了带参数加载一次,对比 `dmesg` 的输出。

```bash
# 第一次:不传任何参数,走默认值
~ # insmod modparams.ko
~ # dmesg | tail -2
[   12.340123] modparams: loaded: mp_debug_level=0 mp_strparam=default

~ # rmmod modparams
```

`mp_debug_level=0 mp_strparam=default`——这俩正是我们在代码里写的默认值,说明用户没传时变量就老老实实保持默认。接着我们传参再试:

```bash
# 第二次:带上参数
~ # insmod modparams.ko mp_debug_level=2 mp_strparam=hello
~ # dmesg | tail -2
[   25.118864] modparams: loaded: mp_debug_level=2 mp_strparam=hello
[   25.118901] modparams: verbose: entering init, doing the heavy work...

~ # rmmod modparams
~ # dmesg | tail -1
[   31.402215] modparams: unloaded: mp_strparam was 'hello'
```

> ⚠️ **待亲测**:上面三段串口日志是按"代码逻辑应当产生"的预期输出整理的,不是真实跑出来的。我们会拿到 QEMU ARM64 + 6.19.9 上 `insmod`/`rmmod` 一遍,把真实的 `dmesg` 时间戳和文本贴回——尤其要确认 BusyBox 的 `insmod` 对 `name=value` 参数的解析、以及 `charp` 带空格字符串的引号转义行为。

注意第二次 `mp_debug_level` 变成了 `2`,于是 `init` 里那个 `>= 2` 的分支被走进去了,多打了一行 `verbose:`;`mp_strparam` 也变成了我们传的 `hello`,连 `exit` 函数里都能读到它。这就是"内核在加载你时,替你改了全局变量"这件事在现象上的样子——代码里我们什么 `sscanf`、什么 `argv` 解析都没写,值就这么对上了,全靠 `module_param` 在 `__param` 段里登记的元数据和加载器的配合。

### 六、运行时调参:sysfs 的口子

如果故事到 `insmod` 就结束,那模块参数顶多算个"高级一点的命令行参数"。真正让它威力翻倍的是第三参数 `perm` 的那一层含义——只要 `perm` 非 0,加载完之后这个参数会在 `sysfs` 里活生生地建出一个文件,我们可以**在模块运行期间随时读、随时写**,不用 `rmmod`、不用重编。

我们给的两个参数都是 `0660`,所以它们会出现在这里:

```bash
~ # ls -l /sys/module/modparams/parameters/
-rw-rw----    1 0     0         4096 Jan  1 00:00 mp_debug_level
-rw-rw----    1 0     0         4096 Jan  1 00:00 mp_strparam
```

权限正好对上 `0660`(`-rw-rw----`)。读它就是 `cat`,写它就是 `echo`(注意 BusyBox 里重定向到这种 root 拥有的文件,`echo 1 > file` 一般够用,真遇到权限问题再用 `sh -c`):

```bash
# 读当前值
~ # cat /sys/module/modparams/parameters/mp_debug_level
2

# 运行时改它——内存里的变量立刻被改
~ # echo 0 > /sys/module/modparams/parameters/mp_debug_level
~ # cat /sys/module/modparams/parameters/mp_debug_level
0
```

这件事的震撼之处在于:**你写进 `/sys/module/.../parameters/mp_debug_level` 的那个 `0`,真的就把模块代码里 `mp_debug_level` 那个全局变量的值改成 0 了**。下一次模块里任何读到 `mp_debug_level` 的地方,看到的都是新值。这意味着我们可以拿一个用户态脚本、甚至一行 `echo`,去实时控制内核模块的行为——开/关调试日志、调缓冲区大小、切换工作模式,全程不重启、不重载。

不过得提醒一句:`sysfs` 改参直接动内存变量,**模块代码不会收到任何"我被改了"的通知**。如果你需要"参数被改时做点事"(比如重新初始化某块硬件、重新分配缓冲区),那就不能光靠 `module_param`,得用带回调的 `module_param_cb`,我们把它的例子放在进阶那一节。

### 七、进阶四件套:`_named`、`_cb`、必传参数、`_hw`

基础款讲完了,日常驱动里还会常碰到四个进阶用法,我们一并过一下,免得将来读到别人代码时发懵。

**改名:`module_param_named`**。有时候内部变量名为了表意清楚取得很长(比如某个分配器的 `dm_bufio_current_allocated`),但你不想让用户 `insmod` 时也敲这么长一串。`module_param_named` 允许"对外暴露一个友好名字、内部仍指向那个长名变量":

```c
static int dm_bufio_current_allocated;
module_param_named(current_allocated_bytes,   /* 对外名字 */
                  dm_bufio_current_allocated, /* 内部变量 */
                  int, 0644);
```

这样用户写 `insmod dm-bufio.ko current_allocated_bytes=4096`,内核照样改的是 `dm_bufio_current_allocated`。普通 `module_param(name, ...)` 其实就是 `module_param_named(name, name, ...)` 的特例——对内外同名的简写。

**带回调:`module_param_cb`**。前面说过普通 `module_param` 改值时模块毫无察觉。如果你需要在"参数被设置"的那一刻执行一段代码(做校验、触发动作),就用 `module_param_cb` 挂一组 `kernel_param_ops` 回调进去,它的 `set`/`get` 函数会在每次读写时被调用。实际上前面那几个宏最终都落到 `module_param_cb`(`include/linux/moduleparam.h:183`),只是默认帮你填了 `param_ops_int`、`param_ops_charp` 这些现成的 ops。需要自定义校验逻辑时,你就自己实现一组 ops 传进来。

**必传参数**。内核没有"声明某个参数为必传"的原生语法,但有个通用套路:在 `init` 函数里手动检查值,不合法就返回负错误码,内核会据此中止加载:

```c
static int control_freak = 0;
module_param(control_freak, int, 0644);

static int __init my_init(void)
{
    if (control_freak < 1 || control_freak > 5) {
        pr_warn("control_freak must be in [1,5]!\n");
        return -EINVAL;          /* 返回负值 → insmod 失败,模块被踢出 */
    }
    return 0;
}
```

`-EINVAL` 是内核约定的"参数非法"错误码,`insmod` 会收到 `Invalid argument` 的报错。把这种校验放 `init` 里,既实现了"必传",也顺带做了"取值范围"的约束。

**硬件参数:`module_param_hw`**(`include/linux/moduleparam.h:580`)。涉及 I/O 端口、内存地址、IRQ 号这类"敏感硬件参数"时,用这个专门的宏。它多一个 `hwtype` 参数,标记这个值是哪种硬件资源,配合 Secure Boot 等安全机制,把这类参数锁得更紧——在开启了模块签名强校验的系统上,普通 `module_param` 和 `module_param_hw` 的待遇是不一样的。

### 八、一个必须讲清楚的环境差异:我们这是 initramfs

读到这里你可能注意到了一个绕不开的问题:原始素材(那本基于 x86_64 Ubuntu + 树莓派的书)在"自动加载模块"那一节,讲了一整套 `modules_install` + `depmod` + `/etc/modprobe.d/xxx.conf` 里写 `options modparams mp_debug_level=2` 的玩法。可我们的 QEMU 是 BusyBox + initramfs 启动,这套东西**大多用不上**,得分辨清楚:

- **`insmod ko param=value`**:BusyBox 的 `insmod` 支持参数传递,这条在我们环境里能用,前面几节的演示就靠它。
- **`/sys/module/<mod>/parameters/`**:这是内核本身提供的,跟用什么用户态无关,BusyBox 的 `cat`/`echo` 照样能读写。
- **`/etc/modprobe.d/xxx.conf` 里 `options`**:这是 `modprobe`(kmod)在**加载时**去读的配置,把参数预先填好。BusyBox initramfs 里通常没有 `modprobe.d` 这套机制,我们用 `insmod` 直接传参绕开。
- **`modules_install` + `depmod` + 开机自动加载**:那是完整发行版(systemd + `/etc/modules-load.d/`)的活,initramfs 是只读快照、开机也不走那套 init,所以这篇不展开,等真要部署到带持久根文件系统的环境时再补。

换句话说,**我们这套 QEMU 环境验证模块参数,主打"`insmod` 直传 + `sysfs` 运行时改"这两条**;`modprobe`/自动加载那套留给生产部署场景。这个差异不是缺陷,是环境定位不同,讲清楚就不纠结了。

## 动手试试

> 这一篇的 example 骨架会随亲测一起落到 `example/mini/`(参考 `00-kernel_module_hello/` 的结构:源文件 + `Makefile` include `../../common/Makefile.arch`)。下面的清单是我们坐到 QEMU 前要逐条验的。

1. 在 `example/mini/` 下建 `modparams/`,写本篇第三节的 `modparams.c` 和 `Makefile`,`make` 出 `modparams.ko`
2. 宿主机先 `modinfo -p modparams.ko`,确认 `mp_debug_level` / `mp_strparam` 两个参数及其描述、类型正确(对照第四节)
3. 把 `.ko` 塞进 rootfs(或走 9p 共享),`insmod modparams.ko`,`dmesg` 确认默认值 `mp_debug_level=0 mp_strparam=default`
4. `rmmod` 后 `insmod modparams.ko mp_debug_level=2 mp_strparam=hello`,确认 `dmesg` 输出的值被覆盖、`verbose` 分支走进去了
5. `ls -l /sys/module/modparams/parameters/`,确认两个文件权限是 `0660`;`cat` 读、`echo 0 >` 改,再 `cat` 确认运行时改值生效
6. 进阶验证:把 `module_param(..., 0660)` 改成 `(..., 0)` 重编加载,确认 `/sys/module/.../parameters/` 下不再出现该参数文件(只留 `perm` 非 0 的那些)
7. 把 `perm` 从八进制 `0660` 改成宏写法 `S_IRUSR|S_IWUSR|S_IRGRP|S_IWGRP`,跑一遍内核源码树里的 `scripts/checkpatch.pl`,观察它对权限宏的警告(体会"内核偏好八进制"这条规矩)

## 延伸阅读

- 源码:`include/linux/moduleparam.h`(Linux 6.19),`module_param` 全家宏的定义与 `param_ops_*` 内置类型清单;`kernel/params.c` 是参数注册与 `sysfs` 接口的实现。
- kernel.org:[Driver Basics](https://docs.kernel.org/driver-api/basics.html) 官方文档,覆盖 `module_init`/`module_exit`、模块引用计数(`try_module_get`/`module_put`)等驱动侧基础 API;[Kernel module signing facility](https://docs.kernel.org/admin-guide/module-signing.html) 讲模块签名与 `CONFIG_MODULE_SIG_FORCE`,对应本篇第七节 `module_param_hw` 在 Secure Boot 下的那层含义。
- 命令行层:宿主机 `man modprobe`、`man modinfo`、`man insmod`(kmod 套件),讲 `options` 配置、依赖解析、参数传递的用户态侧。
- 关联本站:`pr_debug` 与 `CONFIG_DYNAMIC_DEBUG` 的故事放在 [debug-printk](../debugging/01-debug-printk.md) 那一篇,本篇刻意只用 `pr_info` 就是为了不在它的主场抢戏;模块的 `__param` 段、`modinfo` 元数据等 ELF 细节,可以回看 [07-kernel-module-hello](07-kernel-module-hello.md) 里讲 `.modinfo` 段和 `MODULE_*` 宏的那一节。
