---
title: "USB 驱动:设备、接口与 URB"
slug: drv-usb
prerequisites:
  - drv-model
next:
  - drv-drm
difficulty: advanced
tags: [driver, usb, urb, hcd, usb-core, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/driver-api/usb/
  - source: third_party/linux（6.19）include/linux/usb.h、drivers/usb/
maturity: drafting
related:
  - /tutorials/drivers/00-drv-model
---

> 🔨 **整理中** · 这一篇讲 **USB 子系统**——它分两层:**主机控制器驱动(HCD,xHCI/EHCI 等)** 管"怎么和 USB 硬件总线通信",**USB 设备驱动**(HID/storage/net/serial 等类驱动)管"具体 USB 外设(键盘/U盘/网卡)怎么用"。素材以 6.19 源码 + kernel.org [USB 文档](https://docs.kernel.org/driver-api/usb/) 为权威。核心抽象:`usb_device`/`usb_interface`(设备/接口层次)+ **URB**(USB 请求块)。

## 做什么

USB 是个相当复杂的总线——设备能热插拔、能枚举、有 hub 拓扑、设备内部还分"配置-接口-端点"多层、传输类型分控制/批量/中断/等时四种。Linux 把它抽象成一套层次分明的子系统:`USB core` 管枚举/总线模型、`HCD`(主机控制器驱动,drivers/usb/host)管硬件协议、`USB 设备驱动`管具体外设。绝大多数驱动作者写的是**最后一层**——某个 USB 外设(USB 转 serial、USB 网卡、自定义 USB 设备)的驱动,这一篇就聚焦它:怎么用 `usb_driver` + `usb_device_id` 配对、怎么用 URB 和设备交换数据。

## 要了解什么

### 一、USB 的层次:设备 → 配置 → 接口 → 端点

USB 设备内部是分层的:一个**设备(device)** 可有多个**配置(config)**,一个配置下多个**接口(interface)**(每个接口代表一个独立功能,如 USB 复合设备:一个接口当键盘、一个当音频),一个接口下多个**端点(endpoint)**(端点是数据传输的最小单位,有方向 IN/OUT 和类型)。**USB 设备驱动通常绑定到"接口"而非整个设备**(所以一个复合 USB 设备会匹配多个驱动,各管一个接口)——这一点和 platform/pci 那种"一个设备一个驱动"不同。

### 二、`usb_driver` + `usb_device_id`:配对

USB 设备驱动核心是 **`struct usb_driver`**(`include/linux/usb.h`),和 `platform_driver` 同构:`probe`/`disconnect`(USB 叫 disconnect 不叫 remove)+ `id_table` + 内嵌 `device_driver`。配对靠 **`struct usb_device_id`**(`include/linux/mod_devicetable.h`),匹配字段比 platform 丰富:

- `idVendor`/`idProduct`(USB 设备的厂商/产品 ID,设备枚举时上报)
- `bInterfaceClass`/`bInterfaceSubClass`/`bInterfaceProtocol`(接口类,如 HID/Storage/Mass Storage 的类码)
- 或 `USB_DEVICE_AND_INTERFACE_INFO`/`USB_DEVICE` 宏生成表项

`MODULE_DEVICE_TABLE(usb, my_table)` 让模块能被 modprobe 按设备自动加载(udev 看到 USB 设备插入时 modprobe)。USB core 的 bus_type.match 用这张表和枚举出的 `usb_interface` 比对。

### 三、URB(USB Request Block):USB 传输的请求单位

USB 和设备交换数据的单位是 **URB**(`struct urb`,`include/linux/usb.h`),它描述一次传输:目标端点、传输类型(control/bulk/interrupt/isochronous)、数据 buffer、长度、方向、完成回调。流程:

```c
struct urb *u = usb_alloc_urb(0, GFP_KERNEL);     /* 分配 */
usb_fill_bulk_urb(u, dev, pipe, buf, len, my_urb_callback, ctx);  /* 填充(批量传输) */
usb_submit_urb(u, GFP_KERNEL);                     /* 提交给 USB core → HCD → 硬件 */
/* ... CPU 干别的;传输完成 my_urb_callback 被调(异步)... */
usb_free_urb(u);                                    /* 释放 */
```

URB 是**异步**的——`usb_submit_urb` 立即返回,硬件完成后回调(回调在原子上下文,不能睡)。四种传输类型各有 `usb_fill_*_urb` helper:`control`(控制,设备配置/命令)、`bulk`(批量,U 盘数据,可靠)、`interrupt`(中断,鼠标键盘小量周期数据)、`isochronous`(等时,音视频,不保证完整但保时序)。

### 四、同步 wrapper 与 USB class 驱动

URB 异步写起来啰嗦,内核提供**同步 wrapper**(`usb_control_msg`/`usb_bulk_msg`):它们内部提交 URB + 等完成,函数返回时数据已搬好(阻塞、可睡眠,适合进程上下文)。多数简单 USB 驱动用同步 API 就够,只有高吞吐/低延迟场景才手写异步 URB。

USB 还有一堆**类驱动**(`drivers/usb/storage/` U 盘、`drivers/usb/serial/` USB 转串口、`drivers/usb/input/hid/` HID、`drivers/net/usb/` USB 网卡):它们对"符合某类 USB 标准的设备"提供通用驱动——比如你的 U 盘符合 USB Mass Storage class,插上就被 `usb-storage` 驱动自动接管,不用写专属驱动。只有"非标准 USB 设备"才需要写专属 `usb_driver`。

## 动手试试

1. `lsusb`(宿主机)看 USB 设备树;`lsusb -v` 看某设备的配置/接口/端点(对照本篇第一节)
2. 插拔 USB 设备,`dmesg` 看 USB core 枚举/匹配驱动的过程
3. 读 `drivers/usb/usb-skeleton.c`(内核自带的 USB 驱动骨架)——它就是写 USB 设备驱动的标准模板
4. 进阶:`usbmon`(`Documentation/usb/usbmon.rst`)抓 USB 总线数据包,调试 USB 通信
5. 思考题:为什么 USB 设备驱动绑定到"接口"而非"设备"?(提示:USB 复合设备)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/usb.h`(`struct usb_driver`/`struct urb`/`usb_submit_urb`/`usb_fill_*_urb`/`usb_alloc_urb`/`usb_free_urb`)、`include/linux/mod_devicetable.h`(`struct usb_device_id`);USB core `drivers/usb/core/`(`urb.c`/`driver.c`/`hub.c`);HCD `drivers/usb/host/`(`xhci`/`ehci`/`ohci`);类驱动 `drivers/usb/storage/`/`serial/`/`input/hid/`;骨架 `drivers/usb/usb-skeleton.c`。
- kernel.org:[USB](https://docs.kernel.org/driver-api/usb/)、[Writing USB drivers](https://www.kernel.org/doc/html/latest/driver-api/usb/writing_usb_driver.html)、`Documentation/usb/`。
- 关联本站:本篇是 [00 driver model](./00-drv-model.md) 的 USB 子系统类型;USB 是另一条 bus(usb_bus_type),match/probe 框架同源;URB 异步回调和 [12 线程化中断](./12-drv-threaded-irq.md) 的 thread_fn 都是"硬件完成回调"范式。
