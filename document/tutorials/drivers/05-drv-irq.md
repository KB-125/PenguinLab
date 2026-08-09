---
title: "硬件中断:设备怎么打断 CPU——从 IRQ 线电信号到你的 ISR"
slug: drv-irq
prerequisites:
  - /tutorials/foundations/07-kernel-module-hello
next:
  - /tutorials/drivers/12-drv-threaded-irq
difficulty: intermediate
tags: [driver, interrupt, irq, irqchip, gic, bcm2835, arm64]
architectures: [arm64, arm32, x86_64, riscv]
kernel_version: "6.19"
sources:
  - source: third_party/linux（6.19）kernel/irq/、include/linux/interrupt.h、include/linux/irq.h、drivers/irqchip/irq-bcm2835.c
  - notes: document/notes/linux_kernel_device_drivers/ch04.md
maturity: drafting
related:
  - /tutorials/drivers/12-drv-threaded-irq
  - /tutorials/drivers/11-drv-dts
---

> 🔨 **整理中** · 这一篇拆硬件中断子系统:先讲清**中断控制器这套硬件**(外设怎么靠一根 IRQ 线电信号把 CPU 打断、控制器里的 pending/enable/mask/ack 寄存器各自管什么、边沿和电平触发为什么差出一整个"中断风暴"的坑),再分两层读 framework——消费侧的 `request_irq` 怎么把你的 handler 挂上(`kernel/irq/manage.c`),控制器侧的 irqchip 驱动怎么把硬件中断号翻译成 Linux IRQ 号(`kernel/irq/chip.c` + `irqdomain.c`)。然后拿树莓派 BCM2835 的中断控制器驱动 `irq-bcm2835.c`(265 行,开头就甩出三条硬件 quirk,真实得不讲武德)逐段走读,最后把"外设拉线 → CPU 跳异常 → 你的 ISR 被调"这条链从头追到硬件,每一步都钉在源码行号上。动手部分给出 QEMU virt(GIC)和宿主 `/proc/interrupts` 的观察路径。

## 做什么

写用户态程序时,CPU 仿佛永远在老老实实跑我们的代码。其实它每执行完一条指令,硬件都会偷偷瞄一眼中断引脚——一旦有信号,立刻保存现场、跳进内核预设的入口。这股"最高优先级"的力量,就是硬件中断。**它解决的核心矛盾是:CPU 不能去轮询每个外设(那会浪费 99% 的算力),又必须在外设有事(网卡收到包、按键被按下、定时器到期)的瞬间做出响应。** 中断就是外设主动喊 CPU 一嗓子"我有事,放下手头的活过来看一下"。

这一篇我们把中断这条链路拆到底:先弄懂**中断控制器这块硬件**长什么样(所有 API 的根),再读内核 IRQ framework 怎么把"控制器 + 一堆外设 + 一堆驱动 handler"组织起来,最后走读 BCM2835 的 irqchip 驱动——看一个真实中断控制器驱动要填什么、要躲什么坑。线程化中断(`request_threaded_irq`,让 ISR 能睡眠)是本主题的进阶,单开一篇 [12 drv-threaded-irq](./12-drv-threaded-irq.md) 讲透,这里只在最后点一下。

## 要了解什么

### 〇、硬件背景:中断控制器——IRQ 线、寄存器、触发电气

理解 IRQ 子系统的所有 API,得先懂它的硬件。这套 API 的每一个回调、每一个标志位,都对应硬件的一条特性。

**中断是怎么打断 CPU 的——先记这条物理路径**:

1. **外设拉线**:网卡收到一个包,在它连接到中断控制器的物理线上拉高(或拉低)电压。
2. **中断控制器汇总**:x86 上是 IO-APIC,ARM 上是 GIC(General Interrupt Controller),BCM2835 上是自家的 ARMCTRL-IC——统称 PIC(Programmable Interrupt Controller,可编程中断控制器)。它把信号暂存进**pending(待处理)寄存器**,再拉高通往 CPU 的中断引脚。
3. **CPU 捕获**:CPU 检测到中断引脚信号,**硬件自动**保存当前 PC/寄存器现场、跳进异常向量入口(ARM64 上是 `handle_arch_irq`,见后文)。CPU 不知道"网卡""键盘"是什么,它只知道"第 24 号中断线触发了"——这个号叫 **IRQ(Interrupt ReQuest)**,是硬件中断的身份证号。
4. **内核分发**:内核拿到 IRQ 号,查中断描述符里这个号挂的处理函数,逐个调用。
5. **驱动 ISR 执行**:我们注册的处理函数被叫醒。

**中断控制器这块硬件长什么样**——它本质上是一组寄存器,内核靠读写这些寄存器来"管理"中断。以 BCM2835 的 ARMCTRL-IC 为例(`drivers/irqchip/irq-bcm2835.c:69-71`):

```c
static const int reg_pending[] __initconst = { 0x00, 0x04, 0x08 };   /* pending:谁在请求 */
static const int reg_enable[]  __initconst = { 0x18, 0x10, 0x14 };   /* enable:写 1 允许 */
static const int reg_disable[] __initconst = { 0x24, 0x1c, 0x20 };   /* disable:写 1 屏蔽 */
```

一组典型的中断控制器寄存器(每条 IRQ 线都对应里面的若干 bit):

- **pending(待处理)**:硬件置位——某条 IRQ 线有信号了,对应 bit 被硬件写成 1,告诉"这条线有事"。CPU 读取它就知道是谁请求的。
- **enable/disable(使能)**:软件开关——写 enable 寄存器对应 bit 允许这条线产生中断,写 disable 寄存器屏蔽它。这是"软件能不能临时掐断某条线"的硬件基础。
- **ack(确认)/eoi(End Of Interrupt)**:告诉控制器"这条中断我处理了/接手了"。**电平触发**中断里 ack 尤其关键——后面讲。

