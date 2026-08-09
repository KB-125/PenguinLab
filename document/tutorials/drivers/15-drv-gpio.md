---
title: "GPIO 驱动:从控制器到消费者"
slug: drv-gpio
prerequisites:
  - drv-model
  - drv-dts
next:
  - drv-pinctrl
difficulty: intermediate
tags: [driver, gpio, gpiolib, gpio_chip, gpiod, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/driver-api/gpio/
  - source: third_party/linux（6.19）include/linux/gpio/driver.h、include/linux/gpio/consumer.h、drivers/gpio/
maturity: drafting
related:
  - /tutorials/drivers/00-drv-model
  - /tutorials/drivers/11-drv-dts
---

> 🔨 **整理中** · 这一篇讲 **GPIO(通用输入输出)** 子系统——那些 SoC 上可配置成输入/输出的数字引脚。素材以 6.19 源码 + kernel.org [GPIO 文档](https://docs.kernel.org/driver-api/gpio/) 为权威。校订增量:6.x 全面用 **gpiod(descriptor-based)** 接口取代老的基于整数的 `gpio_request`/`gpio_set_value`——老资料那套整数 API 已不推荐。

## 做什么

SoC 上有一组组引脚,每根能配置成输入(读高低电平)或输出(驱动高低电平)——这就是 GPIO。点 LED、读按键、控继电器、连各种简单外设,都用它。GPIO 子系统分两个角色:**GPIO 控制器驱动**(管理一组 GPIO,告诉内核"我这里有 N 根引脚、怎么读/写/设方向")和**GPIO 消费者**(别的驱动或设备树用户,通过 gpiod API 操作某根特定引脚)。这一篇讲控制器驱动怎么写(`gpio_chip` + 注册)、消费者怎么用(`gpiod_*` API)、以及设备树怎么描述"哪个设备用了哪根 GPIO"。

## 要了解什么

### 一、GPIO 控制器:`gpio_chip`

每个 GPIO 控制器(可能是一颗 SoC 的 GPIO 控制器,或一颗外扩的 I2C GPIO 芯片)内核里对应一个 **`struct gpio_chip`**(`include/linux/gpio/driver.h:402`)。它描述"这组 GPIO 有多少根、编号范围、以及读写它们的具体硬件操作"。核心回调:

- **`get`/`set`**:读/写一根引脚的电平。
- **`get_direction`**:查某根当前是输入还是输出。
- **`direction_input`/`direction_output`**:设方向。
- **`request`/`free`**:引脚被申请/释放时调(可用来检查冲突、做引脚初始化)。

注册:`gpiochip_add_data(&gc, data)`(`:577`)或 `devm_gpiochip_add_data`(devm_ 版,推荐),它把 gc 加进 gpiolib 全局表,这组 GPIO 就对消费者可见了。控制器驱动还要挂一个 `gpio_chip` 的设备树 `gpio-controller` 节点,描述这组 GPIO 的属性(`#gpio-cells = <2>;` 告诉消费者怎么在设备树里引用)。

### 二、消费者:`gpiod_*` 接口(6.x 推荐)

另一个驱动(比如 LED 驱动)要用某根 GPIO,不直接碰 `gpio_chip`,而是通过 gpiolib 的**消费者接口**(`include/linux/gpio/consumer.h`),基于 **GPIO descriptor**(`struct gpio_desc *`,不透明指针):

```c
struct gpio_desc *led = gpiod_get(dev, "led", GPIOD_OUT_LOW);  /* 从设备树 "led-gpios" 属性拿 */
gpiod_set_value(led, 1);        /* 点亮 */
int v = gpiod_get_value(btn);   /* 读按键电平 */
gpiod_direction_output(led, 0); /* 改方向 */
gpiod_put(led);                 /* 释放 */
```

`gpiod_get(dev, name, flags)` 从设备的 device tree 节点按 `<name>-gpios` 属性名查到对应引脚,返回 descriptor——这把"哪根 GPIO"完全交给设备树描述,驱动代码和具体板子的 GPIO 编号解耦,换板子只改设备树。这就是 6.x 推荐的 gpiod 方式;老 API(`gpio_request(num, ...)`/`gpio_set_value(num, val)` 用硬编码整数编号)已被标记弃用——它把板子细节硬编码进驱动,违反设备树解耦原则。

### 三、设备树描述

GPIO 在设备树里两端写:控制器节点标 `gpio-controller` + `#gpio-cells`(说明引用格式),消费者节点用 `<phandle> <gpio_num> <flags>` 引用:

```dts
gpio0: gpio@4000_0000 {
    compatible = "penguinlab,gpio";
    reg = <...>;
    gpio-controller;
    #gpio-cells = <2>;     /* 引用格式:<gpio_num> <flags> */
};

led {
    compatible = "penguinlab,led";
    led-gpios = <&gpio0 5 GPIO_ACTIVE_HIGH>;   /* gpiod_get(dev,"led",...) 找这个 */
};
```

`gpiod_get` 的 `con_id="led"` 会去设备树找 `led-gpios` 属性,取 `&gpio0` 的第 5 根、`GPIO_ACTIVE_HIGH` 极性——这套命名约定把"逻辑名(led)→ 物理引脚(gpio0 的 5 号)"的映射交给设备树。

### 四、与 pinctrl 的关系

GPIO 只管"引脚当 GPIO 用时的输入输出";但 SoC 的引脚往往是**多功能复用**的(mux)——同一根引脚可作 GPIO,也可作 UART_TX、I2C_SDA、SPI_CLK 等。把引脚"切到哪种功能"是 [pinctrl 子系统](./16-drv-pinctrl.md)的活;切到 GPIO 功能后,再用 gpiolib 读写它的电平。两者配合:pinctrl 管"功能复用",gpio 管"作为 GPIO 时的电平"。这就是为什么 SoC 引脚操作往往要同时配 pinctrl 和 gpio。

## 动手试试

1. `cat /sys/kernel/debug/gpio`(需 CONFIG_DEBUG_FS)看所有 GPIO 控制器、每根引脚的状态(方向/电平/谁申请了)
2. QEMU virt 机型 GPIO 资源有限,但可在设备树加一个虚拟 `gpio-controller` 节点 + 消费者节点(LED),写控制器驱动 `gpiochip_add_data` + 消费者驱动 `gpiod_get`/`set`,验证两端打通
3. 读 `drivers/gpio/gpio-mmio.c`(基于内存映射的简单 GPIO 控制器驱动)看 `gpio_chip` 怎么填
4. 故意用老的 `gpio_request(num, ...)` API 写消费者,观察 checkpatch 警告(体会"gpiod 取代整数 API"的迁移)
5. 思考题:为什么 6.x 强烈推荐 `gpiod_get` + 设备树,而非老的整数编号 API?(提示:板子解耦)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/gpio/driver.h:402 struct gpio_chip`、`:577 gpiochip_add_data`;`include/linux/gpio/consumer.h`(`gpiod_get`/`gpiod_set_value`/`gpiod_direction_*`);老 API(弃用)`include/linux/legacy_gpio.h`;实现 `drivers/gpio/gpiolib.c`、`drivers/gpio/gpiolib-of.c`(设备树绑定);示例驱动 `drivers/gpio/gpio-mmio.c`、`drivers/gpio/gpio-pca953x.c`(I2C 外扩)。
- kernel.org:[GPIO driver interface](https://docs.kernel.org/driver-api/gpio/driver.html)、[GPIO consumer interface](https://docs.kernel.org/driver-api/gpio/consumer.html)、[device tree binding](https://docs.kernel.org/devicetree/bindings/gpio/gpio.html)。
- 关联本站:本篇是 [00 driver model](./00-drv-model.md) 的 GPIO 子系统类型;引脚功能复用见下一篇 [16 pinctrl](./16-drv-pinctrl.md);设备树绑定见 [11 drv-dts](./11-drv-dts.md);Linux LED 子系统就是 GPIO 的典型消费者。
