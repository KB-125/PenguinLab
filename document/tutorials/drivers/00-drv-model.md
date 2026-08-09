---
title: 'driver model:内核怎么知道"这个硬件该用哪个驱动"'
slug: drv-model
prerequisites:
  - fs-sysfs
  - kernel-data-structures
next:
  - drv-chardev
difficulty: intermediate
tags: [driver-model, device, bus_type, device_driver, class, kobject, platform, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - source: third_party/linux（6.19）drivers/base/、include/linux/device.h、include/linux/device/{driver,bus,class}.h
maturity: drafting
related:
  - /tutorials/kernel/fs/03-fs-sysfs
  - /tutorials/drivers/01-drv-chardev
---

> 🔨 **整理中** · 这一篇是 drivers 藤的**地基**——讲清楚 Linux 的统一设备模型(driver model):device / device_driver / bus_type / class 这套四件套,加上总线 `match` + 驱动 `probe` 的配对机制。它是 [fs-sysfs](../kernel/fs/03-fs-sysfs.md) 里讲的 kobject 体系的"上层应用"(device/driver/bus/class 全都内嵌 kobject),也是后面所有具体驱动类型(platform/usb/pci/...、以及 chardev 等)挂载的框架。素材以 6.19 源码(`drivers/base/`)为权威;动手部分在 QEMU 亲手验过之前标"待亲测"。

## 做什么

写一个字符设备驱动([01 chardev](./01-drv-chardev.md))时,我们 `misc_register` 或 `cdev_add` 就把设备注册了,好像没怎么碰"设备模型"。可一旦你往内核里插一个真实硬件驱动——platform 设备、USB 设备、PCI 设备——立刻会撞上一套术语:`probe`/`remove`、`platform_driver_register`、`of_match_table`、`/sys/bus/...`。这背后就是 **driver model**:内核管理"什么硬件、用什么驱动、它们怎么配对、怎么暴露给用户态"的统一框架。

这一篇我们拆 driver model 的四件套——**device**(一个设备实例)、**device_driver**(驱动)、**bus_type**(总线)、**class**(按功能分类),以及它们之间最关键的机制:**总线用 `match` 把 device 和 driver 配对、配对上了就调 driver 的 `probe` 初始化设备**。理解这套,你就能看懂"为什么内核启动时会自动给你的硬件加载驱动"(回答:bus 的 match + udev/userspace 的配合)、为什么 `/sys` 长成那副目录树(回答:driver model 的 kobject 投影),以及写 platform 驱动时那套 `probe`/`of_match` 套路到底在干什么。

## 要了解什么

### 一、driver model 是什么:统一设备管理框架(回扣 sysfs)

[fs-sysfs](../kernel/fs/03-fs-sysfs.md) 那篇我们讲了 kobject——"能在 sysfs 里出现的对象"的基类。driver model 就是建立在 kobject 之上的**统一设备管理框架**:它把内核里所有"设备相关的东西"——设备、驱动、总线、类——都用内嵌 kobject 的结构体表示,于是它们天然就在 `/sys` 里有目录、有层级、能被用户态(udev 等)枚举。换句话说,**driver model 是 kobject 体系的"设备语义层"**:kobject 提供"对象 + sysfs 暴露"的机制,driver model 在上面定义"什么是设备、什么是驱动、它们怎么关联"的语义。

这套模型解决的核心问题是:**当一个设备出现(硬件热插拔、或内核启动时枚举),内核怎么知道该用哪个驱动?** driver model 的答案就是下面几节要讲的"总线 match + 驱动 probe"机制。

### 二、四件套:`device` / `device_driver` / `bus_type` / `class`

**`struct device`**(`include/linux/device.h:563`)——一个**设备实例**的化身。无论这个设备是物理的(PCI 卡、USB 鼠标)还是虚拟的(platform 设备、纯软件设备),内核里都对应一个 `device` 结构体。关键字段:

```c
struct device {
    struct kobject       kobj;       /* 在 sysfs 里的化身(回扣 fs-sysfs) */
    struct device       *parent;     /* 父设备(硬件拓扑:这个设备挂在谁下面) */
    struct device_private *p;        /* 私有数据(含到 bus/driver 的关联) */
    ...
    struct device_driver *driver;    /* 当前适配上的驱动(没适配则为 NULL) */
    ...
    struct device_node  *of_node;    /* 关联的设备树节点(关联 drv-dts) */
    ...
};
```

`kobj` 让它进 sysfs;`parent` 表达硬件拓扑(USB 设备的 parent 是它插的 USB hub);`driver` 指向"当前绑定的驱动"(配对成功后填上);`of_node` 指向设备树节点(ARM/嵌入式世界里设备来源)。

**`struct device_driver`**(`include/linux/device/driver.h:98`)——**驱动**本身。它代表"一段能管理某类设备的代码"。关键字段:`name`(驱动名)、`bus`(它属于哪条总线)、`probe`/`remove`(设备配对成功/解绑时调的回调)、`owner`(`THIS_MODULE`)、`of_match_table`(设备树匹配表)。一个驱动可以适配多个设备(同一型号网卡插几张,共享一个驱动)。

**`struct bus_type`**(`include/linux/device/bus.h:78`)——**总线类型**。它是 device 和 driver 配对的"红娘"。关键字段:`name`(bus 名,如 `platform`/`usb`/`pci`)、**`match`(device 和 driver 怎么算"配对成功"——核心回调)**、`uevent`(热插拔事件上报)、`probe`/`remove`(总线层面的绑定/解绑,通常转发给 driver 的同名回调)。

**`struct class`**(`include/linux/device/class.h:50`)——**按功能分类**。和 bus 不同,class 不关心"设备挂在哪条总线上",只关心"它是干什么的":网络设备都属于 `net` 类、块设备属于 `block` 类、输入设备属于 `input` 类。于是同一个设备在 sysfs 里**既在 `/sys/devices/...`(按硬件拓扑)出现,又在 `/sys/class/<类名>/...`(按功能)出现一个软链接**——这就是 [fs-sysfs](../kernel/fs/03-fs-sysfs.md) 里讲的"目录镜像"的由来。

### 三、核心机制:`bus.match` + `driver.probe`(设备-驱动配对)

driver model 最关键的机制,是"**一个 device 出现时,总线怎么给它找到 driver**"。流程是这样的:

1. **设备注册**:某个 device 被注册到 bus(启动时内核枚举硬件,或热插拔时)。它进 bus 的设备链表。
2. **`match`**:总线遍历自己上面所有已注册的 `device_driver`,对每个调 `bus->match(dev, drv)`,问"这个驱动适配这个设备吗?"。`match` 的判定由具体 bus 实现:platform 总线比对 `of_match_table`(设备树 compatible)/`name`/`id_table`;USB 总线比对 vendor/product ID;PCI 比对 vendor/device ID。第一次返回真,这个 driver 就"候选"了。
3. **`probe`**:match 成功后,bus 调 `driver->probe(dev)`(或 platform 里的 `platform_driver->probe(pdev)`)。probe 是**驱动初始化设备**的核心回调——在里面使能硬件、注册中断、映射 I/O、注册 cdev/网络设备/块设备等。probe 成功(返回 0),device 和 driver **绑定**(device->driver 填上)。
4. **`remove`**:设备拔掉或驱动卸载时,调 `driver->remove(dev)`,做 probe 的逆操作(释放资源、注销设备)。

反过来也一样:**驱动注册**到一个 bus 时(比如 `module_init` 里 `platform_driver_register`),bus 会拿这个新 driver 去和所有**已注册但还没配对**的 device 反向 match 一遍——这就是"先有设备树节点(device)、insmod 驱动(driver)后自动 probe"的机制根。这套双向 match 是 driver model 能"自动加载/配对"的核心。

### 四、sysfs 镜像:driver model 在 `/sys` 的投影

把四件套的 kobject 投影到 sysfs,就是你熟悉的 `/sys` 目录:

- `/sys/devices/**`——按硬件拓扑组织的 device 树(`device.parent` 决定层级)
- `/sys/bus/<busname>/{devices,drivers}/`——每条 bus 一个目录,下面 `devices/`(软链到 `/sys/devices/`)和 `drivers/`(注册到这条 bus 的驱动)
- `/sys/class/<classname>/`——每个 class 一个目录,下面是该类的设备(软链到 `/sys/devices/`)
- `/sys/module/<modname>/`——每个内核模块一个目录(模块也内嵌 kobject)

所以"为什么 `/sys` 长成这样"的答案是:**它是 driver model 这棵对象树的投影**。你在 `/sys/devices/...` 下看到的一个目录,就是内核里一个 `device` 结构体的化身;它的 `driver` 软链接指向当前绑定的驱动。用户态工具(udev、mdev)就是监听 driver model 的事件(kobject_uevent)来自动创建 `/dev` 节点、加载固件等的。

### 五、生命周期:引用计数 + `release`(回扣 chardev 的 cdev)

driver model 的对象(device/driver/bus/class)都靠 kobject 的**引用计数**管理生命周期:`get_device`/`put_device`(底层 `kobject_get`/`kobject_put`),引用计数归零时触发 kobj_type 的 `release` 方法、真正释放结构体。这套机制和 [chardev](./01-drv-chardev.md) 里 cdev 的生命周期、[fs-sysfs](../kernel/fs/03-fs-sysfs.md) 里 kobject 的引用计数是同源——**内核里凡是"对象 + 共享引用"的东西,统一用这套计数 + release 回调**([内核数据结构](../foundations/12-kernel-data-structures.md) 里 list_head 的用法、这里 kobject 的生命周期,都是这种"内核惯用模式"的实例)。写驱动时记住:device 的最后一个引用释放时,release 会跑——别在 release 后还碰它。

### 六、platform:嵌入式最常用的"虚拟总线"

driver model 里有一条特殊的总线叫 **platform 总线**(`platform_bus`)。它不是物理总线(USB/PCI 那种有真实总线协议),而是个**虚拟总线**——专门收容那些"集成在 SoC 里、不挂任何外部总线"的设备:SoC 的 UART 控制器、I2C 控制器、定时器、看门狗、GPIO 控制器……这些设备没有 PCI vendor ID、没有 USB 枚举,它们在 ARM/嵌入式世界里通过**设备树**描述(device tree 的节点),内核解析设备树后生成对应的 `platform_device` 注册到 platform bus;你的驱动写成一个 `platform_driver` 注册到同一条 bus,platform 总线的 `match` 用 `of_match_table` 把它们配对、触发 probe。

```c
/* include/linux/platform_device.h:23 / :239 */
struct platform_device { ... struct device dev; ... };   /* 内嵌 device */
struct platform_driver { int (*probe)(struct platform_device *); ... };

/* 驱动注册 */
platform_driver_register(&my_drv);    /* :816 起的 platform_device_register 是设备侧 */
```

platform 是嵌入式 Linux 驱动开发的**主战场**——绝大多数 SoC 外设驱动都是 platform_driver。它的深入(设备树绑定、probe 实现套路、devm_ 资源管理)留给后续的 [drv-platform](./10-drv-platform.md)/[drv-dts](./11-drv-dts.md) 节点,这里先建立"platform = 无总线设备的归宿 + of_match 配对"的认知。

## 动手试试

> 这一篇 example 偏观察,用 `/sys` 把 driver model 这棵树看活。

1. QEMU 里 `ls /sys/devices/` 看设备拓扑树;`ls /sys/bus/` 看有哪些总线(platform/usb/virtio...);`ls /sys/class/` 看有哪些类(net/block/input/mem/...)——三者是同一批 device 的三种视角(拓扑/总线/功能)
2. `ls -l /sys/class/net/lo/device 2>/dev/null` 或 `ls -l /sys/devices/...` 下某个设备的 `driver` 软链接,看它指向 `/sys/bus/<bus>/drivers/<drvname>`——直观看到"device 当前绑定的 driver"
3. `ls /sys/bus/platform/devices/` 和 `/sys/bus/platform/drivers/`,看 platform 总线上有哪些 device 和 driver
4. 进阶:写一个极简的 `platform_driver`(用 `module_platform_driver` 宏 + `of_match_table` 匹配一个虚构的 compatible),`insmod` 后在 `/sys/bus/platform/drivers/<你的驱动>/` 看到它出现;对照本篇第三节理解"驱动注册 → bus 反向 match → probe"的链条
5. 思考题:为什么 platform 总线存在?直接给每个 SoC 外设写个独立驱动、不走 bus 不行吗?(提示:driver model 的"统一 match/probe 框架 + sysfs 暴露 + udev 集成"红利)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):四件套——`include/linux/device.h:563 struct device`、`include/linux/device/driver.h:98 struct device_driver`、`include/linux/device/bus.h:78 struct bus_type`、`include/linux/device/class.h:50 struct class`;platform 在 `include/linux/platform_device.h`(`platform_device :23`/`platform_driver :239`)与 `drivers/base/platform.c`(`platform_device_register :816`);整个 driver model 的实现在 `drivers/base/`(`device.c`/`driver.c`/`bus.c`/`class.c`/`platform.c`...)。
- 关联本站:本篇是 [fs-sysfs](../kernel/fs/03-fs-sysfs.md) kobject 体系的设备语义层;生命周期计数 + release 和 [chardev](./01-drv-chardev.md) 的 cdev 同源;`list_head`/`container_of` 在 driver model 里大量使用(见 [内核数据结构](../foundations/12-kernel-data-structures.md));platform 的深入、设备树绑定留给后续 drv-platform/drv-dts 节点。
- 经典纸面参考:LDD3 第 14 章《设备模型》讲 driver model,部分 API(尤其 device 的字段、probe 的签名)在 6.x 有演变,结合 `drivers/base/` 源码看。