**触发方式的电气特性(直接决定一个坑)**:

- **边沿触发(edge)**:IRQ 线电平**跳变**(低→高叫上升沿,高→低叫下降沿)的瞬间触发一次。硬件记下"有一次跳变"就完事,之后电平稳住不再触发。省心,但高负载时两次跳变挨太近可能被合并、漏一次。
- **电平触发(level)**:IRQ 线电平**持续**为高(或低)就一直触发。问题是:如果 ISR 跑完、控制器的 pending 位还亮着(外设那边电平还没撤),中断控制器会**立刻再触发一次**——这就是"中断风暴"(interrupt storm),CPU 被同一个中断反复打断、用户态根本跑不动。**解法是 ISR 里必须 ack——要么把控制器 pending 位清掉,要么去外设寄存器把信号源关掉(比如读掉 UART 的数据,接收缓冲空了 RX 电平自然回低)。** 这正是 `handle_level_irq` 要在调你的 handler 前 `mask_ack_irq` 的硬件动机(见第四节数据流)。

**BCM2835 这块控制器有个真实得不讲武德的细节**——驱动文件开头 30 多行注释甩出**三条硬件 quirk**(`irq-bcm2835.c:6-36`),都是芯片设计留下的毛病,驱动只能捏着鼻子兜底:

- **Quirk 1**(shortcut 中断不设 bank1/2 pending 位):某些 bank1 中断有"快捷通道"直连 bank0,触发时只置 bank0 的 shortcut bit、不置 bank1 pending 位。
- **Quirk 2**(bank1/2 的 pending 中断**不能 mask**):正常级联控制器下游能 mask,BCM2835 不行——只能在外设源头处理。
- **Quirk 3**(shortcut 中断不能在 bank0 mask):得去各自 bank 的 enable/disable 寄存器里操作,bank0 的没效果。

这三条不是软件能改的——是芯片设计如此,驱动写法被迫跟着绕。后面走读时我们会看到代码具体怎么处理它们。换到 GIC(APIC 也一样),寄存器布局、quirk 完全不同,但"pending/enable/mask/ack 这套寄存器 + 边沿/电平两种触发"的本质一样。

**所以内核需要这套 API——每条都追到硬件**:

- `irq_chip`(`include/linux/irq.h:492`)里的 `irq_mask`/`irq_unmask`/`irq_ack`/`irq_eoi`/`irq_set_type` 回调,每一个就是"操作控制器那组寄存器里的一个"——`mask` 写 disable 寄存器、`unmask` 写 enable 寄存器、`ack` 清 pending 位、`set_type` 配边沿/电平。控制器侧 irqchip 驱动填它。
- `irq_domain`(`include/linux/irqdomain.h:168`):**硬件中断号(hwirq)→ Linux IRQ 号(virq)的翻译层**。为什么需要它?因为不同控制器的中断号编号方式天差地别(BCM2835 用"bank + index"编码,GIC 用一个线性号,MSI 用消息),内核要对消费侧驱动呈现统一的"Linux IRQ 号",就得有一层翻译。irqchip 驱动建 domain 提供翻译。
- `request_irq`(消费侧):外设驱动用它把自己的 handler 挂到某个 Linux IRQ 号上。中断触发时,framework 顺着这个号找到 handler 调用它。

不讲清这套硬件,后面看到 `request_irq(irq, handler, IRQF_TRIGGER_FALLING, ...)` 里的 `IRQF_TRIGGER_FALLING` 就只是个魔数;讲清了,你才知道它对应"配控制器的某条线为下降沿触发"这条硬件动作。

### 一、framework 全景:两层 API + 三个核心文件

IRQ 子系统核心代码在 `kernel/irq/`,分两层(对应两类驱动):

**消费侧——外设驱动用的 API**(`kernel/irq/manage.c`,~2700 行):外设驱动只调这层,把 handler 挂到 IRQ 号上。入口是 `request_threaded_irq`(`manage.c:2100`):

```c
int request_threaded_irq(unsigned int irq, irq_handler_t handler,
                         irq_handler_t thread_fn, unsigned long irqflags,
                         const char *devname, void *dev_id);   /* kernel/irq/manage.c:2100 */
```

我们更熟的 `request_irq`(`include/linux/interrupt.h:173`)只是它的薄包装——`thread_fn` 填 `NULL`,自动补一个 `IRQF_COND_ONESHOT` 标志,原样转发:

```c
static inline int __must_check
request_irq(unsigned int irq, irq_handler_t handler, unsigned long flags,
            const char *name, void *dev)
{
    return request_threaded_irq(irq, handler, NULL, flags | IRQF_COND_ONESHOT,
                                name, dev);   /* include/linux/interrupt.h:176 */
}
```

注意 `irq_handler_t` 是个函数指针类型(`include/linux/interrupt.h:104`):`typedef irqreturn_t (*irq_handler_t)(int, void *);`——你的 ISR 就是这个签名。`request_threaded_irq` 内部 `kzalloc` 一个 `struct irqaction`,把 handler/flags/name/dev_id 塞进去,交给 `__setup_irq`(`manage.c:1460`)挂到 `irq_desc` 的 action 链表上(共享中断的关键,见数据结构节)。

**控制器侧——irqchip 驱动用的 API**(`kernel/irq/chip.c` + `irqdomain.c`):中断控制器自己的驱动(如 `irq-bcm2835.c`)填一个 `struct irq_chip`(操作硬件寄存器的回调表)+ 建一个 `struct irq_domain`(hwirq↔virq 翻译),告诉 framework"我这块控制器长这样、怎么 mask、怎么翻译中断号"。这层我们走读 BCM2835 时细看。

