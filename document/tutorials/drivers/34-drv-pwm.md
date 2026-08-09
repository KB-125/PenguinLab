---
title: "PWM:脉宽调制——背光/电机/舵机的万能旋钮"
slug: drv-pwm
prerequisites:
  - drv-model
  - drv-dts
difficulty: intermediate
tags: [driver, pwm, bcm2835, duty_cycle, backlight, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - source: third_party/linux（6.19）drivers/pwm/、include/linux/pwm.h
maturity: drafting
related:
  - /tutorials/drivers/30-drv-lcd
  - /tutorials/drivers/32-drv-hwmon
---

> 🔨 **整理中** · 这一篇拆 PWM 子系统:framework 的"状态机 apply"模型(`pwm_apply_might_sleep` 一次性原子设全状态),再拿树莓派 `pwm-bcm2835.c`(185 行,一个极简但完整的 PWM 控制器驱动)逐段走读它的 probe、`apply` 回调——重点看"纳秒 period/duty 怎么换算成硬件时钟周期数"那段数学,以及"为什么 apply 要原子"。每个 API 对照 BCM2835 PWM 硬件特性讲。动手部分在真板验过之前标"待亲测"。

## 做什么

数字 GPIO 只能输出 0 或 1,但调 LED 亮度、调电机转速、驱动舵机、出蜂鸣器音,都需要"中间值"。**PWM(Pulse Width Modulation,脉宽调制)** 用一个高频方波的**占空比**(周期内高电平占比)控制平均电压——50% 占空比方波,接 LED 看到半亮(人眼低通滤波);接电机看到一半转速(电机电感低通)。SoC 上一般有几个 PWM 控制器(每路一根输出引脚),内核 PWM 子系统统一管理。这一篇拆 framework 的状态机模型 + BCM2835 驱动怎么把"纳秒 period/duty"翻译成"硬件计数器值"。

## 要了解什么

### 〇、硬件背景:BCM2835 PWM——计数器 + 比较器

PWM 控制器的硬件本质极其简单:**一个自由计数器 + 一个比较器**(每通道一组)。以 BCM2835(树莓派)为例(`pwm-bcm2835.c`):

- **计数器**:从 0 开始,每个时钟 tick 加 1,加到 PERIOD 寄存器的值就归零重新数(锯齿波)。
- **比较器**:计数器值 < DUTY 寄存器值时输出高、≥ DUTY 时输出低。于是输出是方波:高电平占 DUTY 个 tick、低电平占 (PERIOD-DUTY) 个 tick,占空比 = DUTY/PERIOD。
- **时钟**:计数器跑在某个时钟频率 `rate`(BCM2835 默认 ~100MHz,可配)。所以 PERIOD/DUTY 寄存器存的是"时钟周期数",不是纳秒——1 个 tick = 1/rate 秒。
- **寄存器布局**(`pwm-bcm2835.c:14-24`):

```
0x00  PWM_CONTROL  控制寄存器(两通道复用,每通道占 8 bit:PWM_MODE/PWM_ENABLE/PWM_POLARITY)
0x10  PERIOD(0)   通道 0 的 period 计数值   ┐ 每通道 16 字节
0x14  DUTY(0)     通道 0 的 duty 计数值     ┘ (0x10/0x14 = 通道0; 0x20/0x24 = 通道1)
```

`PWM_CONTROL_SHIFT(x) = (x)*8`(`:16`)把通道号换算成控制寄存器里的位偏移——通道 0 在 bit 0-7、通道 1 在 bit 8-15。`PERIOD(x) = (x)*0x10 + 0x10`(`:22`)算每通道的 period 寄存器地址。

几个直接决定 API 的硬件特性:

1. **PERIOD/DUTY 存的是"时钟周期数",不是时间**:用户给的是纳秒(period_ns),硬件要的是"数多少个 tick"——得 `period_ticks = period_ns × rate / 1e9`。→ 所以 PWM `apply` 回调里有一段**纳秒→ticks 的换算**(`bcm2835_pwm_apply:67` `DIV_ROUND_CLOSEST_ULL(state->period * pc->rate, NSEC_PER_SEC)`),不是直接写纳秒。

2. **PERIOD 寄存器位数有限(32-bit)**:`period_ticks` 最大 `U32_MAX`,所以 period 能设的最大值受 rate 限制——`max_period = U32_MAX × 1e9 / rate` 纳秒。→ 所以 `apply` 里有一段 `max_period` 的数学推导(`:47-61`),超了返回 `-EINVAL`。

3. **两通道共享控制寄存器、靠位域区分**:PWM_CONTROL 一个 32-bit 寄存器管两通道(通道 0 占低 8 bit、通道 1 占高 8 bit),改通道 1 不能踩到通道 0 的位。→ 所以 `apply` 里改控制位用"读-改-写 + 位掩码"(`:82-94`,`val &= ~(MASK << SHIFT); val |= ... << SHIFT`),不能直接覆盖整个寄存器。

4. **时钟频率变了,PWM 就漂**:计数器跑在 rate 上,如果别人(别的驱动)改了这路时钟的 rate,PWM 频率跟着变。→ 所以 probe 里 `devm_clk_rate_exclusive_get`(`:126`)**独占**时钟频率,禁止别人改。

所以 PWM 的 API——`apply`(一次性原子地设 period+duty+polarity+enable)、`get_state`(读当前硬件状态)——每条对应硬件一个特性。BCM2835 只实现 `apply`(没 `get_state`),因为它的硬件足够简单。

### 一、framework 全景:状态机 apply 模型

PWM framework(`drivers/pwm/core.c`)用**状态机**模型:一个 PWM 通道的完整状态用 `struct pwm_state`(period/duty_cycle/polarity/enabled 四个字段)描述,`pwm_apply_might_sleep(pwm, &state)` 一次性原子地把整个状态写进硬件。这取代了老的分散接口(`config` + `enable` + `set_polarity` 分开调,已弃用)。

**为什么必须原子**(分步设会出问题):如果先 `set_period` 再 `set_duty`,中间状态(period 新、duty 老)可能产生一个超窄或超宽的脉冲——电机/舵机会抖、LED 会闪。一次性 apply 保证硬件看到的是"从旧状态直接切到完整新状态"。

**调用边界**:`pwm_apply_might_sleep`(`core.c:733`)→ `chip->ops->apply(chip, pwm, state)`(`:707`)。consumer(`pwm-backlight` 等)调 `pwm_apply_might_sleep`,framework 转给驱动的 `apply` 回调。名字带 `might_sleep` 是因为有些 PWM 控制器(如 I2C 扩展的 PCA9685)的 apply 走 I2C、会睡眠,不能在原子上下文调。

**注册**:驱动填 `pwm_chip`(含 `npwm` 通道数 + `ops`)→ `devm_pwmchip_add` 注册,framework 建 `/sys/class/pwm/pwmchipN/`,用户 `echo 0 > export` 暴露某通道 → `/sys/class/pwm/pwmchipN/pwm0/{period,duty_cycle,enable,polarity}`,写这些文件 → `pwm_apply_might_sleep` → 驱动 `apply`。

### 二、核心数据结构:pwm_chip / pwm_ops / pwm_state

**`struct pwm_state`**:PWM 通道的完整状态——`period`(周期,纳秒)/`duty_cycle`(占空时间,纳秒)/`polarity`(`PWM_POLARITY_NORMAL`/`INVERSED`)/`enabled`(开/关)。apply 就是把这四个一起设。

**`struct pwm_ops`**(`include/linux/pwm.h`):驱动的回调表——

```c
struct pwm_ops {
    int (*apply)(struct pwm_chip *, struct pwm_device *, const struct pwm_state *);  /* ⭐ 设全状态(现代主接口) */
    int (*get_state)(struct pwm_chip *, struct pwm_device *, struct pwm_state *);    /* 读当前硬件状态(可选) */
    int (*capture)(struct pwm_chip *, struct pwm_device *, struct pwm_capture *, ...); /* 捕获输入 PWM(可选) */
    ...
};
```

老接口(`enable`/`disable`/`config`/`set_polarity`/`calculate_*`)已弃用,新代码只实现 `apply`(加可选 `get_state`)。

**`struct pwm_chip`**:一个 PWM 控制器(多通道),含 `npwm`/`ops`/`atomic`(是否 apply 可原子,见踩坑)。6.x 用 `devm_pwmchip_alloc(dev, npwm, sizeof(priv))` 分配(内嵌私有数据),老写法是静态/手动分配。

### 三、源码走读:pwm-bcm2835.c(树莓派 PWM,185 行)

**寄存器定义 + ops 填充**(`:14`/`:101`):

```c
/* pwm-bcm2835.c:14-24 — 寄存器布局(直接对应硬件手册) */
#define PWM_CONTROL             0x000
#define PWM_CONTROL_SHIFT(x)    ((x) * 8)        /* 通道号→控制寄存器位偏移 */
#define PWM_CONTROL_MASK        0xff
#define PWM_MODE                0x80             /* MSEN2 bit:PWM 模式(vs M/S 模式) */
#define PWM_ENABLE              (1 << 0)
#define PWM_POLARITY            (1 << 4)
#define PERIOD(x)               (((x) * 0x10) + 0x10)   /* 通道 x 的 period 寄存器地址 */
#define DUTY(x)                 (((x) * 0x10) + 0x14)
#define PERIOD_MIN              0x2

/* :101 — ops:只实现 apply(没 get_state,因为简单) */
static const struct pwm_ops bcm2835_pwm_ops = {
    .apply = bcm2835_pwm_apply,
};
```

**`apply` 回调——核心的"纳秒→ticks + 原子写硬件"**(`:37`,最值得逐行看):

```c
/* pwm-bcm2835.c:37(关键段,带注释) */
static int bcm2835_pwm_apply(struct pwm_chip *chip, struct pwm_device *pwm,
                             const struct pwm_state *state)
{
    struct bcm2835_pwm *pc = to_bcm2835_pwm(chip);
    unsigned long long period_cycles;
    u64 max_period;
    u32 val;

    /* ⭐ 1. 算 period 能设的最大值(PERIOD 寄存器 32-bit,period×rate 不能溢出 U32_MAX)
     *    推导:period_cycles = period*rate/1e9 <= U32_MAX
     *    ⟹ period <= ceil((U32_MAX*1e9 + 1e9/2)/rate) - 1   */
    max_period = DIV_ROUND_UP_ULL((u64)U32_MAX * NSEC_PER_SEC + NSEC_PER_SEC / 2,
                                  pc->rate) - 1;
    if (state->period > max_period)
        return -EINVAL;

    /* ⭐ 2. 纳秒 period → 时钟周期数(ticks) */
    period_cycles = DIV_ROUND_CLOSEST_ULL(state->period * pc->rate, NSEC_PER_SEC);
    if (period_cycles < PERIOD_MIN)        /* 硬件最小周期约束 */
        return -EINVAL;
    writel(period_cycles, pc->base + PERIOD(pwm->hwpwm));   /* 写 PERIOD 寄存器 */

    /* 3. duty 同理换算 + 写 DUTY 寄存器 */
    val = DIV_ROUND_CLOSEST_ULL(state->duty_cycle * pc->rate, NSEC_PER_SEC);
    writel(val, pc->base + DUTY(pwm->hwpwm));

    /* ⭐ 4. 极性 + 使能:读-改-写 PWM_CONTROL(两通道共享,位域区分) */
    val = readl(pc->base + PWM_CONTROL);
    val &= ~(PWM_CONTROL_MASK << PWM_CONTROL_SHIFT(pwm->hwpwm));   /* 清本通道 8 bit */
    val |= PWM_MODE << PWM_CONTROL_SHIFT(pwm->hwpwm);              /* 设 PWM 模式 */
    if (state->polarity == PWM_POLARITY_NORMAL)
        val &= ~(PWM_POLARITY << PWM_CONTROL_SHIFT(pwm->hwpwm));
    else
        val |= PWM_POLARITY << PWM_CONTROL_SHIFT(pwm->hwpwm);
    if (state->enabled)
        val |= PWM_ENABLE << PWM_CONTROL_SHIFT(pwm->hwpwm);
    else
        val &= ~(PWM_ENABLE << PWM_CONTROL_SHIFT(pwm->hwpwm));
    writel(val, pc->base + PWM_CONTROL);

    return 0;
}
```

每段都对应硬件特性:`max_period` 推导对应"PERIOD 寄存器 32-bit";`period×rate/1e9` 对应"硬件存 ticks 不存纳秒";`PWM_CONTROL_SHIFT + 读改写`对应"两通道共享控制寄存器、位域区分"。整个 apply 一次写完 PERIOD/DUTY/CONTROL——**原子**,中间不出硬件可见的半状态。

**`probe` 完整流程**(`:105`):

```c
/* pwm-bcm2835.c:105(简化) */
static int bcm2835_pwm_probe(struct platform_device *pdev)
{
    chip = devm_pwmchip_alloc(dev, 2, sizeof(*pc));           /* 2 通道 + 内嵌私有数据 pc */
    pc = to_bcm2835_pwm(chip);

    pc->base = devm_platform_ioremap_resource(pdev, 0);        /* 映射 PWM 寄存器 */
    pc->clk  = devm_clk_get_enabled(dev, NULL);                /* 获取并使能时钟 */
    devm_clk_rate_exclusive_get(dev, pc->clk);                 /* ⭐ 独占时钟频率,防别人改 */
    pc->rate = clk_get_rate(pc->clk);                          /* 读时钟频率(apply 换算用) */

    chip->ops    = &bcm2835_pwm_ops;
    chip->atomic = true;        /* ⭐ 声明 apply 可原子(只 writel,不睡) */
    devm_pwmchip_add(dev, chip);
    return 0;
}
```

几个只有读源码才注意的细节:`devm_pwmchip_alloc`(6.x 新,内嵌私有数据,取代老的"手动 alloc + container_of")、`devm_clk_rate_exclusive_get` 独占时钟(关键,见踩坑)、`chip->atomic = true`(声明这个驱动 apply 不睡眠,framework 允许它在原子上下文被调)。

### 四、数据流:`echo > duty_cycle` 到硬件寄存器

1. **用户态**:`echo 500000 > /sys/class/pwm/pwmchip0/pwm0/duty_cycle`(设 50% duty,period 1ms)。
2. **sysfs**:PWM framework 的 `duty_cycle` store → 把新 duty 填进当前 `pwm_state` → 调 `pwm_apply_might_sleep(pwm, &state)`(`core.c:733`)。
3. **framework 分派**:`chip->ops->apply(chip, pwm, &state)`(`:707`)。
4. **驱动回调**:`bcm2835_pwm_apply`(`pwm-bcm2835.c:37`)→ `duty = DIV_ROUND_CLOSEST_ULL(500000 × rate, 1e9)` → `writel(duty, base + DUTY(0))` + 改 PWM_CONTROL 位域。
5. **硬件**:DUTY 寄存器更新,下一轮计数周期起,比较器按新 duty 翻转输出 → 占空比变成 50%。

整条链:`echo` → sysfs store → `pwm_apply_might_sleep:733` → `ops->apply:707` → `bcm2835_pwm_apply:37` → `writel(DUTY)`。

### 五、源码真踩坑(都是读源码才发现的)

1. **`period × rate` 的溢出与 max_period 推导**(`bcm2835_pwm_apply:47-61`)。PERIOD 寄存器 32-bit,`period_cycles = period_ns × rate / 1e9` 必须 ≤ `U32_MAX`。驱动用一段数学推导算出 `max_period`(纳秒上限),超了直接 `-EINVAL`。这不是"理论上能设多大"的问题——`period_ns × rate`(纳秒×Hz)中间值可能溢出 `u64` 边界,推导里用 `DIV_ROUND_UP_ULL` 和拆项避免溢出。换别的 SoC PWM(不同寄存器位宽),这个 max 推导完全不同。

2. **`devm_clk_rate_exclusive_get` 不能漏**(`probe:126`)。PWM 计数器跑在这路时钟上,如果别的驱动(`cpufreq`/别的 PWM 通道共用时钟)改了 rate,你设的 period(按旧 rate 算的 ticks)实际频率就漂了。`clk_rate_exclusive_get` 锁定 rate,别人改会失败。漏了这行,PWM 频率会莫名其妙漂。

3. **两通道共享控制寄存器,改一个不能踩另一个**(`apply:82-94`)。PWM_CONTROL 一个寄存器管两通道(位域),必须"读-清本通道位-设本通道位-写回",直接 `writel(新值)` 会把另一通道的配置冲掉。`PWM_CONTROL_SHIFT(channel)` 宏算位偏移。多通道 PWM 控制器几乎都这样(共享寄存器 + 位域)。

4. **`chip->atomic = true` 的含义**(`probe:127`)。声明这个驱动的 apply 只做 `writel`(不睡),framework 允许它在原子上下文被调(某些 consumer 路径要求原子)。如果驱动 apply 走 I2C/SPI(像 PCA9685),不能设 atomic,framework 会强制它在进程上下文调。bcm2835 这种 MMIO 寄存器的,设 atomic 没问题。

5. **`PERIOD_MIN` 硬件约束**(`apply:65`)。BCM2835 硬件要求 PERIOD ≥ 2,设太小(高频)硬件行为未定义。每款 PWM 控制器有自己的最小 period(数据手册给),驱动必须拒掉过小的值。

6. **apply 必须一次写全,不能分步**。状态机 apply 的设计原因:分步(先 period 后 duty)中间状态会产生错误脉冲。bcm2835 的 apply 先写 PERIOD/DUTY、最后写 CONTROL(使能)——这个顺序也讲究(配好 period/duty 再使能,避免使能瞬间跑出乱七八糟的波形)。

## 动手试试

> BCM2835 PWM 在树莓派有实物(GPIO12/13/18/19 可复用为 PWM);QEMU virt 没有标准 PWM。以下在树莓派或宿主(若有)做。

1. `ls /sys/class/pwm/`;`echo 0 > /sys/class/pwm/pwmchip0/export` 暴露通道 0 → `/sys/class/pwm/pwmchip0/pwm0/{period,duty_cycle,enable,polarity}`。
2. `echo 1000000 > period; echo 500000 > duty_cycle; echo 1 > enable`(1ms period、50% duty、开),接 LED 看半亮(或接示波器看 1kHz 方波)。
3. 读 `drivers/pwm/pwm-bcm2835.c` 全文(185 行,很短),对照本篇第三/四节走 apply 的换算 + 位操作。
4. 对照 `drivers/pwm/core.c` 的 `pwm_apply_might_sleep:733`,看 framework 怎么调 `ops->apply:707`。
5. 思考题:为什么 apply 用"状态机"(一次设 period+duty+polarity+enable),而不是分开的 `set_period`/`set_duty`/`enable`?(提示:中间状态产生错误脉冲——电机抖/LED 闪)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):
  - framework:`drivers/pwm/core.c`(`pwm_apply_might_sleep:733` → `ops->apply:707`、`devm_pwmchip_add`、sysfs in `sysfs.c`)、`include/linux/pwm.h`(`struct pwm_chip`/`struct pwm_ops`/`struct pwm_state`/`pwm_apply_might_sleep`/`devm_pwm_get`)。
  - 典型驱动:`drivers/pwm/pwm-bcm2835.c`(本篇走读)、`pwm-imx.c`(i.MX)、`pwm- rockchip.c`(瑞芯微)、`pwm-pca9685.c`(I2C 扩展 16 通道,非 atomic 走 regmap)。
- kernel.org:[PWM](https://docs.kernel.org/driver-api/pwm.html)、`Documentation/devicetree/bindings/pwm/`。
- 关联本站:[30 LCD/backlight](./30-drv-lcd.md) 背光常走 PWM(`pwm-backlight.c` 是 consumer)、PWM 引脚经 [16 pinctrl](./16-drv-pinctrl.md) 复用;`atomic` apply 概念关联 [07 drv-sync](./07-drv-sync.md) 的原子上下文。
