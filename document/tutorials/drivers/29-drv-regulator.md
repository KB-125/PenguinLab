---
title: "regulator:电源调节器——给外设供稳定电压"
slug: drv-regulator
prerequisites:
  - drv-model
  - drv-dts
difficulty: advanced
tags: [driver, regulator, voltage, pmic, cpuvolt, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/regulator/
  - source: third_party/linux（6.19）include/linux/regulator/、drivers/regulator/
maturity: drafting
related:
  - /tutorials/drivers/10-drv-platform
  - /tutorials/drivers/11-drv-dts
---

> 🔨 **整理中** · 这一篇讲 **regulator(电源调节器)** 子系统——给 SoC/CPU/外设提供稳定电压的硬件(典型 PMIC)的内核框架。素材以 6.19 源码 + kernel.org [regulator 文档](https://docs.kernel.org/regulator/) 为权威。它比 platform/i2c 复杂,分 **producer/consumer/machine** 三角色。

## 做什么

SoC 和外设需要稳定电压才能工作,且很多场景要**动态调电压**(CPU 调频时配套调压——CPUFreq DVFS、省电时降压、外设不工作时关电)。这些电压由 **regulator**(电压调节芯片,典型 PMIC 如高通 PMIC、TI TPS、Richtek)提供。内核 **regulator 子系统**(`drivers/regulator/`)统一管理这套,分三个角色:谁提供电压(producer/regulator driver)、谁用电压(consumer/外设驱动)、板子上怎么接(machine/约束)。这一篇拆这三角色 + 最常用的 consumer API。

## 要了解什么

### 一、三角色:producer / consumer / machine

- **producer(regulator driver)**:给"PMIC 上每个 LDO/DCDC/Buck"写驱动,填 `struct regulator_desc`(电压范围/可调档位/enable 回调) → 注册成 `regulator_dev`。一个 PMIC 上常有十几个 regulator(每个管一路电),都注册成独立的 regulator_dev。
- **consumer**:用电源的驱动(USB 控制器要 3.3V、SD 卡要 1.8/3.3V 切换)。**不直接碰硬件**,通过 `regulator_get`/`regulator_enable`/`regulator_set_voltage` 这套 consumer API 操作。
- **machine**:板级配置(设备树)描述"哪个 regulator 给哪个外设供电"——`<dev>-supply = <&vcc_usb>;`,把 consumer 名映射到具体 regulator_dev。

三层解耦:producer 管硬件、consumer 只用名字要电源、machine 把名字接到具体硬件。换 PMIC 只改 machine + producer,consumer 不动。

### 二、consumer API(最常用,绝大多数驱动只碰这套)

```c
struct regulator *vcc = devm_regulator_get(dev, "vcc");   /* consumer.h:155,从设备树 vcc-supply 拿 */
regulator_enable(vcc);                                     /* 上电 */
regulator_set_voltage(vcc, 1800000, 3300000);              /* 设 1.8V-3.3V 之间 */
u32 v = regulator_get_voltage(vcc);                        /* 当前电压(uV) */
regulator_disable(vcc);                                    /* 下电 */
```

设备树里:

```dts
mysensor@48 {
    compatible = "vndr,sensor";
    reg = <0x48>;
    vcc-supply = <&ldo3>;          /* vcc 消费 ldo3 这个 regulator */
    vdd-supply = <&vdd_io>;        /* 可消费多个 */
};
```

`devm_regulator_get(dev, "vcc")` 找 `vcc-supply` 属性指向的 regulator_dev、返回一个 `struct regulator *` 句柄(consumer 侧)。然后 `enable`/`disable`/`set_voltage` 通过这个句柄操作。

### 三、用途:DVFS / 省电 / 外设供电

- **CPU DVFS(Dynamic Voltage-Frequency Scaling)**:CPU 调频(CPUFreq)时配套调压——高频要高压、低频可低压,搭配省电。regulator 子系统和 CPUFreq 联动(`cpufreq` driver 调 `regulator_set_voltage`)。
- **外设省电**:外设不工作时关它的 regulator(整条电源切断,比"待机"更省电)。
- **上电时序**:复杂 SoC 启动要按顺序给多路上电、复位——regulator + reset 控制器配合实现。

### 四、`struct regulator_dev` + `regulator_desc`(producer 侧,简述)

PMIC 驱动给每路 LDO/DCDC 填 `struct regulator_desc`(`include/linux/regulator/driver.h`)——电压范围(`n_voltages`/`min_uV`/`uV_step`/`linear_ranges`)、`ops`(`enable/disable/get_voltage/set_voltage/set_mode`...)、of_map_mode 等;`devm_regulator_register(dev, &desc, &config)` 注册成 `regulator_dev`。这部分由 PMIC 厂商驱动写(`drivers/regulator/tps*.c`/`qcom_smd-regulator.c` 等),普通外设驱动只当 consumer。

## 动手试试

1. `ls /sys/class/regulator/`、`cat /sys/class/regulator/regulator.*//name`/`state`/`type`/`microvolts` 看所有 regulator + 当前电压状态
2. 宿主机 `cat /sys/class/regulator/*/name | sort -u` 看 PMIC 提供了多少路
3. 读一个 regulator consumer 用法:任意需要供电的驱动(`drivers/i2c/`、`drivers/mmc/`)里 `devm_regulator_get` + `regulator_enable`
4. 读 PMIC producer:`drivers/regulator/` 下简单驱动(如 `fixed.c` 固定电压 regulator)看 `regulator_desc`/`ops`
5. 思考题:为什么 regulator 分 producer/consumer/machine 三层,而不让 consumer 直接调 producer?(提示:解耦 + 换 PMIC 不改 consumer)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/regulator/consumer.h`(`regulator_get :153`/`devm_regulator_get :155`/`regulator_enable`/`disable`/`set_voltage`/`get_voltage`);producer 侧 `include/linux/regulator/driver.h`(`regulator_dev`/`regulator_desc`/`regulator_ops`);machine `include/linux/regulator/machine.h`(`regulator_init_data`/约束);core `drivers/regulator/core.c`/`core.c`;PMIC 驱动 `drivers/regulator/*.c`。
- kernel.org:[regulator](https://docs.kernel.org/regulator/)、`Documentation/devicetree/bindings/regulator/`。
- 关联本站:[10 platform](./10-drv-platform.md)/[11 dts](./11-drv-dts.md) regulator 通过设备树 `<name>-supply` 接;DVFS 关联 CPUFreq(子系统专题);PMIC 常挂 [I2C](./23-drv-i2c.md)。
