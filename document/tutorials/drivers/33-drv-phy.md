---
title: "net PHY:网卡物理层芯片的驱动框架(phylib)"
slug: drv-phy
prerequisites:
  - drv-netdev
  - drv-model
difficulty: advanced
tags: [driver, phy, phylib, mdio, mii, ethernet, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/networking/phy.html
  - source: third_party/linux（6.19）include/linux/phy.h、drivers/net/phy/
maturity: drafting
related:
  - /tutorials/drivers/14-drv-netdev
  - /tutorials/drivers/10-drv-platform
---

> 🔨 **整理中** · 这一篇深入讲 **网络 PHY(物理层)** 子系统——网卡里那颗"MAC 和网线之间"的 PHY 芯片(REALTEK RTL8211/Marvell 88E1512/Aquantia AQR 等千兆/万兆 PHY)的驱动框架(phylib)。素材以 6.19 源码 + kernel.org [PHY 文档](https://docs.kernel.org/networking/phy.html) 为权威。它是 [14 netdev](./14-drv-netdev.md) 的"物理层一半"展开。

## 做什么

一块以太网网卡其实有两部分:**MAC**(Media Access Controller,负责帧封装/收发调度,通常集成在 SoC 里)和 **PHY**(Physical layer,负责物理信号编码:4B/5B/PAM5/1000BASE-T 的线编码、Line driver 驱动双绞线)。MAC 和 PHY 之间走 **MII/GMII/RGMII/SGMII** 接口(数据线 + MDIO 管理总线)。内核网络栈只跟 MAC 通信(发帧给 MAC),但 PHY 要单独管——协商速率(10/100/1000M)、双工、自协商(autoneg)、链路状态、线缆诊断。**phylib**(`drivers/net/phy/`)就是 PHY 芯片的统一框架:不同厂商 PHY 各填一个 `phy_driver`,phylib 提供状态机 + MDIO 总线 + 和 MAC(net_device)的桥接。这一篇拆 phylib 的三件套 + PHY 状态机 + 现代 phylink。

## 要了解什么

### 一、三件套:`mii_bus`(MDIO 总线) / `phy_device`(PHY 实例) / `phy_driver`

- **`struct mii_bus`(MDIO 总线)**:MAC 通过 **MDIO/MDC**(两根管理线)读写 PHY 的寄存器(IEEE 802.3 Clause 22/45 定义)。一条 MDIO 总线可挂 32 个 PHY(各一个 5 位地址)。`mii_bus` 描述这条总线 + `read`/`write` 回调(MAC 控制器驱动填,操作 MDIO 寄存器)。MAC 驱动注册 `mii_bus`,`mdiobus_register`。
- **`struct phy_device`**(`include/linux/phy.h:662`):一个 PHY 实例——挂在某 `mii_bus` 上、有地址(`phy_addr`)、芯片 ID(读 PHY 寄存器 2/3 拿 vendor:model:rev)、当前状态(链路 up/down/速率/双工)。启动时 phylib 扫描 MDIO 总线,为每个存在的 PHY 创建一个 `phy_device`。
- **`struct phy_driver`**(`:1115`):PHY 驱动,匹配靠 ID(vendor OUI + model),核心回调:`soft_reset`/`config_init`(芯片初始化)/`config_aneg`(启动自协商)/`read_status`(读链路状态:link/speed/duplex)/`config_intr`/`handle_interrupt`/`suspend`/`resume`。

配对:扫描时读 PHY 寄存器 2/3 拿 ID,匹配 `phy_driver` 的 `phy_id`/`phy_id_mask`,命中则 attach。

### 二、PHY 寄存器:Clause 22 vs Clause 45

- **Clause 22**(老,寄存器 0-31):基本控制(0)、状态(1)、PHY ID(2/3)、自协商广播(4/5)、1000BASE-T 控制(9)/状态(10)。`phy_read(phydev, regnum)`(`:1648`)/`phy_write` 走这套。RTL8211/88E1512 这类千兆 PHY 用 Clause 22 + 扩展页。
- **Clause 45**(新,45/10GBASE-R/SFP+ 用):寄存器空间大(按 device type + 16-bit 地址),多用于万兆 PHY(Aquantia AQR)。`__mdiobus_read_c45`/`phy_read_mmd` 这套 API。

`phy_read(phydev, MII_BMCR)` 读基本控制寄存器、`phy_read(phydev, MII_BMSR)` 读状态(link up 位等)。PHY 驱动 `read_status` 就是读这些寄存器、解析成 `phydev->speed/duplex/link`。

### 三、PHY 状态机:自协商 + 链路

PHY 上电后典型流程:`config_init`(芯片特定初始化,写默认寄存器)→ `config_aneg`(启动自协商:PHY 和对端互相广播能力,协商出最高公共速率/双工)→ 轮询/中断检查链路状态 → `read_status`(链路 up 时读出协商出的 speed/duplex)。

phylib 有个**状态机**(`phy_state`:UP/DOWN/ANEG/READY/NOLINK/RUNNING),靠 `phy_status_poll`(定时轮询)或 PHY 中断驱动状态转换。链路状态变化(up→down 或 down→up)时,phylib 通知 MAC(`phy_mac_interrupt` → MAC 调整)。

### 四、`phylink`:现代 MAC-PHY 桥接

老的 MAC 驱动直接和 phylib attach(phy_find_first/phy_connect),自己管"PHY 状态变化 → 调 MAC 配置"。但现代网络(SFP+ 可插拔、固定链接、PHY-less 直连)场景复杂,内核引入 **phylink**(`drivers/net/phy/phylink.c`)作为 MAC 和 PHY 之间的一层:phylink 统一处理"PHY 在/不在、固定速率、SFP 模块插入"各种情况,给 MAC 一致的回调(`phylink_mac_ops`:`mac_config`/`mac_link_up`/`mac_link_down`)。新 MAC 驱动一律走 phylink,不直接碰 phylib。

### 五、用户态:`ethtool`

`ethtool eth0` 调一系列 ioctl 给 PHY:读链路状态/速率/双工(`ethtool eth0`)、改自协商(`ethtool -s eth0 autoneg on/off speed 1000 duplex full`)、看 PHY 寄存器(`ethtool -d eth0` 寄存器 dump)、线缆诊断(`ethtool --phy-tunable`/TDR)。这些 ioctl 走 net_device → phylib → PHY 驱动的 `read/write` 回调。

### 六、实战:RTL8211(千兆 PHY)

RTL8211(Realtek)是嵌入式板最常见的千兆 PHY(Raspberry Pi CM4、很多 SoC 板用它)。驱动 `drivers/net/phy/realtek.c`:

```c
static struct phy_driver realtek_drvs[] = {
    PHY_ID_MATCH_EXACT(0x001cc916),  /* RTL8211F 的 ID(vendor:model) */
    .name            = "RTL8211F Gigabit Ethernet",
    .config_init     = rtl8211f_config_init,  /* 配 RX/TX delay、LED */
    .config_aneg     = genphy_config_aneg,    /* 通用自协商(phylib 提供) */
    .read_status     = rtl8211f_read_status,  /* 读 BMCR/BMSR + 解析 */
    .soft_reset      = genphy_soft_reset,
    ...
};
module_phy_driver(realtek_drvs);
```

多数千兆 PHY 的 `config_aneg`/`read_status` 可直接用 phylib 的通用实现(`genphy_*`),驱动只填芯片特有的 `config_init`(RX delay 等寄存器)。`module_phy_driver` 宏一行注册。

### 七、踩坑

- **RGMII delay**:MAC 和 PHY 之间 RGMII 接口的时钟延迟(RX/TX delay)在哪一侧设(MAC 侧还是 PHY 侧)是经典坑——设备树 `phy-mode = "rgmii-id"`(PHY 内部加 delay)/`"rgmii-txid"`/`"rgmii-rxid"`/`"rgmii"`(不加,MAC 加)。配错链路通但大量丢包/误码。
- **自协商关不掉某些速率**:某些 PHY/交换机组合,自协商关了不识别固定速率。生产环境一般留 autoneg on。
- **Clause 45 vs 22 配错**:万兆 PHY(AQR)用 C45,MAC 控制器只支持 C22 的话读不到 PHY ID。`phy_interface_t`/`phy-mode` 要匹配。
- **SFP+ 模块**:SFP 笼子插不同模块(光模块/DAC/铜缆),phylink + SFP bus 动态识别——比固定 PHY 复杂,走 phylink 才好处理。

## 动手试试

1. `ethtool eth0`(宿主机)看 PHY 状态(Speed/Duplex/Link);`ethtool -i eth0` 看驱动;`ethtool -d eth0 | head` 看 PHY 寄存器 dump
2. `ethtool -s eth0 speed 100 duplex half autoneg off`(强制 100M 半双工)看链路重协商(⚠️ 可能断网)
3. QEMU virtio-net 没有 PHY(虚拟),要看真实 PHY 在真板或用 `phytool` 工具
4. 读 `drivers/net/phy/realtek.c`(RTL8211,典型千兆)或 `micrel.c`(KSZ9031)看 `phy_driver` 怎么填、`config_init` 怎么写芯片寄存器
5. 思考题:为什么 MAC 和 PHY 要分开两个芯片 + 两套驱动,而不是一颗芯片全包?(提示:分工、可换 PHY、模拟/数字工艺差异)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/phy.h:662 struct phy_device`、`:1115 struct phy_driver`、`:524 struct phy_c45_device_ids`、`:1648 phy_read`;phylib `drivers/net/phy/phy_device.c`/`phy.c`(状态机)/`phy-core.c`;MDIO `drivers/net/mdio/`;phylink `drivers/net/phy/phylink.c`;各厂商 PHY `drivers/net/phy/<vendor>.c`(realtek/micrel/marvell/aquantia/intel...)。
- kernel.org:[PHY](https://docs.kernel.org/networking/phy.html)、[phylink](https://docs.kernel.org/networking/sfp-phylink.html)、`Documentation/devicetree/bindings/net/ethernet-phy.yaml`。
- 关联本站:[14 netdev](./14-drv-netdev.md) MAC 驱动 + NAPI、[00 driver model](./00-drv-model.md) PHY 也是设备;PHY 在交换机/路由器/SFP 场景关联 net 子系统。
