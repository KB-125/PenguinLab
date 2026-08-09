---
title: "网络设备驱动:net_device 与 NAPI"
slug: drv-netdev
prerequisites:
  - drv-model
next:
  - drv-gpio
difficulty: advanced
tags: [driver, netdev, net_device, sk_buff, napi, ethernet, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/networking/
  - source: third_party/linux（6.19）include/linux/netdevice.h、include/linux/skbuff.h、net/
maturity: drafting
related:
  - /tutorials/drivers/00-drv-model
---

> 🔨 **整理中** · 这一篇讲**网络设备驱动**——网卡(以太网/Wi-Fi/virtio-net)这类"按包收发、接入网络协议栈"的设备。素材以 6.19 源码 + kernel.org [networking 文档](https://docs.kernel.org/networking/) 为权威。核心概念:`net_device`(网卡抽象)、`sk_buff`(网络包)、**NAPI**(中断+轮询混合,抗中断风暴)。

## 做什么

块设备按"块/扇区"走块 I/O 层,网络设备按"**包(packet)**"走**网络协议栈**(TCP/IP)。网卡驱动不直接面对 `read`/`write` 系统调用,而是:接收方向——硬件收包、驱动从网卡 FIFO 取出包构造成 `sk_buff`、往协议栈 `netif_rx`/`napi_gro_receive` 推;发送方向——协议栈把要发的包构造成 `sk_buff` 调驱动的 `ndo_start_xmit`、驱动让它 DMA 出去。驱动是"硬件和协议栈之间的搬运工"。这一篇拆 `net_device`(网卡怎么注册进协议栈)、`net_device_ops`(网卡的回调表)、`sk_buff`(包的数据结构)、NAPI(高吞吐下怎么不被中断压垮)。

## 要了解什么

### 一、网络设备 vs 块/字符设备

网络设备**不是**字符/块那种"`cdev_add`/`device_add_disk` + `/dev` 节点"的路子——它没有对应的 `/dev` 设备节点(用户态通过 socket 而非 read/write 访问),而是注册进网络协议栈、提供 `net_device_ops` 回调,协议栈发包/收包时调它。它在 sysfs 里以 `/sys/class/net/<name>/` 出现(因为 net 设备归 `net` class),`ip link`/`ifconfig` 操作的就是 `net_device`。

### 二、`net_device`:网卡抽象

**`struct net_device`**(`include/linux/netdevice.h:2105`)是一个**网卡**的化身——名字(`eth0`/`wlan0`)、MAC 地址、MTU、收发统计、`net_device_ops`、NAPI 列表等。分配用 `alloc_etherdev`(以太网)或 `alloc_netdev`(自定义),填好后 `register_netdev` 注册进协议栈。每个网卡一个 `net_device`,协议栈内部按它管理"哪个接口收发哪个包"。

### 三、`net_device_ops`:网卡回调表

**`struct net_device_ops`**(`netdevice.h:1424`)是网卡的 vtable,核心回调:

- **`ndo_open`/`ndo_stop`**:`ip link set up/down` 时调,驱动在这里使能/关闭硬件、申请中断、启动 NAPI。
- **`ndo_start_xmit`**:**发包核心**——协议栈把一个 `sk_buff` 传过来,驱动让它 DMA 发出去,返回 `NETDEV_TX_OK`。
- `ndo_set_rx_mode`:设多播/混杂模式。
- `ndo_get_stats64`:返回收发统计(给 `/proc/net/dev`、`ip -s link`)。
- `ndo_change_mtu`:改 MTU。

注意没有"收包"回调——收包是硬件中断触发的,驱动在 ISR 里主动构造 `sk_buff` 推给协议栈(下一节的 NAPI)。

### 四、`sk_buff`:网络包的容器

**`sk_buff`(套接字缓冲,`include/linux/skbuff.h`)** 是网络包在内核里的标准容器。它不复制包内容、而是用一组指针标出"包数据在 buffer 里的位置",各层协议(以太网/IP/TCP)处理时通过 `skb_push`/`skb_pull`/`skb_reserve` 调整这些指针——加头时 push(指针往低地址推)、剥头时 pull(往高地址推)。一个 sk_buff 从驱动收到开始,层层上传到 socket,或从 socket 层层下发到驱动发送,沿途不复制包数据、只挪指针,高效。sk_buff 还带 `dev`(所属网卡)、协议类型、校验和、路由缓存等元数据。

### 五、NAPI:中断 + 轮询的混合,抗中断风暴

高速网络下(每秒百万包),每包都中断 CPU 会被中断风暴压垮——光处理中断就耗尽 CPU,没空真正收包。**NAPI(New API)** 的思路:**中断只是触发"开始轮询",轮询阶段关中断、用一个 while 循环从网卡批量取包**,取完(或达到预算/budget)再重开中断。这样高负载下从"每包一中断"退化成"一批包一轮询",中断数大减。

驱动用 `netif_napi_add(dev, &napi, my_poll_fn, weight)` 注册一个 poll 回调和权重(weight,该 NAPI 每轮能取的包数预算);收包中断里 `napi_schedule(&napi)`(关中断、调度软中断 poll);`my_poll_fn` 里循环从网卡 FIFO 取包、`napi_gro_receive` 推协议栈,取完 `napi_complete` 重开中断。现代网卡几乎都用 NAPI,它是网络驱动性能的关键。

### 六、注册流程

```c
struct net_device *dev = alloc_etherdev(sizeof(struct my_priv));
dev->netdev_ops = &my_netdev_ops;       /* :1424 */
netif_napi_add(dev, &my_priv->napi, my_napi_poll, NAPI_POLL_WEIGHT);
eth_hw_addr_set(dev, mac);              /* 设 MAC */
register_netdev(dev);                   /* 注册进协议栈,/sys/class/net/<name> 出现 */
```

`register_netdev` 后,`ip link set <name> up` 触发 `ndo_open`(使能硬件、`request_irq`、`napi_enable`),网络就通了。

## 动手试试

1. `ip link`/`ifconfig -a` 看网络设备列表;`ls /sys/class/net/` 看每个 net_device
2. `cat /proc/net/dev` 看每个网卡的收发统计(对应 `ndo_get_stats64`)
3. QEMU 加 virtio-net(`-netdev/ -device virtio-net`),Guest 里 `ip link set eth0 up` + `ping`
4. 读 `drivers/net/ethernet/` 下某简单驱动(或 `drivers/net/loopback.c`),看 `net_device_ops`/`napi` 怎么填
5. 思考题:为什么高速网卡都用 NAPI 而不是每包一中断?(提示:中断风暴)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/netdevice.h:2105 struct net_device`、`:1424 struct net_device_ops`;`include/linux/skbuff.h` 的 `sk_buff`;NAPI 在 `include/linux/netdevice.h`(`netif_napi_add`/`napi_schedule`/`napi_complete`)与 `net/core/dev.c`;协议栈核心 `net/core/`、各协议 `net/ipv4/`、`net/ipv6/`;示例驱动 `drivers/net/ethernet/`(如 intel/realtek)、`drivers/net/virtio_net.c`。
- kernel.org:[Networking](https://docs.kernel.org/networking/) 各子文档(NAPI、TX/RX 路径、统计...)。
- 关联本站:本篇是 [00 driver model](./00-drv-model.md) 的网络设备类型;网络协议栈的深入(协议层)属于本站 net 藤(已有 16 篇骨架);`sk_buff` 的链表用法见 [12 内核数据结构](../foundations/12-kernel-data-structures.md)。
