---
title: "LCD / backlight:屏幕开关与背光亮度子系统"
slug: drv-lcd
prerequisites:
  - drv-model
  - drv-dts
difficulty: intermediate
tags: [driver, lcd, backlight, fbdev, brightness, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/leds/index.html
  - source: third_party/linux（6.19）include/linux/lcd.h、include/linux/backlight.h、drivers/video/backlight/
maturity: drafting
related:
  - /tutorials/drivers/19-drv-drm
  - /tutorials/drivers/29-drv-regulator
---

> 🔨 **整理中** · 这一篇讲 **LCD/backlight 子系统**——"屏幕本身的开关 + 背光亮度调节"两个轻量框架。素材以 6.19 源码 + kernel.org 文档为权威。它**不是** [19 DRM](./19-drv-drm.md) 那种完整显示管线,只是给"屏通断电/调亮度"的简单抽象。

## 做什么

嵌入式产品的"显示"分几层:显示管线(把 framebuffer 内容扫到屏幕,这是 [DRM/KMS](./19-drv-drm.md) 的活)、**屏幕通断电**(LCD 本身的电源开关)、**背光亮度调节**(LED 背光的明暗)。后两者简单(就开/关/调亮度),内核给它们单独的轻量框架:`lcd_class`(屏幕开关/对比度)和 `backlight_class`(背光亮度),都挂在 `drivers/video/backlight/`。用户态 `/sys/class/lcd/lcd0/`、`/sys/class/backlight/backlight0/` 操作。这一篇拆这两个框架怎么写驱动。

## 要了解什么

### 一、`lcd` 子系统:屏幕通断电 + 对比度

**`struct lcd_device`**(`include/linux/lcd.h:71`)+ **`struct lcd_ops`**(`:42`)。核心回调:

- `set_power`/`get_power`:开/关 LCD 本身的电源(`FB_BLANK_UNBLANK` 正常/`POWERDOWN` 关)。
- `set_contrast`/`get_contrast`:调对比度(如果硬件支持)。
- `check_fb`:判断这个 lcd_device 关联哪个 framebuffer(给 fbdev)。

注册:`devm_lcd_device_register(dev, "lcd0", dev, &my_data, &my_lcd_ops)`(`lcd.h:123`)。用户态 `/sys/class/lcd/lcd0/{power,contrast}` 操作。

### 二、`backlight` 子系统:背光亮度

**`struct backlight_device`**(`include/linux/backlight.h:245`)+ **`struct backlight_ops`**(`:100`)。核心回调:

- `update_status`:把"当前亮度/电源状态"写进硬件(`bd->props.brightness`/`power`)。
- `get_brightness`:读当前实际亮度。
- `check_fb`:关联哪个 fb。

注册:`devm_backlight_device_register(dev, "backlight0", dev, &data, &bl_ops, &bl_props)`,props 里设 `max_brightness`/`brightness`(初始)。用户态 `/sys/class/backlight/backlight0/{brightness,max_brightness,actual_brightness,bl_power}`——Android/Linux 调亮度就是 `echo 128 > .../brightness`。

### 三、典型用法:PWM 背光 + GPIO LCD 电源

- **背光**:背光 LED 常由 PWM 驱动(占空比 = 亮度)。内核有 `pwm-backlight.c` 驱动——设备树 `pwms = <&pwm 0 50000>;` + `brightness-levels = <0 64 128 192 255>;`,驱动把"亮度档位 → PWM 占空比"映射好,注册成 backlight_device。用户态写 brightness → 驱动 `update_status` 改 PWM 占空比。
- **LCD 电源**:LCD 模组本身的电源常是一个 regulator(`vcc-lcd-supply = <&ldo5>`)——`lcd_ops.set_power` 里 `regulator_enable/disable` 那个 regulator,实现"屏通电/断电"。

### 四、和 DRM/fbdev 的关系

- **老 fbdev 框架**:`/dev/fb0`(framebuffer)给用户态写像素,lcd/backlight 配套管"屏本身的电和亮度"。老式嵌入式显示(LCD 模组直接接)用这套。
- **现代 DRM/KMS**:[19 DRM](./19-drv-drm.md) 一站式管理显示管线(CRTC/encoder/connector/plane),DRM 自己有 `drm_panel`(面板的开关/时序) + backlight 接口。所以现代显示用 DRM 时,backlight 可能仍走 backlight_class(DRM backlight bridge 复用它),但屏开关/时序归 drm_panel。**新代码用 DRM,lcd/backlight 子系统主要是老 fbdev 时代的产物,仍广泛存在于现有 BSP**。

## 动手试试

1. `ls /sys/class/lcd/`/`/sys/class/backlight/` 看设备;`cat .../backlight0/max_brightness`/`actual_brightness`;`echo 50 > .../brightness` 调亮度(若有真实背光)
2. 读 `drivers/video/backlight/pwm-bl.c`(PWM 背光,最常见)看 `backlight_ops`/`update_status` 怎么调 PWM
3. 读 `drivers/video/backlight/lcd.c`/`backlight.c` 看两个框架的 core
4. 设备树 `backlight { compatible = "pwm-backlight"; pwms = <&pwm 0 ...>; brightness-levels = <...>; };` 加一个,验证 `/sys/class/backlight/` 出现
5. 思考题:为什么 lcd/backlight 单独成子系统,不归 DRM?(提示:历史 + 它们比 DRM 简单早,且可独立于显示管线存在)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/lcd.h:42 struct lcd_ops`、`:71 struct lcd_device`、`:123 devm_lcd_device_register`;`include/linux/backlight.h:100 struct backlight_ops`、`:245 struct backlight_device`;core + 驱动 `drivers/video/backlight/`(`lcd.c`/`backlight.c` core、`pwm-bl.c` PWM 背光、`gpio_backlight.c`、各面板 `*-bl.c`)。
- kernel.org:[LEDs & backlight](https://docs.kernel.org/leds/index.html)、`Documentation/devicetree/bindings/video/backlight/`、`Documentation/ABI/stable/sysfs-class-backlight`。
- 关联本站:[19 DRM](./19-drv-drm.md) 现代显示管线(DRM backlight bridge 复用 backlight_class)、[29 regulator](./29-drv-regulator.md) LCD 电源、[16 pinctrl](./16-drv-pinctrl.md) PWM 可能走它复用。
