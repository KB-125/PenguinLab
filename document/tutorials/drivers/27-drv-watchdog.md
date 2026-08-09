---
title: "watchdog:看门狗——系统挂起时,硬件替你按下复位键"
slug: drv-watchdog
prerequisites:
  - drv-platform
  - drv-irq
difficulty: intermediate
tags: [driver, watchdog, hw_reset, nowayout, bcm2835, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - source: third_party/linux（6.19）drivers/watchdog/、include/linux/watchdog.h
maturity: drafting
related:
  - /tutorials/drivers/10-drv-platform
  - /tutorials/debugging/08-debug-panic
---

> 🔨 **整理中** · 这一篇拆 watchdog 子系统:framework 怎么搭(`watchdog_core.c`/`watchdog_dev.c`)、`struct watchdog_device`/`watchdog_ops` 数据结构,再拿树莓派的 `bcm2835_wdt.c`(248 行,一个完整真实的 watchdog 驱动)逐段走读它的 probe、ops、硬件寄存器操作,最后把"用户喂狗"的数据流从 `/dev/watchdog` 一路追到硬件寄存器。每个 API 都对照它对应的硬件特性讲。动手部分在真板验过之前标"待亲测"。

## 做什么

嵌入式产品(路由器、IoT、工业控制器)常年在野外无人值守。万一软件因为死锁、内存损坏、无限循环卡死,系统就"假死"——没法 ssh、没法重启,得人去现场拔电。**watchdog(看门狗)** 就是给这种场景兜底的硬件机制:SoC 里有一块**独立运行**的倒计数器,软件得定期"喂狗"(把计数器重置回初值)证明"我还活着";一旦软件卡死、停止喂狗,计数器溢出,**硬件自动拉低复位线、把整个 SoC 复位重启**。这套不依赖软件本身(软件已经卡死了,靠软件自己重启不可靠),靠的是独立硬件——所以它叫"硬件看门狗"。

这一篇我们拆 watchdog 子系统:先讲清**硬件长什么样**(以 BCM2835 为例),再读 framework 怎么把"独立计数器+溢出复位"这套硬件抽象成 `/dev/watchdog` + 一组 API,最后走读 bcm2835 驱动怎么填这组 API。

## 要了解什么

### 〇、硬件背景:watchdog 是一块"会自己复位系统"的独立计数器

要理解 watchdog 的 API,得先懂它的硬件——所有 API 设计都从硬件特性来。

**watchdog 硬件本质**:一个独立倒计数器 + 一个溢出动作(拉复位线)。它和 CPU 核心**独立运行**——CPU 卡死不影响它继续倒数;它溢出时直接拉 SoC 的 RESET 线,强制整个芯片复位,跟软件没得商量。软件的活就是"在它溢出前,定期写寄存器把计数器重置回初值"(喂狗);软件一旦不喂,计数器走到 0,硬件复位。

**具体看 BCM2835(树莓派 SoC)的 watchdog**——它就在 BCM2835 的 **PM(电源管理)模块**里,用三个 32 位寄存器(`bcm2835_wdt.c:23-25`):

```c
#define PM_RSTC             0x1c    /* Reset control 复位控制 */
#define PM_RSTS             0x20    /* Reset status 复位状态(记复位原因) */
#define PM_WDOG             0x24    /* Watchdog 计数器值 */
```

几个关键硬件特性(每个都直接决定了一个 API):

1. **写寄存器必须带"密码"**:`PM_PASSWORD = 0x5a000000`(`:27`)。BCM2835 规定:写 PM 模块的任何寄存器,高 8 位必须是 `0x5a`,否则硬件**直接忽略**这次写。这是硬件防误写保护——PM 模块管电源/复位,软件 bug 误写会直接把芯片搞挂,所以硬件强制要密码。→ 所以驱动每次写寄存器都要 `PM_PASSWORD | value`(`bcm2835_wdt.c:74,77,89,106...` 每处 writel 都带)。

2. **计数器是 20 位、tick 固定**:`PM_WDOG_TIME_SET = 0x000fffff`(`:29`)是计数器值的掩码(低 20 位);tick 频率固定,换算宏 `SECS_TO_WDOG_TICKS(x) = (x) << 16`(`:43`)——即每秒 65536 个 tick(每 tick ~15.26µs)。20 位最多存 `0xfffff` ≈ 1048575 tick ≈ **16 秒**。→ 所以驱动填 `max_hw_heartbeat_ms = WDOG_TICKS_TO_MSECS(PM_WDOG_TIME_SET)`(`:144`,约 16 秒),告诉 framework"硬件最多能等 16 秒"。

3. **溢出动作可配**:`PM_RSTC` 的 `WRCFG` 位配成 `PM_RSTC_WRCFG_FULL_RESET = 0x00000020`(`:33`)时,计数器溢出触发**完整芯片复位**。→ 所以 `start` 要写 PM_RSTC 配 FULL_RESET(`:77-78`),`stop` 写 `PM_RSTC_RESET`(`:34/:89`)取消。

4. **复位可以用软件主动触发**:往 PM_WDOG 写一个**极小的值** + 配 FULL_RESET,计数器"立刻"溢出 → 立即复位。→ 这就是 watchdog 还能当"重启按钮"用的原理(`__bcm2835_restart`:`:101`,写 10 tick ≈ 150µs 后复位)。

所以 watchdog 子系统的 API——`start`(启动计数器+配溢出复位)/`stop`/`ping`(喂狗=重置计数器)/`set_timeout`/`get_timeleft`(读剩多少)/`restart`(主动触发复位)——每一条都对应硬件的一个动作。不讲清楚硬件,这套 API 就是没来由的符号罗列。

### 一、framework 全景:watchdog_core + watchdog_dev 两个文件

watchdog 子系统核心代码分两个文件(`drivers/watchdog/`):

**`watchdog_core.c`(494 行)——注册/生命周期**。外部驱动调 `watchdog_register_device(wdd)`(`:367`)注册一个 watchdog,它内部走 `___watchdog_register_device`(`:240`)做四件事:

- **校验**(`:244-249`):`wdd->ops->start` 必须有;`stop` 或 `max_hw_heartbeat_ms`(告诉 framework 硬件能等多久)至少得有一个,否则注册失败。
- **分配 id**(`:261-272`):用 ida 分配 `watchdog0/1/2...`(优先用设备树 `aliases` 里的 `watchdog` 名)。
- **`watchdog_dev_register(wdd)`**(`:274`):把这个 watchdog 注册成字符设备 `/dev/watchdogN`(下一个文件干)。
- **挂 notifier**(`:302-335`):如果设了 `WDOG_STOP_ON_REBOOT`,挂 reboot notifier(系统重启时自动 stop watchdog,免得重启过程中被它复位);如果驱动实现了 `ops->restart`,挂成系统的 restart handler(`reboot` 命令就靠它);如果 `WDOG_NO_PING_ON_SUSPEND`,挂 pm notifier(挂起时停 worker)。

**`watchdog_dev.c`(~1100 行)——`/dev/watchdogN` 字符设备接口 + 喂狗 worker**。它把 watchdog 暴露成字符设备,`file_operations` 在 `:992`:

```c
static const struct file_operations watchdog_fops = {  /* watchdog_dev.c:992 */
    .owner          = THIS_MODULE,
    .write          = watchdog_write,      /* :697  write /dev/watchdog = 喂狗 */
    .unlocked_ioctl = watchdog_ioctl,      /* :750  WDIOC_KEEPALIVE/WDIOC_SETTIMEOUT... */
    .compat_ioctl   = compat_ptr_ioctl,
    .open           = watchdog_open,       /* :864 */
    .release        = watchdog_release,    /* :942  关闭(看 nowayout 决定要不要停) */
};
```

用户态"喂狗"就两条路:往 `/dev/watchdog` `write` 任意一个字节(`watchdog_write:697` 走起),或 `ioctl(WDIOC_KEEPALIVE)`(`:750`)。两条都汇到 `watchdog_ping`(`:191`)→ `__watchdog_ping`(`:144`,下节数据流细讲)。

framework 还内置一个**喂狗内核线程 worker**(`watchdog_kworker`,`watchdog_dev.c:58`)——它的存在是为了解决"用户态要 60 秒超时、但硬件最多只能等 16 秒"的矛盾:framework 算好,在硬件超时前由内核 worker 替你 ping 一次(重置硬件计数器),而对用户态来说"好像超时是 60 秒"。`watchdog_need_worker`(`:76`)判断要不要启用 worker——条件是"用户态 timeout > 硬件 max_hw_heartbeat_ms"。

### 二、核心数据结构:watchdog_device / watchdog_ops / watchdog_info

驱动要填三样(`include/linux/watchdog.h`):

**`struct watchdog_ops`**(`:47`)——驱动填的回调表,对应硬件动作:

```c
struct watchdog_ops {              /* include/linux/watchdog.h:47 */
    struct module *owner;
    int (*start)(struct watchdog_device *);    /* 启动计数器+配溢出复位(必填) */
    int (*stop)(struct watchdog_device *);     /* 停(可选;硬件不能停的给 max_hw_heartbeat_ms) */
    int (*ping)(struct watchdog_device *);     /* 喂狗=重置计数器(可选;没填则 framework 用 start 顶替) */
    unsigned int (*status)(struct watchdog_device *);
    int (*set_timeout)(struct watchdog_device *, unsigned int);
    unsigned int (*get_timeleft)(struct watchdog_device *);  /* 读剩多少秒 */
    int (*restart)(struct watchdog_device *, unsigned long, void *);  /* 主动触发复位 */
    ...
};
```

注意 `ping` 是**可选的**——有些硬件(如 BCM2835)没有单独的"重置计数器"指令,喂狗就是"重新写一次 timeout 值+启动",那 `ping` 不填、framework 自动用 `start` 顶替(下节源码会看到 `__watchdog_ping` 的这个分支)。`restart` 也是可选的,填了就把 watchdog 注册成系统 restart handler(`reboot` 走它)。

**`struct watchdog_device`**(`:98`)——一个 watchdog 实例:

```c
struct watchdog_device {           /* include/linux/watchdog.h:98 */
    const struct watchdog_info *info;
    const struct watchdog_ops  *ops;
    unsigned int timeout;              /* 当前超时(秒) */
    unsigned int min_timeout, max_timeout;   /* 软件可设范围 */
    unsigned int max_hw_heartbeat_ms;  /* 硬件最多能等的毫秒(超这个要靠 framework worker) */
    struct device *parent;
    ...
    unsigned long status;              /* 运行状态位(WDOG_ACTIVE/HW_RUNNING/...) */
};
```

`max_hw_heartbeat_ms` 是 framework worker 机制的关键:驱动告诉 framework"硬件最多等 N 毫秒",如果用户要的超时 > N,framework 用 worker 在 N 内替你 ping。

**`struct watchdog_info`**——给用户态 `ioctl(WDIOC_GETSUPPORT)` 看的身份/能力(如 `WDIOF_KEEPALIVEPING|WDIOF_SETTIMEOUT|WDIOF_MAGICCLOSE` + identity 字符串)。

### 三、源码走读:bcm2835_wdt.c(树莓派 watchdog 驱动,248 行)

现在拿一个真实驱动逐段看。`drivers/watchdog/bcm2835_wdt.c` 是树莓派的 watchdog 驱动,很短但五脏俱全。

**私有数据 + ops 填充**。先看驱动怎么填 ops(`:126`)和那个静态的 watchdog_device(`:140`):

```c
/* bcm2835_wdt.c:126 — ops:填了 start/stop/get_timeleft/restart,没填 ping */
static const struct watchdog_ops bcm2835_wdt_ops = {
    .owner        = THIS_MODULE,
    .start        = bcm2835_wdt_start,
    .stop         = bcm2835_wdt_stop,
    .get_timeleft = bcm2835_wdt_get_timeleft,
    .restart      = bcm2835_restart,
};

/* :140 — 静态 watchdog_device(树莓派只有一个 watchdog,用静态实例) */
static struct watchdog_device bcm2835_wdt_wdd = {
    .info              = &bcm2835_wdt_info,
    .ops               = &bcm2835_wdt_ops,
    .min_timeout       = 1,
    .max_hw_heartbeat_ms = WDOG_TICKS_TO_MSECS(PM_WDOG_TIME_SET), /* ~16000ms,硬件上限 */
    .timeout           = WDOG_TICKS_TO_SECS(PM_WDOG_TIME_SET),
};
```

bcm2835 **没填 `ping`**——因为它的硬件没有单独的"重置计数器"指令,喂狗就是再写一次 PM_WDOG+启动。所以喂狗时 framework 会调它的 `start` 顶替(看下文 `__watchdog_ping`)。

**`start` 的硬件操作**(`:66`)——这是最核心的"和硬件打交道"的代码:

```c
/* bcm2835_wdt.c:66 */
static int bcm2835_wdt_start(struct watchdog_device *wdog)
{
    struct bcm2835_wdt *wdt = watchdog_get_drvdata(wdog);
    uint32_t cur;
    unsigned long flags;

    spin_lock_irqsave(&wdt->lock, flags);                /* 保护寄存器访问 */

    /* 写 PM_WDOG:密码(0x5a) | (秒→tick 数 & 20位掩码) */
    writel_relaxed(PM_PASSWORD | (SECS_TO_WDOG_TICKS(wdog->timeout) &
                                  PM_WDOG_TIME_SET), wdt->base + PM_WDOG);
    /* 配 PM_RSTC:读出当前值,清 WRCFG 位,设成 FULL_RESET,再带密码写回 */
    cur = readl_relaxed(wdt->base + PM_RSTC);
    writel_relaxed(PM_PASSWORD | (cur & PM_RSTC_WRCFG_CLR) |
                   PM_RSTC_WRCFG_FULL_RESET, wdt->base + PM_RSTC);

    spin_unlock_irqrestore(&wdt->lock, flags);
    return 0;
}
```

每一步都对应硬件特性:`PM_PASSWORD |` 是高 8 位密码(防误写)、`SECS_TO_WDOG_TICKS(wdog->timeout)` 把秒换算成 tick、`& PM_WDOG_TIME_SET` 截 20 位、`PM_RSTC_WRCFG_FULL_RESET` 配溢出触发完整复位。`spin_lock_irqsave` 保护(寄存器访问不能并发、不能被中断打断)。`stop`(`:85`)就是写 `PM_PASSWORD | PM_RSTC_RESET` 取消复位配置。

**`probe` 完整流程**(`:171`)——platform 驱动入口:

```c
/* bcm2835_wdt.c:171(简化,保留每一步的关键) */
static int bcm2835_wdt_probe(struct platform_device *pdev)
{
    struct bcm2835_pm *pm = dev_get_drvdata(pdev->dev.parent);  /* 寄存器基址从 parent PM 模块拿 */
    struct bcm2835_wdt *wdt = devm_kzalloc(dev, sizeof(*wdt), GFP_KERNEL);
    spin_lock_init(&wdt->lock);
    wdt->base = pm->base;                                        /* PM 模块的寄存器空间 */

    watchdog_set_drvdata(&bcm2835_wdt_wdd, wdt);                 /* 私有数据挂到 wdd */
    watchdog_init_timeout(&bcm2835_wdt_wdd, heartbeat, dev);     /* 从模块参数/设备树 timeout-sec 设 timeout */
    watchdog_set_nowayout(&bcm2835_wdt_wdd, nowayout);           /* 设 nowayout */
    bcm2835_wdt_wdd.parent = dev;

    /* ⭐ 关键:检查 bootloader 是不是已经把 watchdog 跑起来了 */
    if (bcm2835_wdt_is_running(wdt))
        set_bit(WDOG_HW_RUNNING, &bcm2835_wdt_wdd.status);       /* 告诉 framework"硬件已在跑",它会立刻接管喂狗 */

    watchdog_set_restart_priority(&bcm2835_wdt_wdd, 128);        /* 当系统 restart handler,默认优先级 */
    watchdog_stop_on_reboot(&bcm2835_wdt_wdd);                   /* 系统重启时自动 stop(免得重启被它复位) */
    err = devm_watchdog_register_device(dev, &bcm2835_wdt_wdd);   /* 注册! */

    /* 树莓派额外:如果这 watchdog 是 system power controller,注册成关机回调 */
    if (of_device_is_system_power_controller(pdev->dev.parent->of_node))
        if (!pm_power_off) { pm_power_off = bcm2835_power_off; ... }

    return 0;
}
```

几个只有读源码才注意到的细节:`wdt->base` 是从 **parent PM 模块**拿的(bcm2835 watchdog 不独立占一段寄存器,它寄居在 PM 模块里,所以是个 MFD 子设备);`bcm2835_wdt_is_running` 检查 bootloader 是否已启动 watchdog——是的话设 `WDOG_HW_RUNNING`,framework 立刻接管喂狗(否则 bootloader 设的 timeout 到了会复位,内核还没起来就挂了);`watchdog_stop_on_reboot` 让系统正常 reboot 时自动停 watchdog(否则 reboot 过程中 watchdog 超时复位,无限循环)。

**`restart` + `power_off`:watchdog 的复用**(`:101`/`:153`)。watchdog 还能干两件副产品:`__bcm2835_restart`(`:101`)往 PM_WDOG 写 10 tick(~150µs)+ FULL_RESET,计数器"几乎立刻"溢出复位——这就是 `reboot` 命令的物理实现(注册成 restart handler,priority 128)。`bcm2835_power_off`(`:153`)更妙:树莓派其实**没法真关机**,它通过设 `PM_RSTS` 的 `PM_RSTS_RASPBERRYPI_HALT=0x555` 标志位告诉 bootcode.bin"这次复位后别重启",然后用 watchdog 触发复位——从用户看就是"关机"了。一个 watchdog 硬件,顶"复位保险 + 重启按钮 + 关机"三个用途。

### 四、数据流:用户 `echo > /dev/watchdog` 到硬件,每步都在源码里

把"用户态喂狗"这条链从头走到硬件,每一步标源码行号:

1. **用户态**:`echo x > /dev/watchdog`(或 `ioctl(WDIOC_KEEPALIVE)`)。
2. **VFS** → `watchdog_fops.write` = `watchdog_write`(`watchdog_dev.c:697`):它把这次 write 当作"喂狗"信号。
3. `watchdog_write` → `watchdog_ping`(`:191`):设 `_WDOG_KEEPALIVE` 标志、更新 `last_keepalive`,调 `__watchdog_ping`。
4. `__watchdog_ping`(`:144`)的核心几行:

```c
/* watchdog_dev.c:144(关键段) */
static int __watchdog_ping(struct watchdog_device *wdd)
{
    ...
    /* 节流:距上次硬件 ping 不到 min_hw_heartbeat_ms,用 hrtimer 延后,防过频访问硬件 */
    if (ktime_after(earliest_keepalive, now)) { hrtimer_start(...); return 0; }
    ...
    if (wdd->ops->ping) {
        err = wdd->ops->ping(wdd);     /* :164 驱动有 ping 就调 ping */
    } else {
        err = wdd->ops->start(wdd);    /* :167 没 ping 就调 start 重启计数器 ← bcm2835 走这条 */
    }
    watchdog_update_worker(wdd);        /* 更新 worker 调度(若需要 framework 替喂) */
    return err;
}
```

5. **驱动回调**(bcm2835 走 `:167` 的 start 分支):`bcm2835_wdt_start`(`bcm2835_wdt.c:66`)→ `writel_relaxed(PM_PASSWORD | ticks, wdt->base + PM_WDOG)` → 硬件计数器被重置回 timeout 值。
6. **硬件**:计数器从新值重新倒计数;如果用户态一直没再喂、framework worker 也没替喂,计数器溢出 → PM_RSTC 配的 FULL_RESET 触发 → SoC 复位。

整条链:用户 write → VFS → `watchdog_write:697` → `watchdog_ping:191` → `__watchdog_ping:144` → `ops->start`(`bcm2835_wdt_start:66`)→ `writel(PM_WDOG)`。每一步都能在源码里指到行。

### 五、源码真踩坑(都是读源码才发现的,不是通识)

1. **没 `ops->ping` 时 framework 自动用 `start` 喂狗**(`watchdog_dev.c:163-169`)。所以像 bcm2835 这种"喂狗=重新启动"的硬件,驱动不写 ping 也工作——但你要知道 framework 调的是 start。这也意味着 start 必须是"可重复调用、每次都把计数器重置"的(不能是"只有第一次有效")。

2. **bootloader 已启动 watchdog 时,必须设 `WDOG_HW_RUNNING`**(`bcm2835_wdt.c:190`)。bootloader(如树莓派的 bootcode.bin)可能为了让内核能稳稳启动、提前开了 watchdog。内核驱动 probe 时若发现它已在跑,必须告诉 framework(`set_bit(WDOG_HW_RUNNING, ...)`)——framework 会立刻接管定期喂狗,否则 bootloader 设的 timeout(可能很短)一到就把内核复位了。

3. **`PM_PASSWORD` 这种"写寄存器要密码"是 BCM2835 特有**(`bcm2835_wdt.c:27,74`)。换到别的 SoC(高通/瑞芯微/全志)watchdog 寄存器布局、保护机制完全不同——但"独立计数器+溢出复位"的本质一样,所以 watchdog 子系统的 API 一样。读 bcm2835 是学框架,真要写自己板子的 watchdog 驱动,得看自家 SoC 手册的 PMU/watchdog 寄存器。

4. **`watchdog_stop_on_reboot` 必须设**(`bcm2835_wdt.c:204`)。否则系统正常 reboot 时,watchdog 还在跑,reboot 过程(几秒)超过 timeout 就被它复位——陷入"reboot→watchdog复位→重新启动→reboot"的死循环。

5. **framework worker 替用户态喂狗**(`watchdog_dev.c:76 watchdog_need_worker`)。当用户要的 timeout(如 60s) > 硬件 max(如 16s),framework 用内核 worker 在硬件超时前替你 ping,对用户态呈现"60s 超时"。但代价是:一旦内核 worker 自己卡住(内核 panic 在不可中断上下文),worker 不喂狗 → 硬件复位——这恰恰是 watchdog 该干的(连内核卡死都兜底)。

6. **`nowayout`**(`bcm2835_wdt.c:55,188`):一旦启动 watchdog,关 `/dev/watchdog` 也不再停止它(`WATCHDOG_NOWAYOUT` 配置项)。生产环境开它——防"卡死的软件顺手把 watchdog 也关了,然后彻底没救"。`watchdog_release`(`:942`)关设备时会检查 nowayout 决定要不要 `stop`。

## 动手试试

> BCM2835 watchdog 在树莓派上有实物;QEMU 标准 virt 机型没有 watchdog(可挂 `-device ib700` 老 ISA watchdog,但和 bcm2835 差很远)。以下在树莓派或宿主机做。

1. `ls /dev/watchdog*`、`ls /sys/class/watchdog/`、`cat /sys/class/watchdog/watchdog0/identity`/`state`/`timeout`/`timeleft`/`nowayout`/`status`
2. `cat /sys/class/watchdog/watchdog0/options`(看支持 WDIOF_* 哪些,对照驱动 `info.options`)
3. 读 `drivers/watchdog/bcm2835_wdt.c` 全文(248 行,半小时能读完),对照本篇第三/四节把 probe→start→数据流走一遍
4. **⚠️ 会复位的实验(谨慎,在能接受重启的环境)**:`echo 1 > /sys/class/watchdog/watchdog0/enable`(或 `echo x > /dev/watchdog`)启动,然后**故意不喂**——等 timeout 到,系统被硬件复位重启。这直观验证"watchdog 是独立硬件、软件不喂就复位"。
5. 思考题:bcm2835 驱动没填 `ops->ping`,那用户 `echo > /dev/watchdog` 喂狗时,最终调的是 bcm2835 的哪个函数?为什么这个函数必须"可重复调用"?(提示:`__watchdog_ping:167` 走 start 分支;start 每次都重写 PM_WDOG 重置计数器)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):
  - framework:`drivers/watchdog/watchdog_core.c`(注册/生命周期,`watchdog_register_device:367`/`___watchdog_register_device:240`/`devm_watchdog_register_device:431`)、`drivers/watchdog/watchdog_dev.c`(`/dev/watchdog` 字符设备,`watchdog_fops:992`/`watchdog_write:697`/`watchdog_ping:191`/`__watchdog_ping:144`/`watchdog_need_worker:76`)。
  - 数据结构:`include/linux/watchdog.h:47 struct watchdog_ops`、`:98 struct watchdog_device`。
  - 典型驱动:`drivers/watchdog/bcm2835_wdt.c`(树莓派,本篇走读)、`drivers/watchdog/omap_wdt.c`(TI OMAP,375 行)、`drivers/watchdog/sp805_wdt.c`(ARM PrimeCell,常见于 virt 仿真)、`drivers/watchdog/meson_gxbb_wdt.c`(Amlogic)。
- kernel.org:[Linux Watchdog Support](https://docs.kernel.org/driver-api/watchdog.html)(API 规范 + `nowayout`/`stop_on_reboot` 语义)、`Documentation/devicetree/bindings/watchdog/`(各 SoC watchdog 的设备树 binding,看 timeout-sec 等属性)。
- 关联本站:[08 panic](../debugging/08-debug-panic.md) 软 lockup 检测(软件层的"卡死报警",和 watchdog 硬件复位是两套互补机制)、[00 调试全景图](../debugging/00-debug-bug-classification.md) 的"softlockup/hardlockup";[10 platform](./10-drv-platform.md) bcm2835_wdt 是 platform 驱动(MFD 子设备)。
