---
title: "SPI 驱动:高速串行外设总线"
slug: drv-spi
prerequisites:
  - drv-i2c
  - drv-platform
difficulty: intermediate
tags: [driver, spi, spi_driver, spi_transfer, cs, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/spi/
  - source: third_party/linux（6.19）include/linux/spi/spi.h、drivers/spi/
maturity: drafting
related:
  - /tutorials/drivers/23-drv-i2c
  - /tutorials/drivers/10-drv-platform
---

> 🔨 **整理中** · 这一篇讲 **SPI 子系统**——四线(SCLK/MOSI/MISO/CS)全双工串行总线,比 I2C 快(几十 MHz),Flash/显示屏/ADC/SD 卡底层都用它。素材以 6.19 源码 + kernel.org [SPI 文档](https://docs.kernel.org/spi/) 为权威。和 [I2C](./23-drv-i2c.md) 同构,区别在传输模型(SPI 是"片选 + 全双工")。

## 做什么

SPI(Serial Peripheral Interface)是嵌入式另一条主流总线:四线——SCLK(时钟)/MOSI(主出从入)/MISO(主入从出)/CS(片选)。它比 I2C 快得多(典型几十 MHz、可上百)、全双工(I2C 半双工)、但线多(每从设备一根 CS,或菊花链)。SPI Flash(W25Q 等)、OLED/TFT 显示屏、ADC/DAC、SD/MMC 底层、某些传感器都走 SPI。这一篇拆 SPI 外设 driver 怎么写——结构同 [I2C](./23-drv-i2c.md)(controller + device + driver),传输模型不同(`spi_message` + `spi_transfer` 队列)。

## 要了解什么

### 一、三件套:`spi_controller` / `spi_device` / `spi_driver`

- **`spi_controller`**(老名 `spi_master`):SPI 控制器,管 SCLK/MOSI/MISO + 片选。SoC 厂商驱动注册。
- **`spi_device`**:一个 SPI 外设实例——挂在某 controller 下、有片选号(`chip_select`)/速度(`max_speed_hz`)/模式(`mode`:`CPOL/CPHA` 时钟相位)。
- **`spi_driver`**:外设驱动,同 i2c/platform:`probe`/`remove`/`of_match_table` + 内嵌 `device_driver`。

设备树 + of_match 配对机制和 I2C 完全一样。

### 二、设备树:reg(CS)/max-speed/mode

```dts
&spi0 {
    flash@0 {                          /* 片选 0 */
        compatible = "winbond,w25q128";
        reg = <0x0>;                   /* ← 片选号(对应 controller 的第几根 CS) */
        spi-max-frequency = <50000000>; /* 最高 50MHz */
        spi-cpol; spi-cpha;            /* 模式 3(CPOL=1,CPHA=1);不写默认模式 0 */
        #address-cells = <1>;          /* (flash 子分区用) */
        #size-cells = <1>;
    };
};
```

`reg` 是片选号(不是地址,和 I2C 的 reg 含义不同);`spi-max-frequency` 限速;`spi-cpol`/`spi-cpha`/`spi-cs-high`/`spi-3wire` 等设模式。内核生成 `spi_device` 时填进 `spi->chip_select`/`spi->max_speed_hz`/`spi->mode`。

### 三、传输:`spi_message` + `spi_transfer`

SPI 传输比 I2C 复杂——它用"消息队列"模型:你把一个或多个 `spi_transfer`(每个描述"发这些字节 + 收这些字节 + 多少位")塞进一个 `spi_message`,整条消息原子提交(`spi_sync` 同步 / `spi_async` 异步)。

```c
u8 tx[] = {READ_CMD, addr_hi, addr_lo};
u8 rx[4] = {0};
struct spi_transfer t = {
    .tx_buf = tx, .rx_buf = rx,
    .len = sizeof(tx) + sizeof(rx),   /* 全双工:同时发 tx 收 rx */
};
struct spi_message m;
spi_message_init(&m);
spi_message_add_tail(&t, &m);
spi_sync(spi, &m);                     /* 同步:阻塞到完成 */
/* rx[] 现在含读回的数据 */
```

SPI 全双工特性:`tx_buf` 和 `rx_buf` 同时有效——发 tx 的每个字节、同时收一个字节进 rx。这是 SPI 和 I2C(半双工)的关键区别。helper:`spi_write(spi, buf, len)`(只发)、`spi_read(spi, buf, len)`(只收)、`spi_w8r8`(发 1 字节收 1 字节)等简化常见操作。

### 四、异步 + DMA

`spi_sync` 阻塞当前线程(进程上下文),简单但浪费 CPU。高吞吐场景用 `spi_async`(异步,完成时回调,可在软中断跑),配合 DMA(`spi_transfer.tx_dma`/`rx_dma`)让控制器 DMA 搬数据、CPU 不参与每个字节。SPI Flash/SD 卡这类大批量传输全靠异步+DMA。

## 动手试试

1. `ls /sys/bus/spi/devices/` 看 spi-device;QEMU 可加 `-device spidev` 或 virtio-spi
2. 读 `drivers/mtd/devices/m25p80.c`(SPI Flash)或 `drivers/spi/spidev.c`(用户态 SPI 接口)看 `spi_driver`/`spi_sync` 用法
3. 在设备树加一个 SPI 节点,写 `spi_driver` 匹配、probe 里 `spi_write` 发命令 + `spi_read` 收数据
4. `spidev_test`(用户态工具,通过 spidev 驱动测 SPI 总线)
5. 思考题:SPI 全双工(tx/rx 同时)和 I2C 半双工,传输模型上怎么体现?(提示:`spi_transfer` 同时有 tx_buf/rx_buf)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/spi/spi.h`(`struct spi_driver`/`struct spi_device`/`struct spi_transfer`/`spi_message_init`/`spi_message_add_tail`/`spi_sync`/`spi_async`/`spi_write`/`spi_read`);实现在 `drivers/spi/`(`spi.c` core、各 controller 驱动 `spi-*.c`);示例 `drivers/spi/spidev.c`(用户态 SPI 接口)、`drivers/mtd/devices/m25p80.c`(SPI Flash)。
- kernel.org:[SPI](https://docs.kernel.org/spi/)、`Documentation/spi/`(spidev/summary...)。
- 关联本站:[23 I2C](./23-drv-i2c.md) 同构(三件套 + of_match)、[10 platform](./10-drv-platform.md) 配对机制;SPI Flash 深入关联 [MTD](https://docs.kernel.org/mtd/)。
