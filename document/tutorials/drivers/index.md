---
title: 驱动开发
description: 字符设备、平台驱动、设备树、中断——主线内核驱动开发
---

# 驱动开发

> 字符设备 → 平台驱动 → 设备树 → 中断，掌握主线内核驱动开发的完整链条。

🔨 **整理中**。建议先把[通识基础](../foundations/)和[内核子系统](../kernel/)走通。

## 驱动模型基础 🔨 整理中

- 🔨 [00 driver model:内核怎么知道"这个硬件该用哪个驱动"](./00-drv-model)

## 字符设备与中断 🔨 整理中

- 🔨 [字符设备驱动：用户态通往内核的门](./01-drv-chardev)
- 🔨 [ioctl：结构化的内核-用户命令通道](./02-drv-ioctl)
- 🔨 [poll/select：驱动怎么告诉用户“数据来了”](./03-drv-poll)
- 🔨 [mmap：把设备内存搬进用户进程](./04-drv-mmap)
- 🔨 [硬件中断：设备怎么打断 CPU](./05-drv-irq)
- 🔨 [时间与延迟：内核怎么“等”](./06-drv-clk)
- 🔨 [mutex 与 spinlock：保护临界区的两把锁](./07-drv-sync)
- 🔨 [原子操作、refcount 与内存屏障](./08-drv-atomic)
- 🔨 [RCU：读多写少的无锁魔法](./09-drv-rcu)

## 持续铺开

- 🔨 [10 platform 驱动:嵌入式 SoC 外设的标准开发套路](./10-drv-platform)
- 🔨 [11 设备树:把硬件描述从代码里解放出来](./11-drv-dts)
- 🔨 [12 线程化中断:把 ISR 的慢活挪进内核线程](./12-drv-threaded-irq)
- 🔨 [13 块设备驱动:gendisk 与 blk-mq](./13-drv-block)
- 🔨 [14 网络设备驱动:net_device 与 NAPI](./14-drv-netdev)
- 🔨 [15 GPIO 驱动:从控制器到消费者](./15-drv-gpio)
- 🔨 [16 pinctrl:引脚功能复用与配置](./16-drv-pinctrl)
- 🔨 [17 DMA:让硬件自己搬数据,解放 CPU](./17-drv-dma)
- 🔨 [18 USB 驱动:设备、接口与 URB](./18-drv-usb)
- 🔨 [19 DRM/KMS:现代显示与图形子系统](./19-drv-drm)
- 🔨 [20 ALSA:音频子系统与 PCM 流](./20-drv-alsa)
- 🔨 [21 of_ 接口速查:在内核里遍历设备树、读属性](./21-drv-of-api)
- 🔨 [22 misc 杂项设备:chardev 的轻量封装](./22-drv-misc)
- 🔨 [23 I2C 驱动:传感器/EEPROM/小屏的经典总线](./23-drv-i2c)
- 🔨 [24 SPI 驱动:高速串行外设总线](./24-drv-spi)
- 🔨 [25 UART / TTY 驱动:串口——嵌入式调试命脉](./25-drv-uart)
- 🔨 [26 input 子系统:键盘/鼠标/触摸屏/加速度计的统一框架](./26-drv-input)
- 🔨 [27 watchdog:看门狗——系统挂起时硬件复位](./27-drv-watchdog)
- 🔨 [28 RTC:实时钟——断电也走的时间](./28-drv-rtc)
- 🔨 [29 regulator:电源调节器——给外设供稳定电压](./29-drv-regulator)
- 🔨 [30 LCD / backlight:屏幕开关与背光亮度子系统](./30-drv-lcd)
- 🔨 [31 MTD 子系统:flash 存储(NAND/NOR/SPI-NOR)的统一抽象](./31-drv-mtd)
- 🔨 [32 hwmon:硬件监控——温度/电压/电流/风扇转速](./32-drv-hwmon)
- 🔨 [33 net PHY:网卡物理层芯片的驱动框架(phylib)](./33-drv-phy)
- 🔨 [34 PWM:脉宽调制——背光/电机/蜂鸣器的万能旋钮](./34-drv-pwm)
- 🔨 [35 nvmem:非易失小块存储——EEPROM/MAC/校准数据的统一接口](./35-drv-nvmem)
- 🔨 [36 remoteproc / rpmsg:异构多核——A7 跑 Linux,M4/DSP 跑 RTOS](./36-drv-remoteproc)