**分发路径**(`kernel/irq/handle.c`):中断真的触发时,从 CPU 异常入口进来,一路调到你的 handler。核心是 `__handle_irq_event_percpu`(`handle.c:185`)——遍历这个 IRQ 号的 action 链,对每个 action 调 `action->handler(irq, dev_id)`(handle.c:208)。这条链是第四节数据流的主干。

**三个锚点**:
1. **注册路径**:消费侧 `request_irq → request_threaded_irq:2100 → __setup_irq:1460`(挂 action);控制器侧 `irq_domain_create_linear` + `irq_set_chip_and_handler`(建 domain + 挂 chip)。
2. **回调边界**:framework 在三处调你的代码——(a) 中断触发时分发调 `action->handler`(你的 ISR);(b) mask/unmask/ack 时调 `irq_chip` 的对应回调(irqchip 驱动写的);(c) `request_threaded_irq` 时若提供 `thread_fn`,建 irq 内核线程跑它(详见 [12](./12-drv-threaded-irq.md))。
3. **对外接口**:`/proc/interrupts`(看每个 IRQ 各 CPU 上的触发计数、控制器名、触发方式、设备名)、`/proc/irq/<N>/smp_affinity`(把某 IRQ 绑到指定 CPU 核,做 IRQ 亲和性)、`/sys/kernel/debug/irq/`(开 `CONFIG_GENERIC_IRQ_DEBUGFS` 后看 irq_desc 内部)。

### 二、核心数据结构:irq_desc / irqaction / irq_data / irq_chip / irq_domain

驱动要打交道的主要是 `irqaction`(消费侧)和 `irq_chip`(控制器侧),但要把整条链讲清,五个结构都得认。

**`struct irqaction`**(`include/linux/interrupt.h:123`)——消费侧:你 `request_irq` 时内核替你造的这个结构,代表"一个驱动对一条 IRQ 线的一次注册":

```c
struct irqaction {            /* include/linux/interrupt.h:123 */
    irq_handler_t       handler;       /* :124 你的 ISR(上半部) */
    void               *dev_id;        /* 私有数据 cookie,中断时原样传回 handler */
    struct irqaction   *next;          /* 链到下一个 action(共享中断的关键) */
    irq_handler_t       thread_fn;     /* :131 线程化下半部(NULL=不线程化) */
    struct task_struct *thread;        /* 线程化时对应的内核线程 */
    unsigned int        irq;
    unsigned int        flags;         /* IRQF_* 标志 */
    const char         *name;          /* /proc/interrupts 里显示的名字 */
    ...
};
```

那个 `next` 指针是共享中断的关键:共享同一根 IRQ 线的多个 action 串成链。当中断触发,内核不知道是哪个设备拉的线,把链上每个 handler 都调一遍——**轮到每个驱动自己读硬件寄存器判断"是不是我的设备"**,不是就返回 `IRQ_NONE`。`dev_id` 在共享时是"摘节点"的唯一凭证(`free_irq` 靠它匹配),所以共享中断(`IRQF_SHARED`)必须给非空 `dev_id`。

**`struct irq_chip`**(`include/linux/irq.h:492`)——控制器侧:irqchip 驱动填的回调表,每个回调操作控制器的一类寄存器:

```c
struct irq_chip {             /* include/linux/irq.h:492 */
    const char  *name;
    void        (*irq_ack)(struct irq_data *data);       /* :499 清 pending/确认 */
    void        (*irq_mask)(struct irq_data *data);      /* :500 屏蔽(写 disable 寄存器) */
    void        (*irq_mask_ack)(struct irq_data *data);  /* :501 mask+ack 一步到位 */
    void        (*irq_unmask)(struct irq_data *data);    /* :502 解蔽(写 enable 寄存器) */
    void        (*irq_eoi)(struct irq_data *data);       /* :503 结束中断(某些控制器用) */
    int         (*irq_set_type)(struct irq_data *data, unsigned int flow_type); /* :507 配边沿/电平 */
    ...
    unsigned long flags;      /* :543 IRQCHIP_* 标志 */
};
```

注意它**不是必须全填**——BCM2835 只填了 `irq_mask`/`irq_unmask` 两个(后面走读看到),`ack`/`eoi` 这些由 flow handler(如 `handle_level_irq`)代为协调。`struct irq_data`(`include/linux/irq.h:177`)是"一条中断线的运行时数据"(当前 hwirq、virq、指向 chip、指向 domain),作为回调参数传进去,驱动从里面拿到 hwirq 知道该操作哪个 bit。

**`struct irq_desc`**(`include/linux/irqdesc.h:67`)——一个 Linux IRQ 号(virq)的完整描述:它的 action 链(谁注册了)、用的 chip、用的 flow handler(handle_level_irq / handle_edge_irq / handle_fasteoi_irq 之一)、状态位。framework 内部用它,消费侧一般不直接碰。

**`struct irq_domain`**(`include/linux/irqdomain.h:168`)——hwirq↔virq 翻译层:irqchip 驱动建它,把"控制器的硬件中断号"映射到"Linux 分配的 IRQ 号"。消费侧 `request_irq` 时给的 `irq` 已经是 virq,domain 在背后翻译到 hwirq 再交给 chip 操作寄存器。

### 三、源码走读:irq-bcm2835.c(BCM2835 中断控制器,265 行)

现在拿一个真实 irqchip 驱动逐段看。`drivers/irqchip/irq-bcm2835.c` 是树莓派(BCM2835/BCM2836)的中断控制器驱动,很短,但把"一个控制器怎么接进 IRQ framework"的全套套路都演了一遍。

**先看私有数据 + irq_chip 填充**(`:79`/`:102`):

