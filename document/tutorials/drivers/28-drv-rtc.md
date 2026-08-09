---
title: "RTC:实时钟——断电也走的时间,内核怎么读它"
slug: drv-rtc
prerequisites:
  - drv-platform
  - drv-i2c
difficulty: intermediate
tags: [driver, rtc, pcf8563, bcd, alarm, hctosys, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - source: third_party/linux（6.19）drivers/rtc/、include/linux/rtc.h
maturity: drafting
related:
  - /tutorials/drivers/23-drv-i2c
  - /tutorials/drivers/27-drv-watchdog
---

> 🔨 **整理中** · 这一篇拆 RTC 子系统:framework 怎么搭(`class.c`)、`struct rtc_device`/`rtc_class_ops` 数据结构,再拿 NXP PCF8563 的 `rtc-pcf8563.c`(592 行,一个完整的 I2C RTC 驱动)逐段走读。重点放在"RTC 硬件的特殊性为什么决定了 API 长这样"——BCD 编码、低压检测、世纪位、闹钟,每条硬件特性都对应驱动里一段带行号的代码。动手部分在真板验过之前标"待亲测"。

## 做什么

内核运行时的"墙上时间(wall clock,即 `gettimeofday` 拿到的)"靠软件维护——启动后由高精度定时器 tick 累加。但**关机断电后软件时钟消失**,下次开机如果没人告诉它"现在是几点",时间就归零了。**RTC(Real-Time Clock,实时钟)** 就是干这个的:一块**独立的硬件时钟芯片**,有自己的纽扣电池后备,SoC 断电后它照样一秒一秒地走,存着"年月日时分秒"。内核启动早期从 RTC 把时间读进 wall clock(`hctosys` 机制),从此系统时间就准了;用户态 `hwclock`/`date` 通过 RTC 设时间。RTC 还常带**闹钟**功能——到指定时刻拉一根中断线,用于"定时唤醒 suspend 的系统"。这一篇拆 RTC 子系统:先讲清 RTC 硬件(以 PCF8563 为例)的特殊性,再读 framework + 驱动源码。

## 要了解什么

### 〇、硬件背景:PCF8563——一块 I2C 接口、BCD 编码、带闹钟的实时钟

RTC 芯片很多(NXP PCF8563/DS1307/RV3028/SoC 内置),我们拿 **PCF8563**(NXP/Philips,嵌入式最常见之一)当标本——它是一颗 **I2C 接口**的 RTC,32768Hz 晶振驱动,纽扣电池后备。它的寄存器布局(`rtc-pcf8563.c:24-56`,直接对应数据手册):

```
0x00-0x01  ST1/ST2   状态寄存器(ST2 含 AIE 闹钟中断使能 / AF 闹钟触发标志)
0x02  SC   秒   ┐
0x03  MN   分   │
0x04  HR   时   │ 日期时间,全部 BCD 编码(见下)
0x05  DM   日   │
0x06  DW   星期 │
0x07  MO   月   │  (最高位 MO_C = 世纪翻转标志,见踩坑)
0x08  YR   年   ┘  (00-99,需配合 MO_C 判断世纪)
0x09-0x0C  AMN/AHR/ADM/ADW  闹钟(分/时/日/星期)
0x0D  CLKO  时钟输出(可选输出 32768/1024/32/1Hz 方波)
0x0E-0x0F  TMRC/TMR  倒数定时器
```

几个关键硬件特性,**每条都直接决定了一个 API 或驱动里一段代码**:

1. **BCD 编码**:SC/MN/HR... 这些日期时间寄存器**不是二进制,是 BCD**(每 4 位表示一个十进制数字,如秒 `59` 存成 `0x59` 而非 `0x3B`)。这是 RTC 芯片的行业惯例(方便直接显示在数码管上)。→ 所以驱动**每次读写都要 `bcd2bin`/`bin2bcd` 换算**(`rtc-pcf8563.c:172-178` 读时 `bcd2bin`、`:204-214` 写时 `bin2bcd`)。忘了换算,时间就全乱。

2. **LV(Low Voltage)低压位**:秒寄存器(`0x02`)的最高位 `PCF8563_SC_LV`(`:58`)是"低压"标志——**电池没电了、时间不可靠**。→ 所以驱动 `read_time` 读出来先检查 LV(`:158`),是低压就 `dev_err` + 返回 `-EINVAL`(宁可不返回时间,也不返回错误时间);还通过 `ioctl(RTC_VL_READ)`(`:231`)把这个状态暴露给用户态。

3. **世纪位 MO_C 的歧义**:月份寄存器(`0x07`)最高位 `PCF8563_MO_C`(`:59`)是"世纪翻转"标志——但它的语义**在不同芯片手册里不一样**:PCF8563 手册说"0 表示 20xx、1 表示 19xx",RTC8564 手册说反的(`:66-78` 驱动顶部一大段注释就是这个)。→ 所以驱动用**启发式** `c_polarity`(`:79`/`:180-181`)判断,假设系统活在 1970-2069 之间。这是个"硬件设计不一致、软件擦屁股"的典型。

4. **闹钟精度只到分钟**:闹钟寄存器(`0x09-0x0C`)只有分/时/日/星期,**没有秒**。→ 所以驱动 `set_bit(RTC_FEATURE_ALARM_RES_MINUTE, ...)`(`:516`)告诉 framework"我这闹钟精度是分钟",framework 据此拒绝用户设秒级闹钟。

5. **CLKO 时钟输出**:PCF8563 还能从 CLKO 脚输出方波(32768/1024/32/1Hz)。→ 驱动还把它注册成 **common clock framework** 的一个 `clk_hw`(`:304-455`,`CONFIG_COMMON_CLK` 下),别的驱动能 `clk_get("pcf8563-clkout")` 用它——一颗 RTC 芯片副产品当时钟源。

所以 RTC 子系统的 API——`read_time`/`set_time`(读写 BCD 时间)/`read_alarm`/`set_alarm`/`alarm_irq_enable`(闹钟+中断)/`ioctl(RTC_VL_READ)`(低压)/`read_offset`/`set_offset`(校准)——每条都对应硬件一个特性。不讲清这些硬件怪癖,驱动里那些 `bcd2bin`/LV 检查/世纪位判断就显得莫名其妙。

### 一、framework 全景:class.c 注册 + hctosys 启动读时间

RTC framework 核心(`drivers/rtc/class.c`)。驱动注册一个 RTC 设备分两步(6.x 推荐,`devm_rtc_device_register` 老接口已 deprecated,见 `class.c:454` 注释):

```c
struct rtc_device *rtc = devm_rtc_allocate_device(dev);   /* class.c:363 分配 */
rtc->ops = &my_rtc_ops;                                    /* 填 rtc_class_ops */
/* 设 features / range_min / range_max 等(见下) */
devm_rtc_register_device(rtc);                             /* class.c:392 __devm_rtc_register_device 注册 */
```

`__devm_rtc_register_device`(`class.c:392`)校验 `ops`(read_time 一般必须有)、建 `/sys/class/rtc/rtcN/` + `/dev/rtcN`、把它挂进 RTC 设备列表。

framework 还有个关键的**启动钩子 `hctosys`(Hardware Clock to System)**:内核启动后期,对所有标了 `CONFIG_RTC_HCTOSYS_DEVICE` 的 RTC,调它的 `read_time` 把硬件时间读进 wall clock——这就是"开机后系统时间立刻准"的机制。没它,每次开机时间都归零。

### 二、核心数据结构:rtc_class_ops / rtc_device

**`struct rtc_class_ops`**(`include/linux/rtc.h:59`)——驱动填的回调:

```c
struct rtc_class_ops {                 /* rtc.h:59 */
    int (*ioctl)(struct device *, unsigned int, unsigned long);
    int (*read_time)(struct device *, struct rtc_time *);       /* 读时间(必填,框架 + hctosys 都靠它) */
    int (*set_time)(struct device *, struct rtc_time *);        /* 写时间 */
    int (*read_alarm)(struct device *, struct rtc_wkalrm *);    /* 读闹钟 */
    int (*set_alarm)(struct device *, struct rtc_wkalrm *);     /* 设闹钟 */
    int (*alarm_irq_enable)(struct device *, unsigned int);     /* 开关闹钟中断 */
    int (*read_offset)(struct device *, long *);                /* 校准偏移 */
    int (*set_offset)(struct device *, long);
    ...
};
```

`read_time` 基本是必填的(hctosys 和用户态读时间都靠它);闹钟相关的只有芯片支持闹钟 + 有 IRQ 线才填。时间用 `struct rtc_time`(`tm_sec/min/hour/mday/mon/year/wday`,注意 `mon` 是 0-11、`year` 是从 1900 起的偏移如 2024 年 = 124)。

**`struct rtc_device`**(`rtc.h:87`):一个 RTC 实例,含 `ops`/`features`(位图,声明能力如 `RTC_FEATURE_ALARM`/`RTC_FEATURE_ALARM_RES_MINUTE`)/`range_min`/`range_max`(时间范围,framework 据此校验用户设的时间不越界)。`RTC_TIMESTAMP_*` 宏(`rtc.h:171-179`)是预定义的时间范围常量(如 `RTC_TIMESTAMP_BEGIN_2000 = 2000-01-01`、`END_2099`),驱动按芯片能表示的范围选——PCF8563 年寄存器只有 00-99 + 世纪位,所以 pcf8563 设 `range_min = BEGIN_2000`、`range_max = END_2099`(`rtc-pcf8563.c:519-520`)。

### 三、源码走读:rtc-pcf8563.c(NXP PCF8563 驱动,592 行)

**ops 填充**(`:458`):

```c
/* rtc-pcf8563.c:458 */
static const struct rtc_class_ops pcf8563_rtc_ops = {
    .ioctl            = pcf8563_rtc_ioctl,        /* RTC_VL_READ 低压状态 */
    .read_time        = pcf8563_rtc_read_time,    /* :147 */
    .set_time         = pcf8563_rtc_set_time,     /* :192 */
    .read_alarm       = pcf8563_rtc_read_alarm,   /* :244 */
    .set_alarm        = pcf8563_rtc_set_alarm,    /* :277 */
    .alarm_irq_enable = pcf8563_irq_enable,       /* :296 */
};
```

**`read_time`——最核心的"和硬件打交道 + BCD 换算"**(`:147`),逐段看:

```c
/* rtc-pcf8563.c:147(关键段) */
static int pcf8563_rtc_read_time(struct device *dev, struct rtc_time *tm)
{
    struct pcf8563 *pcf8563 = dev_get_drvdata(dev);
    unsigned char buf[9];
    int err;

    /* 一次性从 0x00 bulk-read 9 字节(状态+日期时间) */
    err = regmap_bulk_read(pcf8563->regmap, PCF8563_REG_ST1, buf, sizeof(buf));
    if (err < 0) return err;

    /* ⭐ LV 低压检查:电池没电,时间不可靠,直接报错 */
    if (buf[PCF8563_REG_SC] & PCF8563_SC_LV) {                /* :158 */
        dev_err(dev, "low voltage detected, date/time is not reliable.\n");
        return -EINVAL;
    }

    /* ⭐ BCD → 二进制:bcd2bin,每字段还要 & 掩码去掉控制位(如秒的 LV 位、月的 MO_C 位) */
    tm->tm_sec  = bcd2bin(buf[PCF8563_REG_SC] & 0x7F);        /* :172 &0x7F 去掉 LV 位 */
    tm->tm_min  = bcd2bin(buf[PCF8563_REG_MN] & 0x7F);
    tm->tm_hour = bcd2bin(buf[PCF8563_REG_HR] & 0x3F);
    tm->tm_mday = bcd2bin(buf[PCF8563_REG_DM] & 0x3F);
    tm->tm_wday = buf[PCF8563_REG_DW] & 0x07;                  /* 星期不用 BCD(1-7 直存) */
    tm->tm_mon  = bcd2bin(buf[PCF8563_REG_MO] & 0x1F) - 1;    /* :177 &0x1F 去掉 MO_C 位;-1 因为 tm_mon 0-11 */
    tm->tm_year = bcd2bin(buf[PCF8563_REG_YR]) + 100;          /* :178 +100 因为 tm_year 从 1900 起,2000 年=100 */

    /* ⭐ 世纪位启发式:判断 c_polarity(见硬件背景第 3 点) */
    pcf8563->c_polarity = (buf[PCF8563_REG_MO] & PCF8563_MO_C) ?
        (tm->tm_year >= 100) : (tm->tm_year < 100);            /* :180 */
    return 0;
}
```

每一行都有来头:`& 0x7F`/`0x3F`/`0x1F` 是去掉寄存器里复用的控制位(LV/MO_C)、`bcd2bin` 是 BCD→二进制、`- 1` 是月从 1-12 转 tm_mon 的 0-11、`+ 100` 是年从"00-99"转 tm_year 的"从 1900 起"。`set_time`(`:192`)是逆操作:`bin2bcd` + 加回控制位。这种"每字段掩码+换算"的繁琐,正是 RTC 驱动的特色——全由硬件"BCD 编码 + 控制位复用"决定。

**`probe` 完整流程**(`:473`):

```c
/* rtc-pcf8563.c:473(简化,保留关键) */
static int pcf8563_probe(struct i2c_client *client)
{
    /* 1. 检查 I2C adapter 能力 */
    if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C)) return -ENODEV;

    pcf8563 = devm_kzalloc(&client->dev, sizeof(*pcf8563), GFP_KERNEL);
    pcf8563->regmap = devm_regmap_init_i2c(client, &regmap_config);  /* regmap 8-bit reg/val */
    i2c_set_clientdata(client, pcf8563);
    device_set_wakeup_capable(&client->dev, 1);                       /* 能唤醒系统 */

    /* 2. 硬件初始化:设最低频率省电 + 清状态/关中断 */
    regmap_set_bits(pcf8563->regmap, PCF8563_REG_TMRC, PCF8563_TMRC_1_60);
    regmap_write(pcf8563->regmap, PCF8563_REG_ST2, 0);

    /* 3. 分配 RTC 设备 + 填能力 */
    pcf8563->rtc = devm_rtc_allocate_device(&client->dev);            /* class.c:363 */
    pcf8563->rtc->ops = &pcf8563_rtc_ops;
    set_bit(RTC_FEATURE_ALARM_RES_MINUTE, pcf8563->rtc->features);    /* 闹钟精度分钟 */
    pcf8563->rtc->range_min = RTC_TIMESTAMP_BEGIN_2000;               /* 时间范围 2000-2099 */
    pcf8563->rtc->range_max = RTC_TIMESTAMP_END_2099;
    pcf8563->rtc->set_start_time = true;

    /* 4. 如果有 IRQ 线:申请闹钟中断(threaded,因 I2C 读寄存器可能睡)+ 使能唤醒 */
    if (client->irq > 0) {
        devm_request_threaded_irq(&client->dev, client->irq, NULL, pcf8563_irq,
                                  IRQF_SHARED | IRQF_ONESHOT | IRQF_TRIGGER_LOW, ...);
        device_init_wakeup(&client->dev, true);                       /* 闹钟能唤醒 suspend */
        set_bit(RTC_FEATURE_ALARM, pcf8563->rtc->features);
    }

    /* 5. 注册 */
    err = devm_rtc_register_device(pcf8563->rtc);                     /* class.c:392 */
    /* 6. 可选:注册 CLKO 成 common clk */
    #ifdef CONFIG_COMMON_CLK
    pcf8563_clkout_register_clk(pcf8563);
    #endif
    return 0;
}
```

注意 `devm_request_threaded_irq`(`:529`)——闹钟中断用**线程化**中断(thread_fn = `pcf8563_irq`),因为 ISR 里要 `regmap_read`(I2C)读 AF 标志,I2C 传输可能睡眠,硬中断里不能睡,所以走线程化。`pcf8563_irq`(`:124`)读到 AF 标志后 `rtc_update_irq` 通知 framework"闹钟触发了",framework 再通知用户态等待者(`select`/`read` `/dev/rtcN`)。

### 四、数据流:`hwclock -r` 到硬件寄存器

1. **用户态**:`hwclock -r`(或 `cat /sys/class/rtc/rtc0/since_epoch`、`ioctl(/dev/rtcN, RTC_RD_TIME, &tm)`)。
2. **framework**:根据入口(sysfs 的 `since_epoch` show / `rtc-dev.c` 的 `ioctl RTC_RD_TIME`)调 `rtc->ops->read_time(dev, &tm)`。
3. **驱动回调**:`pcf8563_rtc_read_time`(`rtc-pcf8563.c:147`)→ `regmap_bulk_read(regmap, 0x00, buf, 9)` → 走 I2C 读 9 字节。
4. **I2C 层**:`regmap` → `i2c_transfer` → SoC 的 I2C 控制器发"读 PCF8563 地址(0x51)从寄存器 0x00 起 9 字节"。
5. **硬件**:PCF8563 把 0x00-0x08 的 9 字节(状态+秒分时日星期月年,BCD 编码)回送。
6. 回到驱动:`& 掩码` 去控制位 + `bcd2bin` 换算 + LV 检查 → 填 `tm`。
7. framework 拿到 `tm`,转 Unix 时间戳返回给用户态。

整条链每步都在源码里:`hwclock` → `read_time` 回调(`rtc-pcf8563.c:147`)→ `regmap_bulk_read`(:153)→ I2C → 硬件 BCD 寄存器 → `bcd2bin`(:172)→ `tm`。

### 五、源码真踩坑(都是读源码才发现的)

1. **BCD 编码是 RTC 的"标配坑"**(`:172/204`)。所有日期时间字段读写都要 `bcd2bin`/`bin2bcd`,漏一处时间就错。这是 RTC 芯片的行业惯例(BCD 方便直接驱动数码管显示),不是 PCF8563 独有——DS1307/RV3028 大多也 BCD。内核 `<linux/bcd.h>` 提供换算函数。

2. **LV 低压位——电池没电的"诚实报告"**(`:158`)。电池电压低于阈值,秒寄存器最高位 LV=1,时间可能已错乱。驱动**不返回错误数据**,而是返回 `-EINVAL`,让用户态知道"该换电池了"。`ioctl(RTC_VL_READ)`(`:231`)把 LV 暴露给用户态,`hwclock` 能显示警告。

3. **世纪位 MO_C 的跨芯片歧义**(`:66-78` 注释 + `:180` 启发式)。PCF8563 和 RTC8564(兼容芯片)对 MO_C 位语义定义相反,驱动没法可靠区分,只能用启发式假设"当前在 1970-2069"。这是"硬件设计不一致、软件擦屁股"的典型——读到驱动顶部那一大段注释就知道作者被坑过。

4. **闹钟寄存器没秒**(`:283-286`/`:516`)。PCF8563 闹钟只有分/时/日/星期,驱动 `set_bit(RTC_FEATURE_ALARM_RES_MINUTE)` 告诉 framework,framework 据此拒绝用户设秒级闹钟(返回 -EINVAL)。不同 RTC 闹钟精度不同,必须如实声明 features。

5. **闹钟中断必须线程化**(`:529 devm_request_threaded_irq`)。ISR 要 I2C 读 AF 标志(regmap 可能睡),硬中断不能睡,所以用 threaded_irq。这是"I2C/SPI 设备的中断"的通用约束——凡 ISR 里要碰总线传输的,都要线程化([12 线程化中断](./12-drv-threaded-irq.md))。

6. **`set_start_time = true`**(`:521`)。首次注册时把当前时间写进 RTC——防止 RTC 从未设过时间(出厂状态)时读到全 0。

7. **CLKO 副产品当 clk**(`:304-455`)。PCF8563 的方波输出脚被注册成 common clk framework 的一个时钟源,别的设备能 `clk_get` 用它——一颗 RTC 芯片"兼职"时钟发生器。这体现了 Linux 子系统间的复用(RTC 驱动同时是 clk provider)。

## 动手试试

> RTC 在多数 SoC/真板上有实物;QEMU virt 没有标准 RTC(可挂 `-device mc146818rtc` 在 x86、或用 PL031 在 ARM)。以下在真板或宿主机做。

1. `ls /sys/class/rtc/`;`cat /sys/class/rtc/rtc0/{date,time,since_epoch,hctosys}` —— `hctosys=1` 说明这个 RTC 启动时被 hctosys 读了时间进 wall clock。
2. `hwclock`(宿主)读 RTC;`hwclock -w`(软件时间写进 RTC)/`hwclock -s`(RTC 时间设为系统)。
3. 读 `drivers/rtc/rtc-pcf8563.c` 全文(592 行),对照本篇第三/四节走一遍 read_time 的 BCD 换算 + LV 检查。
4. 闹钟实验:`echo +5 > /sys/class/rtc/rtc0/wakealarm`(5 秒后触发),等中断;`cat /proc/interrupts | grep rtc` 看闹钟中断计数。
5. 思考题:为什么 `read_time` 里每个字段都要 `& 0x7F`/`0x3F`/`0x1F` 不同的掩码?这些掩码对应硬件的什么?(提示:寄存器位复用——秒的 LV 位、月的 MO_C 位、时/日的"12/24 小时"控制位等)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):
  - framework:`drivers/rtc/class.c`(`devm_rtc_allocate_device:363`/`__devm_rtc_register_device:392`)、`drivers/rtc/rtc-dev.c`(`/dev/rtcN` 字符设备 + `RTC_RD_TIME`/`RTC_ALM_*` ioctl)、`drivers/rtc/rtc-sysfs.c`(`/sys/class/rtc/` 属性)、`drivers/rtc/hctosys.c`(启动读时间进 wall clock)。
  - 数据结构:`include/linux/rtc.h:59 struct rtc_class_ops`、`:87 struct rtc_device`、`:171-179 RTC_TIMESTAMP_*`。
  - 典型驱动:`drivers/rtc/rtc-pcf8563.c`(本篇走读)、`rtc-ds1307.c`(DS1307/DS1339,经典 I2C RTC)、`rtc-rv3028.c`(现代低功耗)、`rtc-pl031.c`(ARM PrimeCell,常见于 virt 仿真)、SoC 内置如 `rtc-meson.c`。
- 数据手册:[PCF8563 PDF](https://www.nxp.com/docs/en/data-sheet/PCF8563.pdf)(驱动源码 `:11` 引的就是它)——对照寄存器布局看驱动每个宏定义。
- 关联本站:[23 i2c](./23-drv-i2c.md) PCF8563 挂 I2C、regmap 走 I2C 传输;[12 threaded-irq](./12-drv-threaded-irq.md) 闹钟中断线程化;`rtc_time` ↔ time64 换算见 [12 内核数据结构](../foundations/12-kernel-data-structures.md) 的时间处理。
