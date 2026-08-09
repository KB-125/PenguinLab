---
title: "用户态/内核态边界:系统调用与 copy_to_user"
slug: user-kernel-boundary
prerequisites:
  - process-thread-kernel
  - virtual-address-space
next: []
difficulty: beginner
tags: [user-kernel, syscall, copy_to_user, uaccess, access_ok, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - notes: document/notes/linux_kernel_programming/ch04.md
  - source: third_party/linux（6.19）include/linux/uaccess.h、include/linux/syscalls.h、arch/arm64/kernel/syscall.c
maturity: drafting
related:
  - /tutorials/foundations/10-process-thread-kernel
  - /tutorials/foundations/11-virtual-address-space
  - /tutorials/drivers/01-drv-chardev
---

> 🔨 **整理中** · 这一篇讲用户态和内核态之间的那道**边界**——特权级为什么划开、系统调用怎么过界、跨界搬数据为什么要用 `copy_to_user`/`copy_from_user` 而不能直接解引用指针。素材从读书笔记 ch04 §4.1(用户/内核空间)+ 6.19 源码整理。动手部分在 QEMU 亲手验过之前标"待亲测"。它是 [10 进程线程](./10-process-thread-kernel.md) 里"单内核:进程自己切入内核"那条的展开。

## 做什么

[进程线程](./10-process-thread-kernel.md) 那篇我们说"进程发起系统调用时,是它自己切入了内核模式"——可"切入内核模式"这件事具体怎么发生?切过去之后,用户态传进来的指针(比如 `read(fd, buf, n)` 的 `buf`)内核能不能直接读?为什么写驱动时到处是 `copy_from_user`/`copy_to_user`、不能直接 `memcpy`?这些问题的答案都在"用户态/内核态边界"这条线上。这一篇我们把这条线彻底讲清:特权级为什么分、系统调用怎么过界、跨界数据搬运的规矩。理解它,你写驱动时给用户态回数据就不会再犯"直接解引用用户指针"这种致命错误。

## 要了解什么

### 一、特权级边界:EL0 与 EL1,两个世界

现代 CPU 支持多个特权级,ARM64 叫 Exception Level(EL):**EL0 是用户态**(普通程序跑的地方,非特权)、**EL1 是内核态**(内核跑的地方,特权)。这道边界是硬件强制的——EL0 的代码不能直接访问内核内存、不能执行特权指令(SWITCH MMU 寄存器、关中断等),违者触发异常。[虚拟地址空间](./11-virtual-address-space.md) 那篇讲的 VAS 上半段(用户空间)和下半段(内核空间)的划分,就是这条特权级边界在地址上的投影:EL0 只能寻址用户空间那半段、EL1 两半都能寻址。

这条边界的意义是**隔离与安全**:用户程序崩了只死自己一个进程,内核崩了整个系统挂;用户程序不能直接窥探/篡改内核和其他进程的内存。所有"用户想用内核能力"(读文件、开设备、fork 进程)的请求,都必须走合法的"门"。

### 二、系统调用:唯一的合法入口

那道门就是**系统调用(system call)**。用户态的 `open`/`read`/`write`/`ioctl` 这些库函数,本质都是对系统调用的封装。机制上,用户态执行一条特殊指令(ARM64 是 `SVC #0`,x86 是 `SYSCALL`),触发同步异常,CPU 从 EL0 切到 EL1、跳到内核预定义的异常向量入口。内核在那里:

1. 保存用户态的寄存器现场(以便事后切回去)。
2. 从寄存器里取出**系统调用号**(用户态把它放在某个约定寄存器,ARM64 是 `x8`)和**参数**(放在 `x0`~`x5`)。
3. 用系统调用号查 `sys_call_table`(一张函数指针表),调对应的内核实现。
4. 完成后恢复用户态现场、切回 EL0,把返回值交给用户态。

内核侧定义一个系统调用,用 **`SYSCALL_DEFINE<n>(name, args...)`** 宏(`include/linux/syscalls.h`,如 `SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)`)。注意参数里那个 `__user *`——它标记"这是个用户态指针",编译器(sparse)会拿它做静态检查,提醒你"这指针不能直接解引用、必须走 uaccess"。下一节讲为什么。

### 三、`copy_to_user`/`copy_from_user`:跨界搬数据的规矩

系统调用的参数经常带"用户态 buffer 指针"(`read` 的 `buf`、`write` 的 `buf`、`ioctl` 的 argp)。内核要读写这块 buffer,绝不能直接 `*p` 或 `memcpy`——必须用 `copy_from_user`/`copy_to_user`(`include/linux/uaccess.h`):

```c
unsigned long copy_to_user(void __user *to, const void *from, unsigned long n);
unsigned long copy_from_user(void *to, const void __user *from, unsigned long n);
```

为什么不能直接解引用?两个硬理由。**第一,这个指针可能不合法**——用户程序可能传一个野指针、或一个根本没映射的地址,内核直接 `*p` 会触发内核态缺页,严重时把内核搞崩;`copy_*_user` 内部用了专门的"缺页能安全恢复"的实现(把 page fault 当作"拷贝失败"处理、而不是 panic)。**第二,即使指针落在用户空间范围,跨边界拷贝也要走专用路径**——它先用 `access_ok` 检查"指针确实指向用户空间、且权限对"(防欺骗),再用底层 `raw_copy_*_user` 拷贝,出错时返回"还剩多少没拷"(而非直接崩)。

返回值是"**未能拷贝的字节数**"——0 表示全部成功,非 0 表示部分失败(用户 buffer 部分无效),驱动这时该返回 `-EFAULT`(`-14`)告诉用户态"指针错了"。这条"检查 `copy_*_user` 返回值、失败返 `-EFAULT`"的纪律,是写驱动时的高频检查点——忘了它,一个野指针用户 buffer 就可能让驱动行为诡异。

### 四、`__user` 标记与 sparse 检查

那个 `__user *` 是 sparse 静态分析工具的注解。开了 sparse 检查(`make C=1`),它会校验"你是不是在内核代码里直接解引用了一个 `__user` 指针"——这是 bug。`__user` 指针必须先经过 `copy_*_user`/`get_user`/`put_user` 这些 uaccess 接口才能访问。养成看 `__user` 就条件反射走 uaccess 的习惯,能避免一大类安全漏洞(内核直接信任并解引用用户指针,是经典提权路径)。

### 五、约束:uaccess 必须在进程上下文

最后记一条约束:`copy_*_user` 这种"访问用户态内存"的操作,**只能在进程上下文做**——因为"用户态指针"得有"当前进程"才有意义(它的页表才有这块地址的映射)。中断上下文没有 `current`、或内核线程 `current->mm` 为 NULL,这时候用户指针根本翻译不出来。所以驱动里凡是中断处理函数(ISR)里看到"用用户指针"的设计都是错的——数据得先在进程上下文拷进内核、再交给中断路径用。这条和 [10 进程线程](./10-process-thread-kernel.md) 里"中断上下文不能睡、`current` 不可靠"是一组约束。

## 动手试试

1. `strace cat /etc/hosts`(宿主机上)看 `read`/`write`/`open` 系统调用的实际调用序列,直观看到"用户态过界到内核态"的入口
2. 读 [01 chardev](../drivers/01-drv-chardev.md) 驱动里 `copy_to_user`/`copy_from_user` 的用法,确认每次调用都检查了返回值、失败返 `-EFAULT`
3. 故意在用户态传一个野指针给某个驱动的 `write`(如把 `buf` 设成 `(char *)0xdeadbeef`),观察内核返回 `-EFAULT`(`Invalid argument` 之类),体会"uaccess 安全网"
4. 进阶:用 `make C=1` 跑 sparse 检查一个驱动,看它怎么报告 `__user` 指针的解引用问题
5. 思考题:为什么 `copy_from_user` 不能在中断处理函数里调?(结合本篇第五节 + [10 进程线程](./10-process-thread-kernel.md) 的中断上下文约束)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/uaccess.h`(`copy_to_user`/`copy_from_user`/`access_ok` 及文档注释)、`include/linux/syscalls.h`(`SYSCALL_DEFINE*` 宏);ARM64 系统调用入口在 `arch/arm64/kernel/entry.S`(SVC 异常向量)和 `arch/arm64/kernel/syscall.c`(`el0_svc`→`invoke_syscall`→`sys_call_table`);`sys_call_table` 在 `arch/arm64/kernel/sys.c`。
- 关联本站:本篇是 [10 进程线程](./10-process-thread-kernel.md) "单内核:进程自己切入内核"的展开;VAS 上下半段的划分在 [11 虚拟地址空间](./11-virtual-address-space.md);`copy_*_user` 的实战用法在 [01 chardev](../drivers/01-drv-chardev.md) 和 [02 ioctl](../drivers/02-drv-ioctl.md)。
- 读书笔记:[ch04 §4.1](../../notes/linux_kernel_programming/ch04.md) 讲用户/内核空间与系统调用的设计动机。