```c
/* irq-bcm2835.c:79 — 驱动私有数据:寄存器基址 + 每个 bank 的 pending/enable/disable 指针 + domain */
struct armctrl_ic {
    void __iomem *base;
    void __iomem *pending[NR_BANKS];    /* NR_BANKS = 3 */
    void __iomem *enable[NR_BANKS];
    void __iomem *disable[NR_BANKS];
    struct irq_domain *domain;
};

static struct armctrl_ic intc __read_mostly;   /* :87 全局唯一实例(树莓派只有一个 IC) */

/* :92 — mask 回调:写 disable 寄存器对应 bit */
static void armctrl_mask_irq(struct irq_data *d)
{
    writel_relaxed(HWIRQ_BIT(d->hwirq), intc.disable[HWIRQ_BANK(d->hwirq)]);
}

/* :97 — unmask 回调:写 enable 寄存器对应 bit */
static void armctrl_unmask_irq(struct irq_data *d)
{
    writel_relaxed(HWIRQ_BIT(d->hwirq), intc.enable[HWIRQ_BANK(d->hwirq)]);
}

/* :102 — irq_chip:只填 mask/unmask,极简 */
static struct irq_chip armctrl_chip = {
    .name       = "ARMCTRL-level",
    .irq_mask   = armctrl_mask_irq,
    .irq_unmask = armctrl_unmask_irq,
    .flags      = IRQCHIP_MASK_ON_SUSPEND | IRQCHIP_SKIP_SET_WAKE,
};
```

这套回调就是第一节数据结构里 `irq_chip` 的真实填充:`irq_mask` 写 disable 寄存器、`irq_unmask` 写 enable 寄存器——每一步都对应"操作控制器的那组寄存器"。`HWIRQ_BANK(d->hwirq)`(`:49`=`d->hwirq >> 5`)从 hwirq 取出 bank 号、`HWIRQ_BIT`(`:50`=`BIT(d->hwirq & 0x1f)`)取出 bank 内的 bit——因为 hwirq 是 `MAKE_HWIRQ(b, n) = (b << 5) | n`(`:48`)编码的"bank 占高位、index 占低 5 位"。**注意它没填 `irq_ack`/`irq_eoi`/`irq_set_type`**——BCM2835 这块控制器的中断类型是硬件固定的(电平触发),驱动初始化时统一挂 `handle_level_irq` 这个 flow handler(见下),ack 由 flow handler 协调,所以 chip 本体不用单独提供 ack。`IRQCHIP_SKIP_SET_WAKE`(跳过电源管理唤醒设置)和 `IRQCHIP_MASK_ON_SUSPEND`(挂起时自动 mask 非唤醒中断)是这块控制器的省心配置。

**初始化函数 `armctrl_of_init`**(`:135`,这是把控制器注册进 framework 的核心):

```c
/* irq-bcm2835.c:135(简化,保留关键步骤) */
static int __init armctrl_of_init(struct device_node *node,
                                  struct device_node *parent, bool is_2836)
{
    void __iomem *base = of_iomap(node, 0);                       /* :143 映射寄存器 */

    /* ⭐ 建 irq_domain:把"控制器的硬件中断号"翻译成 Linux IRQ 号 */
    intc.domain = irq_domain_create_linear(of_fwnode_handle(node),
                          MAKE_HWIRQ(NR_BANKS, 0), &armctrl_ops, NULL);  /* :147 */

    for (b = 0; b < NR_BANKS; b++) {
        intc.pending[b] = base + reg_pending[b];                  /* :153 各 bank 寄存器指针 */
        intc.enable[b]  = base + reg_enable[b];
        intc.disable[b] = base + reg_disable[b];

        for (i = 0; i < bank_irqs[b]; i++) {
            irq = irq_create_mapping(intc.domain, MAKE_HWIRQ(b, i)); /* :158 为每条线分配 virq */
            irq_set_chip_and_handler(irq, &armctrl_chip,           /* :160 挂 chip + flow handler */
                                     handle_level_irq);
            irq_set_probe(irq);
        }

        /* ⭐ 检测 bootloader 残留:enable 寄存器非零说明 bootloader 没关干净 */
        reg = readl_relaxed(intc.enable[b]);
        if (reg) {
            writel_relaxed(reg, intc.disable[b]);                  /* :167 强制关掉 */
            pr_err(FW_BUG "Bootloader left irq enabled: ...");      /* :168 打硬件 bug 警告 */
        }
    }

    /* :179 BCM2836(四核):挂成父中断的 chained handler;BCM2835(单核):设成架构级入口 */
    if (is_2836)
        irq_set_chained_handler(irq_of_parse_and_map(node, 0),
                                bcm2836_chained_handle_irq);       /* :186 */
    else
        set_handle_irq(bcm2835_handle_irq);                        /* :188 设 handle_arch_irq */
    return 0;
}
```

每一步都对应 framework 的一个锚点:`irq_domain_create_linear`(:147)建 domain(线性映射,bank+index → virq);`irq_create_mapping`(:158)为每条硬件中断线分配一个 Linux IRQ 号;`irq_set_chip_and_handler(irq, &armctrl_chip, handle_level_irq)`(:160)把这个 virq 的 chip 指向我们的 `armctrl_chip`、flow handler 指向 `handle_level_irq`(电平触发的标准流程)。`irq_domain_ops armctrl_ops`(:131)只实现了 `xlate`(:110)——从设备树 `interrupts = <bank index>` 属性解析出 hwirq 和触发类型,这是设备树中断属性到硬件中断号的翻译入口。

