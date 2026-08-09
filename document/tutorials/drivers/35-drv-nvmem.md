---
title: "nvmem:非易失小块存储——EEPROM/MAC/校准数据的统一接口"
slug: drv-nvmem
prerequisites:
  - drv-i2c
  - drv-mtd
difficulty: intermediate
tags: [driver, nvmem, eeprom, mac, calibration, ocotp, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/driver-api/nvmem.html
  - source: third_party/linux（6.19）include/linux/nvmem-provider.h、include/linux/nvmem-consumer.h、drivers/nvmem/
maturity: drafting
related:
  - /tutorials/drivers/23-drv-i2c
  - /tutorials/drivers/31-drv-mtd
---

> 🔨 **整理中** · 这一篇深入讲 **nvmem(Non-Volatile Memory)** 子系统——EEPROM/SoC OCOTP/eFuse 这类"小块非易失存储"的统一框架,典型存 MAC 地址/序列号/校准数据(Wi-Fi 校准/ADC 校准)/设备配置。素材以 6.19 源码 + kernel.org [nvmem 文档](https://docs.kernel.org/driver-api/nvmem.html) 为权威。

## 做什么

嵌入式板子上常有些"小份、非易失、按字段读"的数据:

- **MAC 地址**:网卡出厂烧的唯一 MAC,存在 I2C EEPROM 或 SoC OCOTP(eFuse)某偏移。
- **序列号/设备 ID**:SoC OCOTP 里烧的唯一 ID。
- **校准数据**:Wi-Fi/ADC/传感器的出厂校准参数(每片板不同,生产时烧入),驱动运行时读出来用。
- **配置/校准**:某些板存出厂校准的 RTC/温补参数。

这些数据的特点:**非易失**(断电不丢)、**小**(几十~几百字节)、**按字段读**(MAC 6 字节、序列号 8 字节,各在固定偏移)。它们散落在不同硬件(I2C EEPROM AT24/AT25、SoC OCOTP eFuse、SPI flash 某分区),但"读一段字节"的需求一致。**nvmem 子系统**(`drivers/nvmem/`)统一这套:**provider**(EEPROM/OCOTP 驱动)注册一个 nvmem 设备、按字节偏移提供数据;**consumer**(网卡/校准驱动)按"cell 名"读特定字段。这一篇拆 provider/consumer 两层 + 设备树 cell 描述。

## 要了解什么

### 一、provider:`nvmem_config` + `nvmem_register`

EEPROM/OCOTP 驱动(provider 侧)填 **`struct nvmem_config`**(`include/linux/nvmem-provider.h`):

```c
struct nvmem_config config = {
    .dev  = dev,
    .name = "my-eeprom",
    .id   = NVMEM_DEVID_NONE,
    .owner = THIS_MODULE,
    .type = NVMEM_TYPE_EEPROM,
    .size = 256,                  /* EEPROM 总字节 */
    .word_size = 1,
    .stride = 1,
    .reg_read  = my_read,         /* (priv, offset, buf, bytes) → 读硬件 */
    .reg_write = my_write,        /* 可选 */
    .cells = my_cells,            /* 可选:预定义 cell(见下) */
    .ncells = ARRAY_SIZE(my_cells),
};
struct nvmem_device *nvmem = devm_nvmem_register(dev, &config);
```

`reg_read(reg_write)` 是底层硬件访问回调(provider 在这里 I2C 读 EEPROM、或读 SoC OCOTP 寄存器)。注册后 `/sys/bus/nvmem/devices/my-eeprom0/` 出现,`/sys/.../nvmem`(二进制,整个设备内容)可读。

### 二、consumer:`nvmem_cell_get` + `nvmem_cell_read`

用 nvmem 数据的驱动(consumer)不直接按偏移读,而是按 **cell 名**读——cell 是"带名字 + 偏移 + 大小"的字段:

```c
struct nvmem_cell *mac_cell = devm_nvmem_cell_get(dev, "mac-address");  /* consumer.h:54 */
size_t len;
void *mac = nvmem_cell_read(mac_cell, &len);   /* 读 mac-address 这个 cell 的内容 */
/* mac[0..5] 是 6 字节 MAC */
```

`nvmem_cell_read` 内部:cell 描述了 offset/size → 调 provider 的 `reg_read(priv, offset, buf, size)` → 返回数据。consumer 只关心"读 mac-address",不关心它在哪个 EEPROM 哪个偏移。

### 三、设备树:nvmem-cells layout

cell 怎么定义"哪个 cell 名对应哪段 offset/size"?设备树:

```dts
/* provider 端:EEPROM 节点声明它是 nvmem + 定义 cell */
eeprom@50 {
    compatible = "atmel,24c02";
    reg = <0x50>;                        /* I2C 地址 */
    #address-cells = <1>;
    #size-cells = <1>;

    mac-address@40 {                     /* 一个 nvmem cell */
        reg = <0x40 6>;                  /* offset 0x40, 6 字节 */
    };
    calibration@50 {
        reg = <0x50 32>;
    };
};

/* consumer 端:网卡节点引用 cell */
eth0 {
    nvmem-cells = <&mac_address_cell>;   /* 引用,或按名字 */
    nvmem-cell-names = "mac-address";
};
```

provider 节点声明 `nvmem` + 子节点定义 cell(每个 `reg = <offset size>`)。consumer 用 `nvmem-cell-names = "mac-address"` + `nvmem-cells = <...>` 引用。`devm_nvmem_cell_get(dev, "mac-address")` 按名字查到对应 cell。

### 四、用途 + 典型 driver

- **EEPROM provider**:`drivers/misc/eeprom/at24.c`(I2C AT24 EEPROM)——同时注册成 nvmem(`nvmem_config`),其 `reg_read` 走 `i2c_smbus_read_i2c_block_data`。
- **SoC OCOTP/eFuse provider**:各 SoC 自己的"`drivers/nvmem/<vendor>-efuse.c`"(imx-ocotp/qfprom/rockchip-efuse)——读 SoC 内部 eFuse 寄存器(序列号/MAC/安全密钥)。
- **MAC consumer**:网卡驱动 `devm_nvmem_cell_get(np, "mac-address")` + `nvmem_cell_read` → 设 `dev->dev_addr`。`eth0` 的 MAC 就这么从 EEPROM 来。

### 五、踩坑

- **byte order**:某些 cell(MAC)的字节序在 EEPROM 里可能和内核期望相反(`nvmem_cell_read_u8` 之类 helper 处理),读后要确认字节序。
- **cell 名 vs DT phandle**:6.x 推荐用 `nvmem-cell-names`(按名)+ 对应 `nvmem-cells` phouple。老式纯 phouple 已过时。
- **provider 的 `reg_read` 不能睡?**:可睡(像 I2C EEPROM 的 reg_read 走 `i2c_smbus_*` 会睡)。但要在进程上下文调 `nvmem_cell_read`,中断里不行。
- **`nvmem_cell_read_u32`/`_u64` 等 helper**:读整数 cell(序列号/校准值),helper 自动处理大小端 + 校验。

## 动手试试

1. `ls /sys/bus/nvmem/devices/`;`hexdump -C /sys/bus/nvmem/devices/<name>/nvmem`(若有)看整个 nvmem 内容
2. 读 `drivers/misc/eeprom/at24.c` 看 EEPROM 怎么同时注册成 nvmem(`nvmem_config` + `reg_read` 走 I2C)
3. 读某 SoC eFuse(`drivers/nvmem/imx-ocotp.c` 或 `qcom-qfprom.c`)看 OCOTP provider
4. 在 QEMU/真板设备树加一个 I2C EEPROM + cell,写 consumer `nvmem_cell_get`+`read` 读出来打印
5. 思考题:为什么用"按 cell 名读",而不是 consumer 直接按 offset 读 EEPROM?(提示:解耦 + 换 EEPROM 不改 consumer + 命名可读)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/nvmem-provider.h`(`struct nvmem_config`/`struct nvmem_cell_info`/`devm_nvmem_register`);`include/linux/nvmem-consumer.h:53 nvmem_cell_get`/`:54 devm_nvmem_cell_get`/`nvmem_cell_read`/`nvmem_cell_read_u32`/`_u64`;core `drivers/nvmem/core.c`;EEPROM `drivers/misc/eeprom/at24.c`/`at25.c`(也注册 nvmem)、SoC eFuse `drivers/nvmem/*-efuse.c`/`*-ocotp.c`/`qfprom.c`。
- kernel.org:[nvmem](https://docs.kernel.org/driver-api/nvmem.html)、`Documentation/devicetree/bindings/nvmem/`。
- 关联本站:[23 i2c](./23-drv-i2c.md) AT24 EEPROM 挂 I2C、[31 mtd](./31-drv-mtd.md) flash 上的 config 分区也可暴露成 nvmem;nvmem 是"小块非易失"和 MTD(大块 flash)的分工。
