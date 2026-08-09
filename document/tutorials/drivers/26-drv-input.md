---
title: "input 子系统:从按键到触摸屏,所有输入设备的统一事件模型"
slug: drv-input
prerequisites:
  - drv-platform
  - drv-irq
difficulty: intermediate
tags: [driver, input, input_dev, evdev, gpio_keys, event, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - source: third_party/linux（6.19）drivers/input/、include/linux/input.h、include/uapi/linux/input.h
maturity: drafting
related:
  - /tutorials/drivers/05-drv-irq
  - /tutorials/drivers/15-drv-gpio
---

> 🔨 **整理中** · 这一篇拆 input 子系统:为什么内核用统一的"事件(type/code/value)"模型抽象所有输入设备、`input_dev` 的能力位图怎么声明"这设备能产生哪些事件"、framework 怎么把驱动上报的事件分发到 `/dev/input/eventX`。拿 `gpio_keys.c`(GPIO 按键驱动,1122 行,最典型的 input 驱动)逐段走读——从 GPIO 中断到 `input_report_key` 到用户态拿到事件,完整链路每步带行号。动手部分在真板验过之前标"待亲测"。

## 做什么

输入设备五花八门——按键、键盘、鼠标、触摸屏、摇杆、加速度计——它们的硬件接口和原始数据格式天差地别(GPIO 电平、I2C 坐标、USB HID 报告...)。但它们做的是**同一件事**:产生"某类型、某编码、某值"的**事件**(按了 KEY_A、X 方向移动了 10、触摸坐标 1024/768)。内核 **input 子系统**统一这套:设备驱动只管"读硬件 → 转成 input 事件 → `input_report_*` 上报",事件路由/分发/给用户态(`/dev/input/eventX`)由 input core + handler(evdev 等)处理。这一篇拆"事件模型 + 能力位图 + 事件分发",拿 GPIO 按键走完整条链。

## 要了解什么

### 〇、硬件背景:输入设备类型与统一事件模型

输入设备按"产生什么类型的数据"分几类,每类对应一个**事件类型(type)**:

- **按键/键盘**:按下/松开一个键 → `EV_KEY` 事件,`code` = 键码(`KEY_A`=30、`KEY_ENTER`=28、`BTN_TOUCH`...),`value` = 1(按下)/0(松开)/2(重复)。
- **鼠标(相对坐标)**:移动了多少 → `EV_REL`,`code` = `REL_X`/`REL_Y`,`value` = 位移量(+10 = 右移 10 像素)。
- **触摸屏/摇杆(绝对坐标)**:当前坐标 → `EV_ABS`,`code` = `ABS_X`/`ABS_Y`,`value` = 坐标值(0-1023 之类)。
- **同步**:一组相关事件结束 → `EV_SYN`(code=`SYN_REPORT`),告诉消费者"这一帧齐了,可以处理了"。

用户态从 `/dev/input/eventX` 读到的是统一的 **`struct input_event`**(`include/uapi/linux/input.h:28`):

```c
struct input_event {     /* 用户态读到的格式 */
    struct timeval time;  /* 时间戳 */
    __u16 type;           /* EV_KEY / EV_REL / EV_ABS / EV_SYN ... */
    __u16 code;           /* KEY_A / REL_X / ABS_X ... */
    __s32 value;          /* 1/0(按键) 或 位移量(鼠标) 或 坐标值(触摸) */
};
```

不论设备是什么,用户态用同一套 `struct input_event` 读——这是 input 子系统的核心抽象。`evtest`/libinput/X/Wayland 都基于它。

### 一、framework:`input_dev` + 能力位图 + 事件分发

**`struct input_dev`**(`include/linux/input.h:137`)——一个输入设备的化身,核心是**能力位图**:

```c
struct input_dev {          /* input.h:137 */
    const char *name;
    unsigned long evbit[];    /* ⭐ 支持哪些事件类型(EV_KEY? EV_REL? EV_ABS?) */
    unsigned long keybit[];   /* ⭐ 支持哪些按键(KEY_A? KEY_ENTER? ...) */
    unsigned long relbit[];   /* 支持哪些相对轴(REL_X? REL_Y? ...) */
    unsigned long absbit[];   /* 支持哪些绝对轴(ABS_X? ABS_Y? ...) */
    struct input_absinfo *absinfo;  /* 绝对轴的范围(min/max/fuzz/flat) */
    ...
};
```

能力位图是 input 的精髓:`evbit` 声明"我能产生哪些 type"、`keybit` 声明"在 EV_KEY 里我能产生哪些键"、`absbit` 声明"在 EV_ABS 里我有哪些轴"。用户态 `udev`/libinput 读这些位图知道"这设备能干啥、出什么格式"。设能力用 `__set_bit(KEY_A, dev->keybit)` 或 `input_set_capability(dev, EV_KEY, KEY_A)`(`input.c:2071`),绝对轴用 `input_set_abs_params(dev, ABS_X, min, max, fuzz, flat)`(`:455` 设范围 + 分配 absinfo)。

**注册**:`devm_input_allocate_device(dev)` 分配 + 设能力 + `input_register_device(dev)`(`input.c:2312`)——后者把设备加进全局列表、匹配 handler(evdev 等)建连接、`/dev/input/eventX` 出现。注册时 framework **自动加 `EV_SYN`**(所有设备都必须能 sync)。

**事件上报 + 分发**:驱动用 `input_report_key(dev, KEY_A, 1)`(`input.h:437`,封装 `input_event(dev, EV_KEY, KEY_A, 1)`)上报 → `input_event`(`input.c:391`)→ `input_handle_event`(`:358`)→ 攒一批事件 → `input_pass_values`(`:111`)分发给所有连上的 handler。evdev handler 的 `evdev_events`(`evdev.c:291`)接收 → 写进环形 buffer → 唤醒用户态读。

### 二、evdev handler:事件到用户态的桥

`drivers/input/evdev.c` 是最常用的 handler——每个 input_dev 连一个 evdev → `/dev/input/eventN`。事件来时 `evdev_events`(`:291`)调 `evdev_pass_values`(`:244`)把每个 `input_value` 转成 `struct input_event` 写进 evdev_client 的**环形 buffer**(`__pass_event:214`)→ `SYN_REPORT` 时 `wake_up_interruptible_poll`(`:284`)唤醒阻塞在 `read` 的用户态 → `evdev_read`(`:556`)从 buffer 取事件 `copy_to_user`。buffer 满时丢旧事件 + 插一个 `SYN_DROPPED`(`:220`)告诉用户态"丢了,重新同步"。

### 三、源码走读:gpio_keys.c(GPIO 按键 input 驱动)

`drivers/input/keyboard/gpio_keys.c`(1122 行)是最典型的 input 驱动——N 个 GPIO 按键,每个按/松开产生 `EV_KEY` 事件。

**probe**(`:837`):

```c
static int gpio_keys_probe(struct platform_device *pdev)
{
    /* 1. 从设备树读所有按键定义(gpio/键码/去抖间隔) */
    pdata = gpio_keys_get_devtree_pdata(dev);

    /* 2. 分配 input_dev + 驱动私有数据 */
    input = devm_input_allocate_device(dev);
    input->name = "gpio-keys";

    /* 3. 每个按键:获取 GPIO + 设能力 + 请求 IRQ */
    for (i = 0; i < pdata->nbuttons; i++) {
        gpio_keys_setup_key(pdev, input, ddata, &pdata->buttons[i], i, child);
        /* setup_key 内部(:496):
         *   gpiod = devm_fwnode_gpiod_get(dev, child, NULL, GPIOD_IN);  // 获取 GPIO
         *   input_set_capability(input, EV_KEY, keycode);                // ⭐ 声明"能产生这个键"
         *   irq = gpiod_to_irq(gpiod);                                   // GPIO → IRQ 号
         *   devm_request_any_context_irq(dev, irq, gpio_keys_gpio_isr,
         *       IRQF_TRIGGER_RISING | IRQF_TRIGGER_FALLING, ...);        // ⭐ 双边沿(按+松都触发)
         */
    }

    /* 4. 注册 */
    input_register_device(input);
    return 0;
}
```

**ISR + 去抖 + 上报**(`:411`/`:401`/`:360`):

```c
/* gpio_keys.c:411 — GPIO 中断(按下或松开时触发,双边沿) */
static irqreturn_t gpio_keys_gpio_isr(int irq, void *dev_id)
{
    struct gpio_button_data *bdata = dev_id;
    /* ⭐ 去抖:不立刻报事件,启动定时器等抖动过去 */
    if (bdata->debounce_use_hrtimer)
        hrtimer_start(&bdata->debounce_timer, ms_to_ktime(bdata->software_debounce), ...);
    else
        mod_delayed_work(system_wq, &bdata->work, msecs_to_jiffies(bdata->software_debounce));
    return IRQ_HANDLED;
}

/* :401 — 去抖定时器到时回调(抖动已过,现在是稳定状态) */
static enum hrtimer_restart gpio_keys_debounce_timer(struct hrtimer *t)
{
    gpio_keys_debounce_event(bdata);   /* → :384 报事件 */
    return HRTIMER_NORESTART;
}

/* :384 — 真正上报 */
static void gpio_keys_debounce_event(struct gpio_button_data *bdata)
{
    gpio_keys_gpio_report_event(bdata);   /* → :360 读 GPIO + input_report_key */
    input_sync(bdata->input);             /* ⭐ 一帧结束,必须 sync */
}

/* :360 — 读 GPIO 状态 + 上报 */
static void gpio_keys_gpio_report_event(struct gpio_button_data *bdata)
{
    int state = gpiod_get_value(bdata->gpiod);   /* 读 GPIO 电平(0=松开/1=按下) */
    input_event(input, type, *bdata->code, state);  /* → input_report_key(dev, KEY_A, 1/0) */
}
```

核心链路:GPIO 电平变 → 双边沿 IRQ(`:411`)→ **去抖 hrtimer**(等抖动过)→ `gpio_keys_gpio_report_event`(`:360`)读 GPIO 实际电平 → `input_report_key(dev, KEY_X, state)` + `input_sync`。

### 四、数据流:按键到用户态的完整链路

1. **用户按按键** → GPIO 电平变化。
2. **GPIO 控制器**检测到边沿 → 触发 IRQ → `gpio_keys_gpio_isr`(`gpio_keys.c:411`)。
3. **去抖**:启动 hrtimer 等 `debounce_interval` ms → `gpio_keys_debounce_timer`(`:401`)→ `gpio_keys_gpio_report_event`(`:360`)。
4. **读电平 + 上报**:`gpiod_get_value` 读 GPIO → `input_report_key(dev, KEY_A, 1)`(`:360`/`input.h:437`)→ `input_event`(`input.c:391`)。
5. **input core 攒事件**:`input_handle_event`(`:358`)把事件存进 `dev->vals[]` 数组。
6. **`input_sync`**(`:360`)→ 触发 `input_pass_values`(`input.c:111`)→ 遍历所有连上的 handler 调 `handle_events`。
7. **evdev 接收**:`evdev_events`(`evdev.c:291`)→ `evdev_pass_values`(`:244`)→ 逐事件 `__pass_event`(`:214`)写进环形 buffer。
8. **唤醒用户态**:`SYN_REPORT` 时 `wake_up_interruptible_poll`(`:284`)。
9. **用户态 read**:`evdev_read`(`:556`)从 buffer 取 `struct input_event` → `copy_to_user` → 用户态 `evtest`/libinput 拿到 `{type=EV_KEY, code=KEY_A, value=1}`。

整条链:GPIO 电平 → IRQ(`:411`)→ debounce hrtimer(`:401`)→ `input_report_key`(`:360`)→ `input_event`(`:391`)→ `input_pass_values`(`:111`)→ `evdev_events`(`:291`)→ `__pass_event`(`:214`)→ `evdev_read`(`:556`)→ 用户态。

### 五、源码真踩坑(都是读源码才发现的)

1. **`input_sync` 必须调**(`input.c:2312` 注册时自动加 EV_SYN + 事件攒到 sync 才分发)。驱动报了一组事件(如触摸的 ABS_X + ABS_Y + BTN_TOUCH)后**必须 `input_sync`**,否则 handler 不处理这一帧——事件攒在 `dev->vals[]` 里等着。漏 sync,用户态收不到事件。

2. **EV_ABS 必须设范围**(`input.c:2319` 注册检查 absinfo)。触摸屏的 ABS_X/ABS_Y 要 `input_set_abs_params(dev, ABS_X, 0, 1023, 0, 0)` 设 min/max(范围),否则 `input_register_device` 返回 `-EINVAL`。libinput/X 靠这个范围做坐标映射。`fuzz`(去抖)/`flat`(死区)参数也在这里设。

3. **GPIO 按键要双边沿 IRQ**(`gpio_keys.c:599` `IRQF_TRIGGER_RISING | IRQF_TRIGGER_FALLING`)。只触发沿(仅按下)的话,松开事件收不到——按键永远"按着"。双边沿 = 按+松都触发 ISR。

4. **去抖:硬件优先、软件兜底**(`gpio_keys.c:554`)。先试 `gpiod_set_debounce(gpiod, interval)`(硬件去抖,GPIO 控制器支持的话);失败(不支持)回退到软件去抖(hrtimer 延迟 `debounce_interval` ms 再读电平)。机械按键抖动会导致按下瞬间多次 IRQ(几 ms 内抖动),没有去抖会报"按下松开按下松开"一堆假事件。

5. **自动重复(`EV_REP`)由 core 处理,驱动不用管**(`input.c:2216`)。如果设了 `EV_REP`(probe 里 `__set_bit(EV_REP, input->evbit)`),用户按住不放时 core 自动每 `REP_PERIOD`(33ms)发一个重复事件——驱动只报"按下 1"和"松开 0",重复由 core 的定时器插。

6. **环形 buffer 满 → `SYN_DROPPED`**(`evdev.c:220`)。用户态 read 太慢(缓冲区满),evdev 丢旧事件 + 插 `SYN_DROPPED`。用户态收到 `SYN_DROPPED` 后应该丢弃到下一个 `SYN_REPORT` 之间的所有事件(因为可能不完整),重新同步——libinput 就是这么处理的。

## 动手试试

1. `ls /sys/class/input/`;`cat /proc/bus/input/devices`(看每个设备的能力位图 evbit/keybit/absbit + 对应的 eventX)。
2. `evtest /dev/input/eventN`(装 evtest)实时看事件流;按一个键,看 `{EV_KEY, KEY_A, 1}` + `{EV_SYN, SYN_REPORT, 0}` 一帧。
3. 读 `drivers/input/keyboard/gpio_keys.c` 的 probe(`:837`)+ ISR(`:411`)+ report(`:360`),对照本篇第三/四节走完整链。
4. `cat /sys/class/input/eventN/device/capabilities/key`(hex 位图,看支持哪些键)。
5. 思考题:为什么 input 要"一组事件后 `input_sync`",而不是每条事件直接送用户态?(提示:原子性——触摸的 X+Y+触摸态是一帧,要一起给消费者才一致)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):
  - framework:`drivers/input/input.c`(`input_register_device:2312`/`input_event:391`/`input_pass_values:111`/`input_set_abs_params:455`/`input_set_capability:2071`)、`include/linux/input.h:137 struct input_dev`、`include/uapi/linux/input.h:28 struct input_event`(用户态格式)、`include/uapi/linux/input-event-codes.h`(所有 EV_*/KEY_*/ABS_* 常量)。
  - handler:`drivers/input/evdev.c`(`evdev_connect:1334`/`evdev_events:291`/`evdev_pass_values:244`/`__pass_event:214`/`evdev_read:556`)——通用事件透传到 `/dev/input/eventX`。
  - 典型驱动:`drivers/input/keyboard/gpio_keys.c`(本篇走读)、`drivers/input/touchscreen/`(各种触摸屏,用 I2C/SPI 读坐标 + EV_ABS)、`drivers/input/mouse/`(鼠标)、IIO 传感器 `drivers/iio/`。
- kernel.org:[Input](https://docs.kernel.org/input/)、`Documentation/input/`(event codes/edev...)。
- 关联本站:[05 irq](./05-drv-irq.md) GPIO 按键的中断、[15 gpio](./15-drv-gpio.md) GPIO 读电平、[23 i2c](./23-drv-i2c.md) I2C 触摸屏常挂 I2C。