> **`set_handle_irq` 在干什么**(`arch/arm64/kernel/irq.c:90`)?它把 `bcm2835_handle_irq` 设进全局函数指针 `handle_arch_irq`(`irq.c:87`,标记 `__ro_after_init` 只读)。ARM64 CPU 收到中断跳进异常向量后,最终调 `handle_arch_irq(regs)`——这个间接调用让不同 SoC 的中断控制器能各自接管"CPU 异常入口 → 控制器处理"这一环。BCM2835 在这接管,GIC 的 `irq-gic.c` 也在这接管,替换的都是这个指针。GIC 还会检查"只能设一次"(`handle_arch_irq != default_handle_irq` 时返回 `-EBUSY`,`irq.c:92-93`),防止两个控制器抢入口。

**中断处理入口 `bcm2835_handle_irq`**(`:245`,标记 `__exception_irq_entry` 说明跑在异常入口这种特殊上下文):

```c
/* irq-bcm2835.c:225 — 读 pending 寄存器,找出"是谁在请求中断" */
static u32 get_next_armctrl_hwirq(void)
{
    u32 stat = readl_relaxed(intc.pending[0]) & BANK0_VALID_MASK;  /* :227 读 bank0 pending */
    if (stat == 0)
        return ~0;                                    /* 没中断 */
    else if (stat & BANK0_HWIRQ_MASK)
        return MAKE_HWIRQ(0, ffs(stat & BANK0_HWIRQ_MASK) - 1);     /* :232 bank0 直连 */
    else if (stat & SHORTCUT1_MASK)
        return armctrl_translate_shortcut(1, stat & SHORTCUT1_MASK); /* :234 shortcut 通道 */
    else if (stat & SHORTCUT2_MASK)
        return armctrl_translate_shortcut(2, stat & SHORTCUT2_MASK); /* :236 */
    else if (stat & BANK1_HWIRQ)
        return armctrl_translate_bank(1);             /* :238 bank1 级联:读 bank1 pending */
    else if (stat & BANK2_HWIRQ)
        return armctrl_translate_bank(2);             /* :240 bank2 级联 */
    else
        BUG();
}

/* :245 — CPU 异常进来后调这里 */
static void __exception_irq_entry bcm2835_handle_irq(struct pt_regs *regs)
{
    u32 hwirq;
    while ((hwirq = get_next_armctrl_hwirq()) != ~0)              /* 循环处理所有 pending */
        generic_handle_domain_irq(intc.domain, hwirq);             /* :251 把 hwirq 交给 framework */
}
```

这里能直接看到三大 quirk 的代码体现:`get_next_armctrl_hwirq` 要分五种情况判(bank0 直连 / shortcut1 / shortcut2 / bank1 级联 / bank2 级联),就是因为 Quirk 1(shortcut 不置 bank1/2 pending 位)逼出来的——硬件做了"快捷通道"优化让某些常用中断直达 bank0,软件为了正确识别被迫写一堆分支。最后 `generic_handle_domain_irq(domain, hwirq)`(`:251`)把"硬件中断号"交给 framework,framework 顺着 domain 翻译成 virq、找到 irq_desc、调 flow handler——这就是第四节数据流的接力棒。

### 四、数据流三段链:外设拉线 → CPU 跳异常 → 你的 ISR,每步都在源码里

把"一次中断从硬件到你的 handler"这条链从头追到尾,每一步标源码行号。这是 IRQ 子系统最值得走一遍的链路。

1. **硬件**:外设(比如 UART 收到一字节)在自己的中断输出线上拉电压 → BCM2835 ARMCTRL-IC 的 pending 寄存器对应 bit 被硬件置 1 → 控制器拉高通往 CPU 的 IRQ 引脚。
2. **CPU 捕获**:CPU 执行完当前指令,硬件检测到 IRQ 引脚 → 自动保存现场、跳进 ARM64 异常向量 → 最终调用全局函数指针 `handle_arch_irq`(`arch/arm64/kernel/irq.c:87`)。
3. **控制器驱动接管**:`handle_arch_irq` 是 BCM2835 在 `armctrl_of_init:188` 用 `set_handle_irq`(`arch/arm64/kernel/irq.c:90`)设进来的 `bcm2835_handle_irq`(`irq-bcm2835.c:245`)。它调 `get_next_armctrl_hwirq`(`:225`)读 pending 寄存器找出 hwirq,再调 `generic_handle_domain_irq(intc.domain, hwirq)`(`:251`)把活儿交给 framework。
4. **framework 翻译 + 分派 flow handler**:`generic_handle_domain_irq`(`kernel/irq/irqdesc.c:723`)用 domain 把 hwirq 翻译成 virq、找到对应 `irq_desc`、调它的 flow handler。BCM2835 在 `:160` 把 flow handler 挂成 `handle_level_irq`(`kernel/irq/chip.c:685`):

```c
/* kernel/irq/chip.c:685 — 电平中断的标准 flow handler */
void handle_level_irq(struct irq_desc *desc)
{
    guard(raw_spinlock)(&desc->lock);
    mask_ack_irq(desc);          /* :688 ⭐ 先 mask+ack:屏蔽这条线 + 清 pending(防风暴!) */

    if (!irq_can_handle(desc))   /* 没人注册 handler 就直接返回 */
        return;

    kstat_incr_irqs_this_cpu(desc);
    handle_irq_event(desc);      /* :694 ⭐ 调你的 handler(下面这层) */
    cond_unmask_irq(desc);       /* :696 handler 返回后,有条件地 unmask 重开这条线 */
}
```

   `mask_ack_irq` 这一步是关键——它**先屏蔽 + 确认**这条 IRQ 线,正是第一节讲的"电平触发防风暴"的代码体现:不先 mask,handler 还没跑完,新中断又进来就把 CPU 打爆了。

5. **调你的 ISR**:`handle_irq_event` → `__handle_irq_event_percpu`(`kernel/irq/handle.c:185`)遍历 action 链,对每个 action 调 `action->handler(irq, action->dev_id)`(`handle.c:208`/`:211`)——**这就是你的 ISR 被调到的地方**:

