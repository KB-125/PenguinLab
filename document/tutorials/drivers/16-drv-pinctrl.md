---
title: "pinctrl:引脚功能复用与配置"
slug: drv-pinctrl
prerequisites:
  - drv-gpio
  - drv-dts
next:
  - drv-dma
difficulty: intermediate
tags: [driver, pinctrl, pinmux, pinconf, soc, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/driver-api/pinctl.html
  - source: third_party/linux（6.19）include/linux/pinctrl/pinctrl.h、drivers/pinctrl/
maturity: drafting
related:
  - /tutorials/drivers/15-drv-gpio
  - /tutorials/drivers/11-drv-dts
---

> 🔨 **整理中** · 这一篇讲 **pinctrl(引脚控制)** 子系统——SoC 引脚的**功能复用(mux)** 和**电气配置(pull-up/down/drive-strength)**。素材以 6.19 源码 + kernel.org [pinctrl 文档](https://docs.kernel.org/driver-api/pinctl.html) 为权威。它和 [GPIO](./15-drv-gpio.md) 分工:pinctrl 管"这根引脚**当什么用**"(UART_TX?GPIO?I2C_SDA?),gpio 管"当 GPIO 用时的**电平**"。

## 做什么

SoC 的引脚数量有限,但外设很多,于是同一根物理引脚能被**配置成多种功能**——比如 PA0 可以是 GPIO_A0、也可以是 UART2_TX、也可以是 I2C1_SDA,靠芯片内部的 mux 寄存器选。这就是"**引脚功能复用(pin muxing)**"。再加上电气配置:这根引脚要不要内部上拉/下拉、驱动强度多大、是施密特触发还是普通。这俩配置合起来就是 **pinctrl 子系统**管的范围。每个外设驱动(UART/I2C/SPI)启用前,都要先用 pinctrl 把它需要的引脚"切到对应功能";切到 GPIO 功能后,再用 [GPIO](./15-drv-gpio.md) API 操作电平。这一篇拆 pinctrl 的两个核心——pinmux(复用)+ pinconf(配置)、以及设备树怎么描述它们。

## 要了解什么

### 一、`pinctrl_desc`:pinctrl 控制器抽象

每个 pinctrl 控制器(SoC 通常有一个主 pinctrl,外扩芯片也可能有)内核里对应一个 **`struct pinctrl_desc`**(`include/linux/pinctrl/pinctrl.h:151`),它挂三组回调:

- **`pctlops`(pin control ops)**:查"这个控制器有多少引脚、每根叫什么名"、把引脚分组。
- **`pmxops`(pinmux ops)**:**功能复用**——`set_mux(group, function)` 把一组引脚切到指定功能;`get_functions_count`/`get_function_name` 枚举可用功能。
- **`confops`(pinconf ops)**:**电气配置**——`pin_config_set(pin, config, num_configs)` 设上下拉/驱动强度等参数。

`pinctrl_register(pd)` 把它注册进 pinctrl core。控制器驱动还要维护一张"引脚 ↔ 功能 ↔ 寄存器值"的表(通常由 SoC 厂商提供,数据量很大),`set_mux`/`pin_config_set` 内部按这张表写对应寄存器。

### 二、pinmux:功能复用

最核心的操作是 **`set_mux`**:给定一个"引脚组"(如 `uart2_pins_grp`)和一个"功能"(如 `uart2`),把组里每根引脚的 mux 寄存器写到对应值,让它们成为 UART2 的 TX/RX/RTS/CTS。控制器驱动用枚举表(`functions[]`/`groups[]`)描述"这个 SoC 有哪些功能、每个功能用哪组引脚、每组引脚对应什么寄存器值"。客户端(如 UART 驱动)不直接调 `set_mux`,而是通过设备树的 `pinctrl-0`/`pinctrl-names` 声明"我要用这组 mux 配置",pinctrl core 在客户端 probe 时自动应用(`pinctrl_select_state`)。

### 三、pinconf:电气配置

`pin_config_set` 设引脚的电气属性,常见参数(在 `include/linux/pinctrl/pinconf-generic.h`):

- `PIN_CONFIG_BIAS_PULL_UP`/`PIN_CONFIG_BIAS_PULL_DOWN`:内部上拉/下拉
- `PIN_CONFIG_DRIVE_STRENGTH`:驱动强度(mA)
- `PIN_CONFIG_BIAS_DISABLE`:禁用偏置
- `PIN_CONFIG_INPUT_SCHMITT`:施密特触发使能

这些参数也通过设备树(`bias-pull-up;`/`drive-strength = <8>;`)在 pinctrl 节点里配,pinctrl core 应用时调驱动的 `confops`。

### 四、设备树:pinctrl 节点 + 客户端引用

pinctrl 在设备树里两端写。pinctrl 控制器节点定义"各种引脚组合":

```dts
pinctrl: pinctrl@4000_0000 {
    compatible = "penguinlab,pinctrl";
    reg = <...>;

    uart2_pins: uart2-pins {        /* 一个"引脚状态"子节点 */
        pinmux = <PA0_MUX_UART2_TX>, <PA1_MUX_UART2_RX>;  /* 复用 */
        bias-pull-up;               /* pinconf:上拉 */
        drive-strength = <8>;       /* 驱动强度 8mA */
    };
};

&uart2 {
    pinctrl-names = "default";
    pinctrl-0 = <&uart2_pins>;       /* uart2 驱动引用这个状态 */
};
```

`uart2` 驱动 probe 时,pinctrl core 看到 `pinctrl-0 = <&uart2_pins>`,自动调控制器驱动的 `set_mux`/`pin_config_set` 应用这组配置——把 PA0/PA1 切成 UART2 功能、设上拉和驱动强度。客户端驱动几乎不写 pinctrl 代码,全靠设备树声明。

### 五、pinctrl 与 GPIO 的分工

记住:**pinctrl 管"功能",GPIO 管"电平"**。一根引脚要当 GPIO 用,先用 pinctrl 把它的 mux 设到 GPIO 功能,再用 gpiolib 操作它的方向和电平;当 UART/I2C 用,就 pinctrl 设到对应功能、不再走 gpiolib。同一个 SoC 的引脚,pinctrl 是"总开关"(管功能),gpio 是"GPIO 这个特定功能下的电平读写"。

## 动手试试

1. `ls /sys/kernel/debug/pinctrl/`(需 CONFIG_DEBUG_FS)看 pinctrl 控制器、`cat` 它的 `pinmux-pins`/`pinconf-groups` 看每根引脚当前的功能/配置
2. QEMU virt 机型有简单 pinctrl,在设备树加一个自定义 pinctrl 节点 + 引用它的客户端节点,验证 `set_mux` 被调
3. 读 `drivers/pinctrl/pinctrl--generic.c` 或某 SoC 厂商驱动(如 `drivers/pinctrl/nxp/pinctrl-imx*.c`)看 `pinctrl_desc` 怎么填、`set_mux` 怎么写寄存器
4. 思考题:为什么 pinctrl 和 GPIO 是分开的两个子系统,而不是合一个?(提示:职责——功能复用 vs 电平读写)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/pinctrl/pinctrl.h:151 struct pinctrl_desc`、`pinmux.h`(`pinmux_ops` 的 `set_mux`)、`pinconf.h`(`pinconf_ops`/`pin_config_set`)、`pinconf-generic.h`(`PIN_CONFIG_*` 常量);实现在 `drivers/pinctrl/`(`core.c`/`pinmux.c`/`pinconf.c`);各 SoC 厂商驱动在 `drivers/pinctrl/<vendor>/`(如 `nxp/`、`samsung/`、`mediatek/`)。
- kernel.org:[Pinctrl subsystem](https://docs.kernel.org/driver-api/pinctl.html)、`Documentation/devicetree/bindings/pinctrl/pinctrl-bindings.rst`。
- 关联本站:本篇是 [15 GPIO](./15-drv-gpio.md) 的"上游"(管功能);设备树 binding 见 [11 drv-dts](./11-drv-dts.md);driver model 框架见 [00 drv-model](./00-drv-model.md)。
