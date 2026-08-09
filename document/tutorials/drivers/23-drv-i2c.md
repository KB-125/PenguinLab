---
title: "I2C 子系统:两根线串起所有传感器——总线协议、adapter 与 client"
slug: drv-i2c
prerequisites:
  - drv-model
  - drv-dts
  - drv-platform
difficulty: intermediate
tags: [driver, i2c, adapter, client, smbus, at24, i2c-gpio, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - source: third_party/linux（6.19）drivers/i2c/、include/linux/i2c.h
maturity: drafting
related:
  - /tutorials/drivers/10-drv-platform
  - /tutorials/drivers/11-drv-dts
  - /tutorials/drivers/32-drv-hwmon
---

> 🔨 **整理中** · 这一篇拆 I2C 子系统:先讲清 I2C 总线协议(SCL/SDA/起始停止/ACK/7-bit 地址)——这是所有 API 的硬件根基;再读 framework 的三件套(adapter/client/driver)+ 传输核心(`i2c_transfer`);最后走两个真实驱动:client 侧的 `at24.c`(EEPROM,怎么写 I2C 外设驱动)和 adapter 侧的 `i2c-gpio.c`(GPIO 模拟 I2C,怎么写控制器驱动)。每个 API 都对照 I2C 协议讲。动手部分在真板验过之前标"待亲测"。

## 做什么

I2C(Inter-Integrated Circuit)是嵌入式里最常见的两线串行总线——SoC 上一个 I2C 控制器(adapter)的两根线(SCL+SDA)上能**并联挂几十个 I2C 外设**(client:温度传感器、EEPROM、PMIC、触摸控制器、OLED...),每个外设有唯一的 7-bit 地址区分。内核 I2C 子系统把这套"主从共享总线"抽象成统一的框架:adapter 驱动管"怎么在 SCL/SDA 上产生时序"、client 驱动管"某外设怎么读写寄存器"、中间的 `i2c_transfer` 统一传输。这一篇拆这套,关键是搞懂"I2C 协议 → API 设计"的对应。

## 要了解什么

### 〇、硬件背景:I2C 总线协议——两根线 + 主从 + ACK

**I2C 的硬件就是两根线**:`SCL`(时钟,主设备控制)+ `SDA`(数据,双向)。两根都是**开漏输出 + 上拉电阻**——任何设备拉低就是低(线与逻辑),没人拉低时上拉拉高。这样多个设备可以安全共享同一对线(谁都能拉低,但谁都不能强制拉高)。

**通信协议**(每次传输是一个"主设备发起、从设备响应"的过程):

1. **起始条件**:主设备在 SCL 为高时把 SDA 从高拉低 → 表示"开始一次传输"。
2. **地址字节**:主设备发一个字节 = **7-bit 从设备地址 << 1 + R/W 位**(0=写,1=读)。这个"左移一位 + R/W"就是所谓的"8-bit 地址"——它是 7-bit 地址左移来的,不是另一个地址。(`include/linux/i2c.h:948` 的 `i2c_8bit_addr_from_msg` 就是这步:`(addr << 1) | (flags & I2C_M_RD)`)
3. **ACK**:每个字节后第 9 个 SCL 脉冲,接收方拉低 SDA = ACK(收到)、不拉 = NACK(没收到/不想收)。主设备发完地址字节后,被寻址的从设备应答 ACK。
4. **数据传输**:主设备(写)或从设备(读)按字节发数据,每字节后 ACK。读时主设备发 ACK 表示"还要继续读"、发 NACK 表示"读完了"。
5. **停止条件**:主设备在 SCL 为高时把 SDA 从低拉高 → 结束传输。

**关键参数**:
- **地址**:7-bit(范围 0x03-0x77,0x00-0x07/0x78-0x7F 保留),可扩展到 10-bit。client 的 `addr` 字段存的就是 7-bit 地址(`include/linux/i2c.h:342` 注释明确:"NOTE: 7bit, addresses are stored in the _LOWER_ 7 bits")。设备树 `reg = <0x48>` 给的就是 7-bit。
- **速率**:标准 100kHz(`I2C_MAX_STANDARD_MODE_FREQ`)、快 400kHz(`I2C_MAX_FAST_MODE_FREQ`)、高速 3.4MHz,最高超快 5MHz(`include/linux/i2c.h:43-49`)。速率越高,对上拉/布线电容要求越苛刻。

所以 I2C 子系统的 API——adapter(控制器,管时序)+ client(外设,有 7-bit 地址)+ `master_xfer`(发起一次含起始/地址/数据/ACK/停止的完整传输)+ SMBus 封装(把常见的"读某寄存器"包成简单函数)——每条都对应协议的一个概念。

### 一、framework 三件套:adapter / client / driver

I2C 子系统核心分三个角色(`include/linux/i2c.h` + `drivers/i2c/i2c-core-base.c`):

**`struct i2c_adapter`**(`i2c.h:733`)——一条 I2C 总线(SoC 的一个 I2C 控制器),核心字段:

```c
struct i2c_adapter {           /* i2c.h:733 */
    const struct i2c_algorithm *algo;   /* ⭐ 传输算法:master_xfer 回调(管 SCL/SDA 时序) */
    struct rt_mutex bus_lock;            /* 总线锁(一条总线同时只能有一个传输) */
    int timeout;  int retries;           /* 超时 + 仲裁丢失重试次数 */
    struct device dev;                   /* 设备模型节点 */
    int nr;  char name[48];             /* 总线号(i2c-0/i2c-1...) + 名字 */
    ...
};
```

**`struct i2c_algorithm`**(`i2c.h:544`)——adapter 的传输回调表,核心:

```c
struct i2c_algorithm {         /* i2c.h:544 */
    int (*master_xfer)(struct i2c_adapter *, struct i2c_msg *msgs, int num);  /* ⭐ 主传输 */
    int (*master_xfer_atomic)(...);   /* 原子上下文传输(可选,用于 panic 路径) */
    int (*smbus_xfer)(...);            /* 原生 SMBus 传输(可选,不是所有硬件都有) */
    u32 (*functionality)(struct i2c_adapter *);  /* 报告支持哪些功能(I2C_FUNC_*) */
    ...
};
```

`master_xfer` 是 adapter 驱动填的核心——它接收一组 `i2c_msg`(每条描述"往哪个地址发/收多少字节"),在 SCL/SDA 上实际产生时序完成传输。

**`struct i2c_client`**(`i2c.h:331`)——一个 I2C 外设实例(挂在某 adapter 上、有 7-bit 地址):

```c
struct i2c_client {            /* i2c.h:331 */
    unsigned short addr;       /* ⭐ 7-bit 地址(低 7 位,不是 8-bit!) */
    struct i2c_adapter *adapter; /* 挂在哪个 adapter 上 */
    int irq;                   /* 该外设的中断号(从设备树 interrupts 解析) */
    struct device dev;
    ...
};
```

**`struct i2c_driver`**(`i2c.h:270`)——I2C 外设驱动,和 platform_driver 同构:`probe`/`remove` + `of_match_table` + 内嵌 `device_driver`。

### 二、注册路径:adapter 注册 → 设备树生成 client → driver 匹配

**adapter 注册**:`i2c_add_adapter`(`i2c-core-base.c:1653`)——分配总线号(优先用设备树 `aliases` 的 `i2c` 名)→ `i2c_register_adapter` 把 adapter 挂进系统 + 创建 `/sys/bus/i2c/devices/i2c-N/` + **遍历设备树子节点生成 client**。

**client 从设备树生成**:`of_i2c_register_devices`(`i2c-core-of.c:84`)——adapter 注册后,遍历设备树该 adapter 节点的子节点(每个子节点是一个 I2C 外设),读 `reg`(7-bit 地址)+ `compatible` + `interrupts`,创建 `i2c_client` 挂到这个 adapter。

```dts
&i2c0 {                        /* adapter:SoC 的 I2C 控制器 0 */
    eeprom@50 {                /* client:一个 EEPROM */
        compatible = "atmel,24c02";
        reg = <0x50>;          /* 7-bit I2C 地址 */
    };
};
```

**driver 匹配 client**:`i2c_device_match`(`i2c-core-base.c:139`)——优先设备树 `compatible` 匹配(`of_match_table`)、其次 ACPI、最后传统 `id_table`。匹配成功调 `i2c_device_probe`(`:491`)→ 驱动的 `probe(client)`。

### 三、传输核心:`i2c_transfer` + SMBus 封装

**`i2c_transfer`**(`i2c-core-base.c:2293`)——底层传输入口:

```c
int i2c_transfer(struct i2c_adapter *adap, struct i2c_msg *msgs, int num)
{
    __i2c_lock_bus_helper(adap);              /* 锁总线(一条总线同时只传一组) */
    ret = __i2c_transfer(adap, msgs, num);    /* 实际传输 */
    i2c_unlock_bus(adap, I2C_LOCK_SEGMENT);
    return ret;
}
```

`__i2c_transfer`(`:2221`)调 `adap->algo->master_xfer(adap, msgs, num)`——把一组消息交给 adapter 驱动的 `master_xfer` 实际在 SCL/SDA 上传。它还带**仲裁丢失重试**:多主系统里如果两个主同时发起传输、仲裁失败的一方返回 `-EAGAIN`,framework 在 `retries` 次内重试(`:2256-2267`)。

**SMBus 封装**——大多数 I2C 外设驱动不直接构造 `i2c_msg`、调 `i2c_transfer`,而是用更高层的 SMBus API:

```c
/* i2c-core-smbus.c — 把"读某寄存器一个字节"这种常见操作包成函数 */
s32 i2c_smbus_read_byte_data(const struct i2c_client *client, u8 command);  /* 读 client 的 command 寄存器,1 字节 */
s32 i2c_smbus_write_byte_data(client, command, value);                       /* 写 */
s32 i2c_smbus_read_i2c_block_data(client, command, length, values);          /* 连续读 N 字节 */
```

SMBus 内部:如果 adapter 有原生 `smbus_xfer` 就调它;否则 `i2c_smbus_xfer_emulated`(`i2c-core-smbus.c:323`)把 SMBus 操作"模拟"成一组 `i2c_msg` 走 `i2c_transfer`。**不是所有 adapter 都支持原生 SMBus**——纯 I2C 控制器(只懂 `master_xfer`)靠模拟。

### 四、源码走读(一):at24.c(I2C client 驱动——EEPROM)

`drivers/misc/eeprom/at24.c`(878 行)是一个典型的 I2C **client** 驱动——驱动 AT24 系列 EEPROM(256B-1MB I2C EEPROM,存储 MAC/序列号/配置等)。它的特殊之处:注册成 [nvmem](./35-drv-nvmem.md) 设备(用户态通过 `/sys/bus/nvmem/` 读)。

**probe 流程**(`at24.c:596`):

```c
static int at24_probe(struct i2c_client *client)
{
    /* 1. 检查 adapter 能力(是否支持 I2C block read) */
    i2c_check_functionality(client->adapter, I2C_FUNC_I2C | I2C_FUNC_SMBUS_WRITE_I2C_BLOCK);

    /* 2. 从设备树读芯片参数(容量/页大小/地址宽度) */
    cdata = i2c_get_match_data(client);          /* of_match_table 的 .data */
    device_property_read_u32(dev, "pagesize", &page_size);

    /* 3. 配置 regmap(I2C 8/16-bit 寄存器地址) */
    regmap_config.reg_bits = (flags & AT24_FLAG_ADDR16) ? 16 : 8;
    regmap_config.disable_locking = true;         /* ⭐ 关键:驱动自己做锁,regmap 别锁(否则死锁) */
    regmap = devm_regmap_init_i2c(client, &regmap_config);

    /* 4. 注册成 nvmem(用户态 /sys/bus/nvmem/devices/... 读 EEPROM 内容) */
    nvmem_config.reg_read  = at24_read;           /* 读回调 */
    nvmem_config.reg_write = at24_write;
    at24->nvmem = devm_nvmem_register(dev, &nvmem_config);
    return 0;
}
```

**读操作**(`at24.c:437`)——`at24_read` 是 nvmem 的 `reg_read` 回调:

```c
static int at24_read(void *priv, unsigned int off, void *val, size_t count)
{
    mutex_lock(&at24->lock);                      /* 驱动自己加锁(regmap 的 disable_locking=true) */
    /* 分块读(处理页边界),每块调 at24_regmap_read */
    ret = at24_regmap_read(at24, buf, off, count);
    mutex_unlock(&at24->lock);
    return 0;
}
```

`at24_regmap_read`(`:348`)调 `regmap_bulk_read(regmap, offset, buf, count)` → regmap I2C 后端 → `i2c_transfer` → adapter → SCL/SDA → EEPROM 返回数据。

### 五、源码走读(二):i2c-gpio.c(I2C adapter 驱动——GPIO 模拟)

`drivers/i2c/busses/i2c-gpio.c`(451 行)是一个特殊的 adapter 驱动——它**没有真正的 I2C 控制器硬件**,用两根普通 GPIO(SCL/SDA)+ 软件**位操作**(bit-bang)模拟出 I2C 时序。这恰好把"I2C 协议怎么在 SCL/SDA 上执行"讲得最透。

**probe**(`i2c-gpio.c:339`):

```c
static int i2c_gpio_probe(struct platform_device *pdev)
{
    /* 1. 获取 SDA/SCL 两根 GPIO(设备树 sda-gpios/scl-gpios) */
    priv->sda = i2c_gpio_get_desc(dev, "sda", 0, GPIOD_OUT_HIGH_OPEN_DRAIN);
    priv->scl = i2c_gpio_get_desc(dev, "scl", 1, GPIOD_OUT_HIGH_OPEN_DRAIN);

    /* 2. 填位操作回调(怎么翻 SCL/SDA) */
    bit_data->setsda = i2c_gpio_setsda_val;   /* 拉 SDA 高/低 */
    bit_data->setscl = i2c_gpio_setscl_val;   /* 拉 SCL 高/低 */
    bit_data->getsda = i2c_gpio_getsda;       /* 读 SDA */
    bit_data->getscl = i2c_gpio_getscl;       /* 读 SCL(支持时钟拉伸需要) */
    bit_data->udelay = 5;                      /* 每个 bit 5μs → ~100kHz */

    /* 3. 注册 adapter(挂 i2c-algo-bit 的 master_xfer = bit_xfer) */
    i2c_bit_add_numbered_bus(adap);
    return 0;
}
```

**位操作传输 `bit_xfer`**(`drivers/i2c/algos/i2c-algo-bit.c:520`)——这是"软件模拟 I2C 协议"的核心,完整实现协议的"起始→地址→数据→ACK→停止":

```c
static int bit_xfer(struct i2c_adapter *i2c_adap, struct i2c_msg msgs[], int num)
{
    i2c_start(adap);                    /* 产生起始条件(SCL 高时 SDA 下降沿) */
    for (i = 0; i < num; i++) {
        if (i) i2c_repstart(adap);     /* 后续消息:Repeated Start(不发 Stop) */
        bit_doAddress(adap, &msgs[i]);  /* 发地址字节(7bit<<1 + R/W) + 等 ACK */
        if (msgs[i].flags & I2C_M_RD)
            readbytes(adap, &msgs[i]);  /* 读:主设备发 ACK 继续读、NACK 结束 */
        else
            sendbytes(adap, &msgs[i]); /* 写:从设备 ACK */
    }
    i2c_stop(adap);                    /* 产生停止条件(SCL 高时 SDA 上升沿) */
    return ret;
}
```

**逐位发字节 + 读 ACK**(`i2c-algo-bit.c:152` 的 `i2c_outb`)——这是最底层的 SCL/SDA 操作:

```c
static int i2c_outb(struct i2c_adapter *i2c_adap, unsigned char c)
{
    for (i = 7; i >= 0; i--) {         /* 从 MSB 开始逐位发 */
        setsda(adap, (c >> i) & 1);    /* 设 SDA = 本位值 */
        udelay(adap->udelay / 2);      /* 等半周期 */
        sclhi(adap);                   /* SCL 拉高(从设备在此时钟沿读 SDA) */
        scllo(adap);                   /* SCL 拉低 */
    }
    /* 第 9 个 clock:读 ACK */
    sdahi(adap);                       /* 主设备释放 SDA(让从设备驱动) */
    sclhi(adap);                       /* SCL 拉高 */
    ack = !getsda(adap);              /* SDA 被从设备拉低 = ACK */
    scllo(adap);
    return ack ? 1 : 0;               /* 1=ACK, 0=NACK */
}
```

这段代码把 I2C 协议"每个 bit 在 SCL 低时改 SDA、SCL 高时采样"的精髓写透了——`setsda`(设数据)→ `sclhi`(时钟沿,从设备采样)→ `scllo`(准备下一位),重复 8 次发完字节、第 9 次读 ACK。GPIO 模拟 I2C 的速率完全由 `udelay` 决定(`udelay=5` → ~100kHz、`udelay=50` → ~10kHz)。

### 六、数据流:用户态到 EEPROM 硬件的完整链路

以"用户读 EEPROM 内容"为例,走完整条链:

1. **用户态**:`hexdump /sys/bus/nvmem/devices/<name>/nvmem`(或 `cat`)。
2. **nvmem core**:`nvmem->reg_read` → `at24_read`(`at24.c:437`)。
3. **at24 驱动**:`mutex_lock` → `at24_regmap_read`(`:348`)→ `regmap_bulk_read(regmap, offset, buf, count)`。
4. **regmap I2C**:`regmap_i2c_read` → `i2c_transfer(adapter, msgs, 2)`(发"寄存器地址"+"读数据"两条消息)。
5. **I2C core**:`i2c_transfer`(`i2c-core-base.c:2293`)→ 锁总线 → `__i2c_transfer`(`:2221`)→ `adapter->algo->master_xfer`。
6. **adapter 驱动(i2c-gpio)**:`bit_xfer`(`i2c-algo-bit.c:520`)→ `i2c_start` + `i2c_outb`(发地址) + `readbytes`(逐字节读 + ACK) + `i2c_stop`。
7. **GPIO 硬件**:`setsda`/`setscl`(`i2c_gpio_setsda_val`/`setscl_val`)翻转 GPIO 引脚 → SCL/SDA 电平变化 → EEPROM 芯片响应。
8. **EEPROM**:收到地址 + 寄存器偏移 → 输出数据字节。

整条链:用户 → nvmem → `at24_read:437` → `regmap_bulk_read` → `i2c_transfer:2293` → `bit_xfer:520` → `i2c_outb:152` → GPIO SCL/SDA → EEPROM。

### 七、源码真踩坑(都是读源码才发现的)

1. **7-bit 地址存 `client->addr`,传输时由 adapter 左移成 8-bit**(`i2c.h:342`/`:948`)。设备树 `reg = <0x50>` 给的是 7-bit;`client->addr` 也是 7-bit;但实际线上的"地址字节"是 `addr << 1 | R/W`(`i2c_8bit_addr_from_msg`)。如果你拿数据手册上的"8-bit 写地址 0xA0"(= 0x50 << 1)直接填设备树,就错了——设备树要填 7-bit `0x50`。

2. **不是所有 adapter 都支持原生 SMBus**(`i2c-core-smbus.c:554`)。有些 SoC I2C 控制器只实现了 `master_xfer`(纯 I2C),没有 `smbus_xfer`。framework 靠 `i2c_smbus_xfer_emulated`(`:323`)把 SMBus 操作模拟成 i2c_msg。但有些 SMBus 协议(如 block process call)模拟不了——驱动 probe 时要 `i2c_check_functionality` 检查 adapter 能力,别假设 SMBus 一定可用。

3. **GPIO 模拟 I2C 不能读 SCL 时,不支持时钟拉伸**(`i2c-algo-bit.c:75` `sclhi`)。时钟拉伸(clock stretching)是从设备忙时拉低 SCL 暂停主设备——需要主设备能"读 SCL"等待从设备释放。如果 GPIO 配成 SCL 只输出(不能读),`getscl` 为 NULL,`sclhi` 不等(`i2c-algo-bit.c:88` 直接 goto done),时钟拉伸就失效——从设备慢一点就丢数据。`i2c-gpio` 设备树有 `scl-is-output-only` 属性时就是这种情况。

4. **大容量 EEPROM 用多个 I2C 地址**(`at24.c:525` `at24_make_dummy_client`)。24C02(256B)一个地址够;但 24C1025(128KB)靠"地址高位当 I2C 地址扩展"——bank 切换。at24 驱动给大容量 EEPROM 创建多个 dummy client(各占一个 I2C 地址),读写时 `at24_translate_offset`(`:348`)按偏移选对应 bank。这种"用 I2C 地址空间扩展容量"的硬件设计,驱动处理起来相当绕。

5. **at24 的 regmap 必须 `disable_locking = true`**(`at24.c:689`)。at24 驱动自己用 `mutex_lock(&at24->lock)` 保护(因为要分块读 + 页边界处理 + 写等待),如果 regmap 也锁,两层锁会死锁。所以 regmap 配 `disable_locking`,让驱动自己管锁。

6. **仲裁丢失重试**(`i2c-core-base.c:2256`)。多主系统(I2C 总线上多个主设备)里,两个主同时发起传输、地址不同时 → 线与仲裁,输的一方返回 `-EAGAIN`。framework 在 `adap->retries` 次内自动重试。单主系统(绝大多数嵌入式)不会遇到,但要知道这个机制。

7. **`udelay` 决定 GPIO I2C 速率**(`i2c-gpio.c:406`)。`udelay=5` → ~100kHz、`udelay=50` → ~10kHz。设备树 `i2c-gpio,delay-us = <5>` 配。速率不能太高(GPIO 翻转 + 上拉 RC 充电需要时间),否则信号失真。

## 动手试试

> I2C 在几乎所有真板上有;QEMU virt 可挂 virtio-i2c 或 `-device loader` 加 I2C 设备。以下在真板或宿主做。

1. `ls /sys/bus/i2c/devices/`(adapter 是 `i2c-N`,client 是 `N-xxxx`);`i2cdetect -y 0`(若有 i2c-tools)扫总线看挂了哪些地址。
2. `cat /sys/bus/i2c/devices/0-0050/name`(若有 EEPROM)看 client 名;`i2cget -y 0 0x50 0x00 b`(读 EEPROM 地址 0x50 的寄存器 0x00)。
3. 读 `drivers/i2c/algos/i2c-algo-bit.c:152 i2c_outb` + `:520 bit_xfer`,对照本篇第五节的协议逐步走——这段代码把 I2C 协议讲透了。
4. 读 `drivers/misc/eeprom/at24.c:596 at24_probe`,看一个真实 I2C client 驱动怎么 probe + 注册成 nvmem。
5. 思考题:设备树里 EEPROM 写 `reg = <0x50>`,但数据手册上写"写地址 0xA0、读地址 0xA1"——这俩是什么关系?为什么设备树填 0x50?(提示:7-bit vs 8-bit,左移 + R/W)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):
  - framework:`drivers/i2c/i2c-core-base.c`(`i2c_add_adapter:1653`/`i2c_device_match:139`/`i2c_device_probe:491`/`i2c_transfer:2293`/`__i2c_transfer:2221`)、`drivers/i2c/i2c-core-smbus.c`(`i2c_smbus_read_byte_data:103`/`i2c_smbus_xfer_emulated:323`)、`drivers/i2c/i2c-core-of.c`(`of_i2c_register_devices:84`)。
  - 数据结构:`include/linux/i2c.h:733 struct i2c_adapter`、`:544 struct i2c_algorithm`、`:331 struct i2c_client`、`:270 struct i2c_driver`、`:948 i2c_8bit_addr_from_msg`(7→8 bit 地址)。
  - 典型 client:`drivers/misc/eeprom/at24.c`(EEPROM,本篇走读)、`drivers/hwmon/lm75.c`(温度,[32 hwmon](./32-drv-hwmon.md) 已走读)。
  - 典型 adapter:`drivers/i2c/busses/i2c-gpio.c`(GPIO bit-bang,本篇走读)+ `drivers/i2c/algos/i2c-algo-bit.c`(`bit_xfer:520`/`i2c_outb:152`)、SoC 控制器如 `i2c-imx.c`/`i2c-bcm2835.c`。
- kernel.org:[I2C](https://docs.kernel.org/i2c/)、`Documentation/i2c/`(writing-clients/summary/dev-interface...)。
- 关联本站:[10 platform](./10-drv-platform.md)/[11 dts](./11-drv-dts.md) I2C adapter 是 platform 设备、client 从设备树生成;[32 hwmon](./32-drv-hwmon.md) LM75 是典型 I2C client;[35 nvmem](./35-drv-nvmem.md) AT24 注册成 nvmem。
