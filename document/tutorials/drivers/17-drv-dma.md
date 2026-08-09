---
title: "DMA:让硬件自己搬数据,解放 CPU"
slug: drv-dma
prerequisites:
  - drv-model
next:
  - drv-usb
difficulty: advanced
tags: [driver, dma, dmaengine, dma_chan, dma_device, slave-dma, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/driver-api/dmaengine/
  - source: third_party/linux（6.19）include/linux/dmaengine.h、drivers/dma/
maturity: drafting
related:
  - /tutorials/drivers/00-drv-model
  - /tutorials/drivers/14-drv-netdev
---

> 🔨 **整理中** · 这一篇讲 **DMA(直接内存访问)** 子系统——让外设和内存之间、或内存和内存之间的数据搬运由 DMA 控制器硬件完成,不占 CPU。素材以 6.19 源码 + kernel.org [dmaengine 文档](https://docs.kernel.org/driver-api/dmaengine/) 为权威。内核统一用 **dmaengine** 框架(`drivers/dma/` + `dma_async_*` API)管理 DMA 控制器、给客户端提供统一接口。

## 做什么

外设和内存之间搬数据,如果不靠 DMA,CPU 得一个字节(或一个字)地循环读写外设 FIFO——海量 CPU 时间耗在"搬运"上。DMA 控制器是一块独立的硬件,能"自己"在外设和内存之间按描述符成块搬数据,CPU 只需给它描述好"搬哪、搬多少、方向",它在后台干完、给 CPU 一个中断。CPU 在这期间能干别的活。所以高吞吐外设(磁盘 DMA、网络、USB、音频、SPI 大块传输)都靠 DMA。内核的 **dmaengine** 子系统给 DMA 控制器驱动和 DMA 客户端各提供一套统一接口,让"哪个控制器/哪个客户端"解耦。这一篇拆 dmaengine 的两边:控制器驱动怎么写(`dma_device`)、客户端怎么用(`dmaengine_*` API)。

## 要了解什么

### 一、DMA 控制器:`dma_device` + `dma_chan`

每个 DMA 控制器内核里对应一个 **`struct dma_device`**(`include/linux/dmaengine.h:868`),它描述"这个 DMA 控制器能干什么、有哪些通道"。核心回调按"传输类型"分:

- **`device_prep_dma_memcpy`**:内存→内存拷贝(memcpy DMA)
- **`device_prep_slave_sg`**:外设↔内存的 scatter-gather 传输(slave DMA,如 UART/SPI 收发)
- **`device_prep_dma_cyclic`**:循环传输(音频 ALSA 用——环形 buffer 周期性搬)
- **`device_issue_pending`**:把提交的描述符真正发给硬件开始搬
- **`device_terminate_all`**:终止某通道上所有传输

一个 `dma_device` 下挂若干 **`struct dma_chan`**(`:338`,DMA 通道,DMA 控制器可并行跑多通道)。控制器驱动 `dma_async_device_register(&dmadev)` 注册进 dmaengine core。

### 二、两种 DMA:memcpy vs slave

DMA 传输分两大场景:**memcpy DMA**(内存→内存,纯搬运,典型用 `device_prep_dma_memcpy` 提交一段拷贝)和 **slave DMA**(外设↔内存,需指定"外设侧"是谁、数据宽度/突发长度等,用 `device_prep_slave_sg` 或 `device_prep_dma_cyclic`)。slave DMA 的"外设侧"通过 **DT 的 `dmas`/`dma-names` 属性**描述(对应外设的某个 TX/RX FIFO),客户端 `dma_request_chan(dev, "rx")` 拿到对应通道。

### 三、客户端用法:申请通道 → 准备描述符 → 提交 → 启动 → 回调

DMA 客户端(如 UART/音频/网卡驱动)的标准流程:

```c
struct dma_chan *chan = dma_request_chan(dev, "rx", &cfg);   /* 从设备树 "dmas" 拿 rx 通道 */
struct dma_async_tx_descriptor *desc;
desc = dmaengine_prep_slave_sg(chan, sg, nents, dir, flags); /* 准备一个 sg 传输描述符 */
desc->callback = my_dma_done;                                /* 完成时调 */
desc->callback_param = ctx;
dmaengine_submit(desc);                                       /* 提交到通道 */
dma_async_issue_pending(chan);                                /* 启动,DMA 开始搬 */
/* ... CPU 干别的;搬完 my_dma_done 被调 ... */
dma_release_channel(chan);                                    /* 用完释放 */
```

要点:DMA 是**异步**的——`dma_async_issue_pending` 立即返回,CPU 不等;搬完硬件中断→控制器驱动→dmaengine core 调你的 `callback`。回调通常在 tasklet/软中断上下文(不能睡),里面把缓冲"消费掉"(交给上层)、再准备下一个传输。这套异步+回调是 DMA 编程的基本范式。

### 四、DMA 地址与一致性

DMA 涉及"CPU 看到的虚拟地址"和"DMA 控制器看到的总线地址"两套,要用 `dma_map_single`/`dma_map_sg` 把虚拟地址映射成 DMA 地址(并处理 cache 一致性——CPU cache 的脏数据要让内存可见,否则 DMA 看到的是旧值)。一致性 DMA(常用 coherent buffer,`dma_alloc_coherent`)CPU 和外设都保证看到一致内容、不用手动 sync;流式 DMA(`dma_map_single` 那类)需 `dma_sync_*` 显式管理。这些 `dma_*` API 在 `include/linux/dma-mapping.h`,是 DMA 编程绕不开的地址/一致性工具。

## 动手试试

1. `ls /sys/class/dma/`(若存在)看 DMA 通道;某些 SoC 有 `/sys/kernel/debug/dmaengine/`
2. 读 `drivers/dma/dmatest.c`(内核自带的 DMA 测试模块)看一个完整的 memcpy DMA 客户端流程——它是 dmaengine 的"参考客户端"
3. 读一个简单 SoC DMA 控制器驱动(如 `drivers/dma/fsl-edma-main.c` 或 `drivers/dma/ste_dma40.c`)看 `dma_device` 怎么填
4. 进阶:在 ALSA 音频驱动里看 `device_prep_dma_cyclic` 的典型用法(环形 buffer 周期搬)
5. 思考题:为什么 DMA 客户端用"异步 + 回调"而非"同步等搬完"?(提示:CPU 利用率)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/dmaengine.h:868 struct dma_device`、`:338 struct dma_chan`、`struct dma_async_tx_descriptor`;`include/linux/dma-mapping.h`(`dma_map_single`/`dma_alloc_coherent`/`dma_sync_*`);实现在 `drivers/dma/`(`dmaengine.c` core、各 SoC 厂商驱动);参考客户端 `drivers/dma/dmatest.c`、ALSA 的 `sound/core/pcm_dmaengine.c`。
- kernel.org:[DMAEngine documentation](https://docs.kernel.org/driver-api/dmaengine/)、[DMA mapping guide](https://docs.kernel.org/core-api/dma-api.html)、[DMA API howto](https://docs.kernel.org/core-api/dma-api-howto.html)。
- 关联本站:本篇是 [00 driver model](./00-drv-model.md) 的 DMA 子系统类型;网络/音频/USB 这些高吞吐外设都靠 DMA(见 [14 netdev](./14-drv-netdev.md)、ALSA);DMA 描述符常和 scatter-gather 链表配合(见 [12 内核数据结构](../foundations/12-kernel-data-structures.md))。
