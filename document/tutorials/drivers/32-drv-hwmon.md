---
title: "hwmon:硬件监控——温度/电压/风扇转速的统一框架"
slug: drv-hwmon
prerequisites:
  - drv-platform
  - drv-i2c
difficulty: intermediate
tags: [driver, hwmon, lm75, temperature, sensors, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - source: third_party/linux（6.19）drivers/hwmon/、include/linux/hwmon.h
maturity: drafting
related:
  - /tutorials/drivers/23-drv-i2c
  - /tutorials/drivers/27-drv-watchdog
---

> 🔨 **整理中** · 这一篇拆 hwmon 子系统:framework 怎么从一张 `hwmon_chip_info` 表自动生成 `/sys/class/hwmon/` 下那一堆 `temp1_input`/`in0_min` 文件、怎么在用户 `cat` 时分派到驱动回调,再拿 NXP **LM75** 的 `lm75.c`(1141 行,I2C 温度传感器,hwmon 最经典的驱动之一)逐段走读它的 chip_info 配置、`read` 回调、单位换算、多芯片变体处理。每个 API 都对照 LM75 硬件的特性讲。动手部分在真板/宿主验过之前标"待亲测"。

## 做什么

服务器和嵌入式板子上散布着各种"硬件状态读数"传感器:CPU/板温、电源电压(3.3V/5V/12V)、电流、风扇转速、机箱入侵...它们来自不同硬件(CPU 内部 MSR、Super I/O 芯片、I2C/SPI 传感器、BMC),读法各异。**hwmon(Hardware Monitoring)** 子系统给它们一套统一抽象 + 标准 sysfs 接口:不论传感器在哪、怎么读,用户态都从 `/sys/class/hwmon/hwmonN/<type><ch>_<attr>` 读到统一格式的值(milli-unit),`sensors` 命令就是遍历这套 sysfs 打印。这一篇拆 framework 的"类型+通道+属性"模型 + 自动 sysfs 生成,再走读 LM75 这个典型。

## 要了解什么

### 〇、硬件背景:LM75——I2C 接口的数字温度传感器

要懂 hwmon 的 API(尤其"为什么 read 回调要做那种位运算换算"),得先懂温度传感器硬件。**LM75**(NXP/TI,经典中的经典)是一颗 I2C 接口的数字温度计:

- **内部结构**:温度感应元件(硅带隙,温度→电压) + ΔΣ ADC 周期采样,把温度数字化存进寄存器;不需要 CPU 干预,自己周期性地刷新温度值。
- **寄存器布局**(I2C 偏移,直接对应 `lm75.c:84-95` 的宏):
  - `0x00` 温度寄存器:**16-bit 补码**,有效位 9-12bit(精度可配),高位是符号位。LSB = 2^(resolution-8) °C——9bit 时 LSB=0.5°C、12bit 时 0.0625°C。
  - `0x01` 配置寄存器:设分辨率(9-12bit)、工作模式(正常/关断/比较/中断)。
  - `0x02`/`0x03` THYST/TOS:欠温/超温阈值,可触发 OS(over-limit shutdown)引脚。
  - I2C 地址 `0x48-0x4F`(8 个可选,A0-A2 地址脚配)。
- **采样周期随分辨率**:9bit ~100ms、12bit ~400ms(分辨率越高越慢)。

几个直接决定 API 的硬件特性:

1. **温度是补码、不是 BCD、有效位随分辨率变**:读 0x00 拿到 16-bit 补码,要按当前 resolution 取有效位、再换算成毫摄氏度。→ 所以 hwmon `read` 回调里有个**位运算换算** `lm75_reg_to_mc`(`lm75.c:346`),不是简单的"读个值乘 1000"。这是 LM75 硬件(可配精度 + 补码)逼出来的。

2. **多档阈值 + 中断**:TOS/THYST 寄存器存上下界,超界触发 OS 引脚(可接 SoC GPIO 当中断)。→ 所以 hwmon 暴露 `temp1_max`/`temp1_max_hyst`/`temp1_max_alarm`(超界告警)这一组属性,`write` 回调能设阈值。

3. **LM75 系列兼容芯片一大堆,配置位不一样**:LM75A/DS75/TMP102/PCT2075... 都是"LM75 兼容",但配置寄存器的 set/clr 掩码、分辨率、采样时间各不同。→ 所以驱动用一张 `device_params[]` 表(`lm75.c:131-344`)描述每款芯片的差异,probe 时按芯片 ID 选对应参数——这是 hwmon 驱动处理"一族兼容芯片"的典型套路。

所以 hwmon 的 API——`read`(读传感器值 + 换算)、`write`(设阈值)、`is_visible`(声明哪些属性可读/可写)——每条都对应硬件一个特性。

### 一、framework 全景:chip_info 驱动的"自动 sysfs 生成"

hwmon framework(`drivers/hwmon/hwmon.c`)的精髓是:**驱动只声明"我这芯片能提供哪些类型的哪些通道的哪些属性"(一张位图表),framework 自动生成对应的 sysfs 文件,并在用户读/写时分派到驱动的 `read`/`write` 回调**。驱动完全不用手建 sysfs。

**声明用 `HWMON_CHANNEL_INFO` 宏**(`include/linux/hwmon.h:440`):

```c
/* hwmon.h:440 — 展开成一个 hwmon_channel_info,config 是 u32 位图 */
#define HWMON_CHANNEL_INFO(stype, ...)                  \
    (&(const struct hwmon_channel_info) {               \
        .type   = hwmon_##stype,                         /* 类型:temp/in/curr/fan/... */
        .config = (const u32 []) { __VA_ARGS__, 0 }      /* 每通道一个 u32,位图声明属性 */
    })
```

驱动把所有通道塞进 `hwmon_chip_info.info[]` 数组(每个元素一类),framework 注册时(`devm_hwmon_device_register_with_info`)遍历这张表、**为每个"通道×属性"组合自动创建一个 sysfs 文件**(`temp1_input`/`temp1_max`/`in0_min`...)。属性权限(可读/可写/不存在)由驱动的 `is_visible` 回调决定(`hwmon.c:158` 调 `ops->is_visible(drvdata, type, attr, channel)` 返回 mode)。

**用户读时的分派**:用户 `cat /sys/class/hwmon/hwmon0/temp1_input` → framework 的 sysfs `show` 回调 → 解析出"这是 temp 类、第 0 通道、input 属性" → 调 `ops->read(dev, hwmon_temp, hwmon_temp_input, 0, &val)`(`hwmon.c:172`)→ 驱动返回值 → framework 格式化进 sysfs。写同理,`ops->write`(`hwmon.c:203`)。这套"(type, channel, attr)三元组 → 回调"的分派,让一个 `read` 回调处理该芯片所有属性(switch 分支)。

### 二、核心数据结构:hwmon_chip_info / hwmon_ops / hwmon_channel_info

**`struct hwmon_chip_info`**(`hwmon.h:453`):一张芯片的"能力声明"——

```c
struct hwmon_chip_info {                  /* hwmon.h:453 */
    const struct hwmon_channel_info **info;   /* 各类的通道信息数组(temp 类、in 类...) */
    const struct hwmon_ops *ops;              /* read/write/is_visible 回调 */
};
```

**`struct hwmon_ops`**(`hwmon.h:417`):三个回调——

```c
struct hwmon_ops {                        /* hwmon.h:417 */
    umode_t (*is_visible)(const void *, enum hwmon_sensor_types, u32, int);  /* 该属性的权限(0444/0644/0) */
    int (*read)(const void *, enum hwmon_sensor_types, u32 attr, int channel, long *val);
    int (*write)(const void *, enum hwmon_sensor_types, u32 attr, int channel, long val);
};
```

`read`/`write` 的参数是 `(drvdata, type, attr, channel, val)`——一个回调靠 `switch(type) switch(attr)` 处理该芯片所有属性,`channel` 区分同类多通道(如 8 路温度的 temp1/temp2/.../temp8)。

类型(`enum hwmon_sensor_types`):`hwmon_chip`/`hwmon_temp`/`hwmon_in`(电压)/`hwmon_curr`/`hwmon_fan`/`hwmon_pwm`/`hwmon_power`...;属性位(每类一组):`HWMON_T_INPUT`/`HWMON_T_MAX`/`HWMON_T_MAX_HYST`/`HWMON_T_ALARM`/`HWMON_T_MIN`...(温度类)、`HWMON_I_INPUT`/`HWMON_I_MIN`/`HWMON_I_MAX`...(电压类)。这些位标志既是"声明能力"(写进 chip_info.config),又是"回调里 switch 的 attr 值"。

### 三、源码走读:lm75.c(NXP LM75 及兼容芯片,1141 行)

**chip_info + ops 填充**(`:552`):

```c
/* lm75.c:552 — 声明能力:chip 类(update_interval) + temp 类(input/max/max_hyst/alarm) */
static const struct hwmon_channel_info * const lm75_info[] = {
    HWMON_CHANNEL_INFO(chip,        /* :553 芯片级:update_interval 属性 */
                       HWMON_C_REGISTER_TZ | HWMON_C_UPDATE_INTERVAL),
    HWMON_CHANNEL_INFO(temp,        /* :555 温度类:第 0 通道有 input/max/max_hyst/alarm */
                       HWMON_T_INPUT | HWMON_T_MAX | HWMON_T_MAX_HYST | HWMON_T_ALARM),
    NULL
};

static const struct hwmon_ops lm75_hwmon_ops = {     /* :561 */
    .is_visible = lm75_is_visible,
    .read       = lm75_read,
    .write      = lm75_write,
};

static const struct hwmon_chip_info lm75_chip_info = { /* :565 */
    .ops  = &lm75_hwmon_ops,
    .info = lm75_info,
};
```

framework 拿这张表自动生成 `/sys/class/hwmon/hwmonN/`:`temp1_input`/`temp1_max`/`temp1_max_hyst`/`temp1_alarm`/`update_interval`(权限由 `lm75_is_visible` 决定)。LM75 只有一个温度通道,所以是 `temp1_*`(channel=0→序号 1)。

**`read` 回调——核心的"按 attr 读硬件 + 换算"**(`:366`,关键段):

```c
/* lm75.c:366 */
static int lm75_read(struct device *dev, enum hwmon_sensor_types type,
                     u32 attr, int channel, long *val)
{
    struct lm75_data *data = dev_get_drvdata(dev);
    unsigned int regval;
    int err, reg;

    switch (type) {
    case hwmon_temp:
        switch (attr) {                       /* 按 attr 选寄存器 */
        case hwmon_temp_input:    reg = LM75_REG_TEMP; break;
        case hwmon_temp_max:      reg = LM75_REG_MAX;  break;   /* TOS */
        case hwmon_temp_max_hyst: reg = LM75_REG_HYST; break;
        case hwmon_temp_alarm:    reg = LM75_REG_CONF; break;
        default: return -EINVAL;
        }
        err = regmap_read(data->regmap, reg, &regval);   /* I2C 读寄存器 */
        if (err < 0) return err;
        if (attr == hwmon_temp_alarm) {
            /* alarm 位:不同芯片位位置不同,按 kind 取 */
            ...
        } else {
            *val = lm75_reg_to_mc(regval, data->resolution);  /* :410 ⭐ 换算成毫摄氏度 */
        }
        break;
    case hwmon_chip:                          /* update_interval = 采样周期 */
        if (attr == hwmon_chip_update_interval) { *val = data->sample_time; ... }
        ...
    }
    return 0;
}
```

**单位换算的位操作**——这是 LM75 硬件逼出来的核心逻辑(`:346`):

```c
/* lm75.c:346 — 把 16-bit 补码寄存器值换算成毫摄氏度 */
static inline long lm75_reg_to_mc(s16 temp, u8 resolution)
{
    return ((temp >> (16 - resolution)) * 1000) >> (resolution - 8);
}
```

这一行信息量极大:`temp` 是 16-bit 补码(读出的原始值);`resolution` 是当前精度(9-12)。`temp >> (16-resolution)` 把有效位右移到低位(9bit 时右移 7 位,取低 9 位有效);`* 1000` 转毫摄氏度;`>> (resolution-8)` 除以 LSB 的毫度数(9bit 时 LSB=0.5°C=500milli-degree,右移 1 位 = 除 2)。换算结果:一个 `long` 毫摄氏度值,framework 直接写进 `temp1_input`。这种"补码 + 可变精度 + 位运算"换算,是温度传感器驱动的特色——没有这步,读出来的温度是错的。

**`probe` 完整流程**(`lm75_generic_probe:710`,I2C probe 走它):

```c
/* lm75.c:710(简化,保留关键) */
static int lm75_generic_probe(struct device *dev, const char *name,
                              enum lm75_type kind, int irq, struct regmap *regmap)
{
    data = devm_kzalloc(dev, sizeof(*data), GFP_KERNEL);
    data->regmap = regmap;
    data->kind = kind;
    data->params = &device_params[kind];              /* ⭐ 按芯片型号选参数表(掩码/分辨率/采样时间) */
    data->sample_time = data->params->default_sample_time;
    data->resolution  = data->params->default_resolution;

    /* 读当前配置 + 按 params 的 set_mask/clr_mask 改配置(设分辨率等) */
    regmap_read(data->regmap, LM75_REG_CONF, &status);
    data->orig_conf = status;
    lm75_write_config(data, data->params->set_mask, data->params->clr_mask);

    devm_add_action_or_reset(dev, lm75_remove, data);  /* 注册逆操作(恢复 orig_conf) */

    hwmon_dev = devm_hwmon_device_register_with_info(dev, name, data, &lm75_chip_info, NULL);

    /* 可选:alarm 中断(部分芯片有 OS 引脚接 IRQ) */
    if (irq && data->params->alarm)
        devm_request_threaded_irq(dev, irq, NULL, lm75_alarm_handler, IRQF_ONESHOT, ...);

    return 0;
}
```

**多芯片变体的 `device_params[]` 表**(`:131-344`)——这是 LM75 驱动处理"一族兼容芯片"的核心。每款芯片一项:

```c
/* lm75.c:131-344(每款芯片一项,示例) */
[as6200] = {                          /* TI AS6200 */
    .config_reg_16bits = true,        /* ⭐ 配置寄存器是 16 位(其他 LM75 兼容是 8 位!) */
    .set_mask = 0x94C0,
    .default_resolution = 12,
    .default_sample_time = 125,
    .alarm = true,
},
[lm75b] = {                           /* TI LM75B */
    .set_mask = 0x10,                 /* 不同的掩码 */
    .default_resolution = 11,
    .default_sample_time = 100,
    ...
},
```

每款的 `set_mask`/`clr_mask`(配置寄存器要 set/clr 的位)、`default_resolution`/`default_sample_time`、`config_reg_16bits`(配置寄存器 8 还是 16 位)、`alarm`(有没有超温告警引脚)都不同。驱动按 `kind`(从设备树 `compatible` / `i2c_get_match_data` 拿)选对应项。这种"一张参数表描述一族芯片"是处理兼容芯片的标准套路——换芯片不改代码,只加表项。

**I2C regmap 自定义总线**(`:582`):LM75 兼容芯片读温度/阈值用 `i2c_smbus_read_word_swapped`(高低字节交换),但配置寄存器有的是 8bit 有的是 16bit(`config_reg_16bits`),所以驱动注册一个**自定义 regmap 总线**(`lm75_i2c_regmap_bus`,`:582` 的 `lm75_i2c_reg_read`/`reg_write`),按寄存器类型选 byte/word 读取——而不是用 `devm_regmap_init_i2c` 的默认 SMBus。这也是"一族芯片寄存器宽度不统一"逼出来的细节。

### 四、数据流:`cat temp1_input` 到 LM75 温度寄存器

1. **用户态**:`cat /sys/class/hwmon/hwmon0/temp1_input`(或 `sensors`)。
2. **sysfs**:framework 的 `tempN_input` show 回调 → 解析出 `(hwmon_temp, hwmon_temp_input, channel=0)`。
3. **framework 分派**:调 `ops->read(dev, hwmon_temp, hwmon_temp_input, 0, &val)`(`hwmon.c:172`)。
4. **驱动回调**:`lm75_read`(`lm75.c:366`)→ switch 命中 `hwmon_temp_input` → `reg = LM75_REG_TEMP` → `regmap_read(regmap, LM75_REG_TEMP, &regval)`。
5. **regmap → I2C**:`lm75_i2c_reg_read`(`:582`,自定义总线)→ `i2c_smbus_read_word_swapped(client, LM75_REG_TEMP)` → SoC I2C 控制器读 LM75 的 0x00 寄存器。
6. **硬件**:LM75 返回 16-bit 补码温度(ADC 上次采样值)。
7. **换算**:`lm75_reg_to_mc(regval, data->resolution)`(`:346`)→ 毫摄氏度 `long`。
8. framework 拿到 `*val`,格式化写进 sysfs(`35000` = 35.000°C)。

整条链每步在源码里:`cat` → `ops->read:172` → `lm75_read:366` → `regmap_read` → `lm75_i2c_reg_read:582` → I2C → LM75 → `lm75_reg_to_mc:346`。

### 五、源码真踩坑(都是读源码才发现的)

1. **单位换算不是"乘 1000"那么简单**(`lm75.c:346`)。LM75 温度是补码 + 精度可变(9-12bit),换算要"右移取有效位 + 乘 1000 + 再右移除 LSB"。如果直接 `regval * 1000 / 256`,9-bit 模式下精度对不上、符号位也可能错。这种位运算换算是温度传感器(可变精度补码)的特色,电压/电流类(固定精度)就没这么绕。

2. **配置寄存器宽度跨芯片不一致**(`:582`/`device_params.config_reg_16bits`)。LM75 经典款配置寄存器是 8-bit,但 AS6200 等"兼容"芯片是 16-bit。驱动用自定义 regmap 总线按 `config_reg_16bits` 标志选 `read_byte_data`/`read_word_data`——用默认 `devm_regmap_init_i2c` 会对部分芯片读错配置。

3. **多芯片变体的 set_mask/clr_mask 必须按芯片选**(`:131-344`)。设分辨率/模式要写配置寄存器,但每款的掩码位不同,写错掩码会把芯片设进未定义状态。驱动用 `device_params[kind].set_mask/clr_mask` 精确控制——这就是为什么 LM75 驱动那张表那么长(几十款兼容芯片)。

4. **alarm IRQ 是可选的、按芯片**(`:710`/`device_params.alarm`)。只有 `alarm=true` 的芯片才有 OS 超温输出引脚、能接中断;没有的芯片 probe 时即使设备树给了 IRQ 也用不上(`dev_err "alarm interrupt is not supported"`)。别假设所有 LM75 兼容芯片都支持 alarm。

5. **采样周期 ≠ 读取即时性**(`device_params.default_sample_time`)。LM75 自己周期采样(100-400ms),`cat temp1_input` 读到的是"上次 ADC 采样值",不是这一瞬间的温度——刚启动时可能读到上电默认值。`update_interval` 属性暴露这个采样周期,告诉用户态"这值多久刷一次"。

6. **probe 改了配置、remove 要恢复**(`:710` `devm_add_action_or_reset(lm75_remove)`)。probe 按 set_mask/clr_mask 改了配置寄存器(设分辨率等),卸载时 `lm75_remove` 恢复 `orig_conf`——否则模块卸了芯片还停在非默认配置。devm_ 的 action 机制保证即使 probe 中途失败也会回滚。

## 动手试试

> LM75 在真板/Arduino 扩展板上常见;QEMU virt 没有标准 hwmon(可挂 virtio 或用 SoC 内置温度)。以下在宿主机或真板做。

1. `sensors`(装 lm-sensors)看所有 hwmon 读数;`ls /sys/class/hwmon/`;`cat /sys/class/hwmon/hwmonN/{name,temp1_input}`(除 1000 得摄氏度)。
2. `cat /sys/class/hwmon/hwmonN/update_interval`(若有)看采样周期;`cat /sys/class/hwmon/hwmonN/temp1_max`/`temp1_max_alarm`(若有)看阈值/告警。
3. 读 `drivers/hwmon/lm75.c` 的 `device_params[]`(`:131-344`)看几十款兼容芯片的参数差异,体会"一张表处理一族芯片"。
4. 对照本篇第三/四节,把 `lm75_read:366` 的 switch + `lm75_reg_to_mc:346` 换算走一遍。
5. 思考题:为什么 framework 用"chip_info 位图声明能力 + 自动生成 sysfs",而不是让驱动手建每个 sysfs 文件?(提示:统一命名/权限 + 少写大量样板 + `sensors` 工具能通用解析)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):
  - framework:`drivers/hwmon/hwmon.c`(注册 + sysfs 自动生成 + 调 `ops->is_visible:158`/`read:172`/`write:203`)、`include/linux/hwmon.h:417 struct hwmon_ops`、`:440 HWMON_CHANNEL_INFO` 宏、`:453 struct hwmon_chip_info`、`HWMON_T_*`/`HWMON_I_*` 属性位(`include/uapi/linux/hwmon.h`)。
  - 典型驱动:`drivers/hwmon/lm75.c`(本篇走读)、`nct7802.c`(Super I/O,多类多通道)、`coretemp.c`(x86 CPU 温度,读 MSR)、`scpi-hwmon.c`(ARM SCP)。
- kernel.org:[hwmon](https://docs.kernel.org/hwmon/)、`Documentation/devicetree/bindings/hwmon/`(每个驱动头注释也讲该芯片的 sysfs 属性)。
- 数据手册:[LM75 PDF](https://www.nxp.com/docs/en/data-sheet/LM75.pdf)——对照寄存器布局/分辨率/补码格式看 `lm75_reg_to_mc` 的换算。
- 关联本站:[23 i2c](./23-drv-i2c.md) LM75 挂 I2C、regmap 走 I2C;`thermal` 子系统(`drivers/thermal/`)是 hwmon 上层(用 hwmon 读温度 + 加 trip point/cooling);用户态 `sensors`/libsensors。