```c
/* kernel/irq/handle.c:185(关键段) */
irqreturn_t __handle_irq_event_percpu(struct irq_desc *desc)
{
    ...
    for_each_action_of_desc(desc, action) {
        irqreturn_t res = action->handler(irq, action->dev_id);   /* :208/211 ⭐ 你的 ISR */

        if (WARN_ONCE(!irqs_disabled(), ...))                      /* :216 防你 ISR 偷开中断 */
            local_irq_disable();

        switch (res) {
        case IRQ_WAKE_THREAD:                                      /* :221 线程化:唤醒下半部线程 */
            if (unlikely(!action->thread_fn)) { warn_no_thread(irq, action); break; }
            __irq_wake_thread(desc, action);                       /* :231 */
            break;
        default:
            break;
        }
        retval |= res;
    }
    return retval;
}
```

6. **ISR 返回后**:回到 `handle_level_irq:696`,`cond_unmask_irq` 调你的 `irq_chip->irq_unmask`(对 BCM2835 就是 `armctrl_unmask_irq:97`,写 enable 寄存器)重新打开这条中断线,准备接下一次。

整条链:外设拉线 → 控制器 pending → CPU 跳 `handle_arch_irq` → `bcm2835_handle_irq:245` → `generic_handle_domain_irq:723` → `handle_level_irq:685`(mask_ack_irq)→ `__handle_irq_event_percpu:185` → `action->handler`(你的 ISR,handle.c:208)→ 返回 → `cond_unmask_irq` → `armctrl_unmask_irq:97`(写 enable 寄存器)。从硬件电信号到你的 C 函数,每一步都能在源码里指到行。

### 五、源码真踩坑(都是读 irq-bcm2835.c 和 core 才发现的,不是通识)

1. **BCM2835 的 bank1/2 中断"不能 mask"(Quirk 2)**(`irq-bcm2835.c:16-21` 注释)。正常级联控制器下游中断线像普通线一样能 mask,BCM2835 偏偏不行。这意味着 `armctrl_mask_irq`(:92)对 bank1/2 的中断实际掐不断源头——只能靠"电平触发 + ONESHOT + flow handler 先 mask 自己这层"来兜底。读到这条 quirk 你才明白,为什么 IRQ 子系统要把"mask"设计成 chip 回调而不是直接关寄存器——不同硬件的"mask"能力是不一样的,framework 给了"尽力 mask"的语义,真掩不掩得住得看芯片。换 GIC 这种规整的控制器就没这毛病。

2. **probe 时必须检测 bootloader 残留**(`irq-bcm2835.c:165-170`)。驱动初始化时读 enable 寄存器,非零说明 bootloader(如树莓派的 firmware)开了某些中断又没关干净。驱动主动把它们 disable 掉并打 `FW_BUG`(固件 bug)警告。这是平台/irqchip 驱动要操心的真实坑——bootloader 留的"幽灵中断"在内核还没注册 handler 时就触发,会走到空 action 链、被 spurious 逻辑统计,严重时刷屏。所以严肃的 irqchip 驱动 probe 都要做这道清理。

3. **hwirq、virq、硬件引脚号是三个不同的东西**。硬件层面是"bank + index"(如 bank1 的第 5 条线);驱动用 `MAKE_HWIRQ(b, n) = (b << 5) | n`(`:48`)把它编码成一个 `hwirq`(如 0x25);framework 再通过 `irq_domain` 给这个 hwirq 分配一个 Linux IRQ 号 `virq`(如 73)。消费驱动 `request_irq(irq=73, ...)` 给的是 virq,framework 翻译回 hwirq 再交给 chip 操作寄存器。**三层号别混**——`/proc/interrupts` 第一列是 virq,debugfs 里能看到对应 hwirq。这就是 `irq_domain` 这层翻译存在的意义:把"千奇百怪的硬件编号"统一成"一套连续的 Linux IRQ 号空间"。

4. **`handle_level_irq` 代你做 mask/ack,所以 BCM2835 的 irq_chip 极简**(`chip.c:685-688`)。flow handler 在调你的 handler 前 `mask_ack_irq`,在 handler 返回后 `cond_unmask_irq`——这套"自动 mask-ack-handle-unmask"流程是 framework 的 flow handler 干的,不是你要写的。所以 BCM2835 的 `armctrl_chip` 只填 `irq_mask`/`irq_unmask` 两个回调就够工作(`:102`),没单独的 `irq_ack`——电平控制器的 ack 往往就是 mask(屏蔽即清 pending)。这也是为什么"flow handler"叫 flow handler:它管的是"一次中断从进来到处理完的标准流程",chip 回调只是流程里被调用的零件。

5. **ISR 偷开中断会被 framework 抓现行**(`handle.c:216`)。`__handle_irq_event_percpu` 调完你的 handler 会检查 `irqs_disabled()`——如果你在 ISR 里(直接或间接)开了 CPU 中断,`WARN_ONCE` 打一条 `handler enabled interrupts` 并帮你 `local_irq_disable()` 关回去。这是防 ISR 写错的护栏:中断上下文里处理器中断本该是关着的,你偷偷开了会导致中断重入、栈溢出等一系列灾难。开 `CONFIG_DEBUG_ATOMIC_SLEEP` 调试时这类问题会第一时间暴露。

6. **边沿 vs 电平触发的坑,本质是"ack 之后还会不会再触发"**。电平触发里,只要外设那边的电平没撤(比如 UART 接收缓冲还有数据,RX 线一直高),你 ack 掉 pending 位它马上又被硬件置位 → 中断风暴。所以电平中断的 ISR 必须**从源头消除信号**(读掉数据/复位外设),光 ack 控制器没用。边沿触发只记"跳变次数",ack 一次清一次,相对省心但高负载可能合并脉冲。BCM2835 全用电平(`handle_level_irq`),所以它的外设驱动 ISR 都得规矩处理信号源。这也是 `IRQF_TRIGGER_FALLING` 这种标志的电气含义——告诉控制器"这条线配成下降沿触发",从根上决定后续行为。

## ISR 的铁律:不能睡,要快

跑在**中断上下文**的 handler 有条铁律,要刻进骨头里:

> **在中断处理程序里,绝不能睡眠。**

不能调 `mutex_lock()`,不能 `kmalloc(GFP_KERNEL)`(必须 `GFP_ATOMIC`),不能 `copy_to_user()`(可能触发缺页睡眠)。理由:中断上下文**不属于任何进程**,调度器没法把你"挂起再唤醒"——你一旦睡,系统就死在那儿。开了 `CONFIG_DEBUG_ATOMIC_SLEEP` 的话,`might_sleep()` 会吐 `WARNING` 加调用栈(底层走 `__might_sleep()`)——只是警告加打印,不 oops 不 panic,但看到这栈你该知道自己踩雷了。

handler 的标准长相:

```c
static irqreturn_t my_isr(int irq, void *dev_id)
{
    /* 1. 读寄存器,确认是不是本设备触发 */
    /* 2. 从源头清掉信号(电平触发尤其要) */
    /* 3. 只做最紧急的活,重活推给下半部 */
    return IRQ_HANDLED;   /* 或 IRQ_NONE / IRQ_WAKE_THREAD */
}
```

返回值 `irqreturn_t`:`IRQ_HANDLED`(处理了)、`IRQ_NONE`(不是我的,共享中断里常见)、`IRQ_WAKE_THREAD`(唤醒线程化下半部,见 [12](./12-drv-threaded-irq.md))。注意 `IRQ_NONE` 不能滥用——持续返回它会被 spurious 逻辑(`note_interrupt()`,`kernel/irq/spurious.c`)记成虚假中断,超过阈值(默认 10 万次里 99 次未处理)就自动把这条 IRQ 线禁掉,得排查清楚再返回。

ISR 太慢会丢后续中断、太原子又干不了要睡眠的重活——Linux 的解法是**分治**:上半部(ISR)抢时间、关中断里干最紧急的确认;下半部把不急的重活延后。下半部有几代实现:**softirq**(编译期静态注册的向量,最快但没并发保护)、**tasklet**(建在 softirq 上,保证单 CPU 不重入,**已被标记 deprecated**,新代码别用)、**workqueue**(丢给内核线程跑,可睡眠,适合要分配大内存/持 mutex 的重活)、**线程化中断**(下半部的现代方案,见 [12](./12-drv-threaded-irq.md))。本篇把上半部讲透,下半部展开是 [12](./12-drv-threaded-irq.md) 的活儿。

## `IRQF_` 标志位家族

`request_irq` 的 `flags` 用一组 `IRQF_*` 标志组合(`include/linux/interrupt.h`):

- **`IRQF_TRIGGER_RISING/FALLING/HIGH/LOW`**(`:32-35`,值 `0x1/0x2/0x4/0x8`):电气触发方式。上升沿/下降沿是边沿,高/低电平是电平。设备树 `interrupts` 属性已编码触发类型时通常由 IRQ controller driver 设,驱动不用再手动指定。
- **`IRQF_SHARED`**(`:74`,值 `0x80`):允许多个设备共用一根 IRQ 线(PCI 的老传统)。配它就必须给非空 `dev_id`——`free_irq` 时靠 `dev_id` 区分该摘掉链表上哪个节点。
- **`IRQF_ONESHOT`**(`:80`,值 `0x2000`):**线程化中断专用**——hardirq 跑完不立即重开这条 IRQ 线,保持屏蔽直到 thread_fn 跑完。电平触发的线程化中断必加,否则 thread 还没跑完新中断又来,行为混乱。详见 [12](./12-drv-threaded-irq.md)。
- **`IRQF_NO_AUTOEN`**(`:86`,值 `0x80000`):注册后不自动使能,等驱动准备好再 `enable_irq`。

## 释放、启用与禁用 IRQ

用完要还:`free_irq(irq, dev_id)`(`manage.c` 中 `const void *free_irq(...)`)。它从 action 链上摘掉匹配 `dev_id` 的节点、`kfree(action)`,并**等待当前正在跑的 handler 跑完**才返回(内部调 `__synchronize_irq`)。返回值是被摘下那个 action 的 name——释放后判个空,能确认自己确实摘对了节点。共享中断务必先在硬件层禁用这条线再 `free_irq`,否则释放途中又来中断、handler 却已解绑,系统会懵。

光释放不够时,还要会"临时掐断再恢复"。几个常用 API(都在 `kernel/irq/manage.c`)作用域差很多,别混用:

- **`disable_irq(irq)`**:同步禁用——标记这条线不响应,**并等待当前正在跑的 handler 结束**才返回。所以它本身可能睡眠,**绝不能在持有自旋锁或中断上下文里调**,否则死锁。
- **`disable_irq_nosync(irq)`**:异步禁用——只标记,不等 handler。中断上下文里要禁用就用它,但代价是你返回后 handler 可能还在别的 CPU 上跑完。
- **`enable_irq(irq)`**:和 disable 配对,重新开线。disable 调几次、enable 就得配几次,内核对这对操作有计数。
- **`synchronize_irq(irq)`**:不改变使能状态,纯粹"等到这条 IRQ 上所有 pending 的 handler 跑完"。换 buffer、卸 handler 前调它最稳。
- **`local_irq_disable()` / `local_irq_enable()`**(`include/linux/irqflags.h`):这是宏,关/开**当前 CPU 的全部中断**,粒度最粗。只能极短临界区用,关太久直接拖垮实时性。

这套 API 跟 `free_irq` 的"等 handler 跑完"是同一条逻辑线:只要你想动一条正在服务的中断,都得先确保没人还在它的 handler 里。现代驱动更推荐托管版 `devm_request_irq()` / `devm_request_threaded_irq()`——多传一个 `struct device *`,内核记录归属,设备移除时自动 `free_irq`,省去手动配对的麻烦。

## 动手试试

> 本篇机制可在 QEMU ARM64 virt(GIC 中断控制器)上验证;BCM2835 的 ARMCTRL-IC 在树莓派实物上,标"待亲测"。

1. **看中断第一现场**:`cat /proc/interrupts`——每行一个 IRQ,列依次是 IRQ 号(virq)、各 CPU 核上的触发计数、中断控制器类型、触发方式、设备名。在 QEMU virt 上能看到 GIC 各种中断(GICv2/GICv3);敲一下键盘或 `ping` 一下,再看对应行计数 +1,直观验证"中断真的来了"。
2. **IRQ 亲和性**:`cat /proc/irq/<N>/smp_affinity_list`、`echo 0-1 > /proc/irq/<N>/smp_affinity` 把某中断绑到指定 CPU 核,然后 `cat /proc/interrupts` 观察计数只在那几个核涨——这是 NUMA/实时调优的常用手段。
3. **debugfs 内部**(开 `CONFIG_GENERIC_IRQ_DEBUGFS`):`ls /sys/kernel/debug/irq/`、`cat /sys/kernel/debug/irq/irqs/<N>` 看 irq_desc 的 action 链、chip、hwirq——把第二节的五个数据结构对着真实节点认一遍。
4. **注册一个虚拟中断并触发**:写一个 platform 驱动,`probe` 里用 `devm_request_irq()` 注册一段 IRQ,handler 只做计数自增 + 返回 `IRQ_HANDLED`;通过 sysfs/gpio 或 `irq_inject_interrupt()` 注入一次中断,`cat /proc/interrupts` 看对应 IRQ 计数是否 +1,`dmesg` 看 ISR 被调。
5. 读 `drivers/irqchip/irq-bcm2835.c` 全文(265 行)对照本篇第三节,把 `armctrl_of_init` 的"建 domain → 建 mapping → 挂 chip+handler → 查 bootloader 残留"四步走一遍;再读 `kernel/irq/chip.c:685` 的 `handle_level_irq` 和 `kernel/irq/handle.c:185` 的 `__handle_irq_event_percpu`,把第四节数据流链每一步在源码里指到行。
6. 思考题:BCM2835 的 `armctrl_chip` 只填了 `irq_mask`/`irq_unmask`,没填 `irq_ack`,但电平触发又必须 ack 防 pending 位残留——那 ack 动作到底谁干的?(`handle_level_irq:688` 的 `mask_ack_irq` 会优先调 `irq_mask_ack`,没有就调 `irq_mask`+`irq_ack`,BCM2835 这俩都没单独填就只调 `irq_mask`——屏蔽即清 pending,这是电平控制器常见的 ack 等价处理。)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):
  - framework 核心:`kernel/irq/manage.c`(`request_threaded_irq:2100`、`request_irq` 包装在 `include/linux/interrupt.h:173`、`__setup_irq:1460`、`free_irq`、`disable_irq`/`enable_irq`/`synchronize_irq`);`kernel/irq/handle.c`(`__handle_irq_event_percpu:185` 调你的 handler、`__irq_wake_thread` 唤醒线程化下半部);`kernel/irq/chip.c`(`handle_level_irq:685` 电平 flow handler、`handle_fasteoi_irq:736` GIC 常用、`handle_edge_irq`);`kernel/irq/irqdomain.c`(hwirq↔virq 翻译);`kernel/irq/spurious.c`(`note_interrupt` 虚假中断判定与自动禁线)。
  - 数据结构:`include/linux/interrupt.h:123 struct irqaction`、`:104 irq_handler_t`、`:32-86 IRQF_* 标志`;`include/linux/irq.h:492 struct irq_chip`、`:177 struct irq_data`;`include/linux/irqdesc.h:67 struct irq_desc`、`:185 generic_handle_domain_irq 声明`;`include/linux/irqdomain.h:168 struct irq_domain`;`arch/arm64/kernel/irq.c:90 set_handle_irq`(设架构级 IRQ 入口)。
  - 典型 irqchip 驱动:`drivers/irqchip/irq-bcm2835.c`(本篇走读)、`drivers/irqchip/irq-gic.c`(ARM GIC,服务器/手机主流)、`drivers/irqchip/irq-sifive-plic.c`(RISC-V)、`drivers/irqchip/irq-nvic.c`(ARM Cortex-M)、`drivers/pinctrl/bcm/pinctrl-bcm2835.c`(树莓派 GPIO 控制器也兼 irqchip,看 gpio_chip 怎么挂 irq_domain)。
- kernel.org:[Generic IRQ subsystem](https://docs.kernel.org/core-api/genericirq.html)(IRQ 子系统设计:flow handler/chip/domain 分层,权威)、`Documentation/devicetree/bindings/interrupt-controller/`(各控制器 binding,看 `interrupts` 属性怎么写)。
- 关联本站:本篇讲上半部(硬中断)全景 + irqchip 驱动,线程化下半部(`request_threaded_irq`/`IRQF_ONESHOT`/irq 内核线程)是 [12 drv-threaded-irq](./12-drv-threaded-irq.md) 的进阶;IRQ 号从设备树 `interrupts` 属性来,配对靠 `compatible`,见 [11 drv-dts](./11-drv-dts.md);中断风暴/ISR 写错导致的 oops 排查见调试篇。
