---
title: "platform 驱动:嵌入式 SoC 外设的标准开发套路"
slug: drv-platform
prerequisites:
  - drv-model
  - kernel-module-hello
next:
  - drv-dts
difficulty: intermediate
tags: [driver, platform-driver, probe, of_match, devm, device-tree, remove_new, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - source: third_party/linux（6.19）drivers/base/platform.c、include/linux/platform_device.h
maturity: drafting
related:
  - /tutorials/drivers/00-drv-model
  - /tutorials/drivers/05-drv-irq
---

> 🔨 **整理中** · 这一篇把 [drv-model](./00-drv-model.md) 里讲的 platform 总线概念落到"**怎么写一个 platform 驱动**"上——嵌入式 SoC 外设(UART/I2C/GPIO/定时器...)的开发套路:`of_match_table` 配对、`probe`/`remove_new` 回调、`devm_` 托管资源、`module_platform_driver` 注册宏。素材以 6.19 源码为权威。校订增量:6.x 推荐用 `.remove_new`(返回 void)取代老的 `.remove`(返回 int)。动手部分在 QEMU 亲手跑过之前标"待亲测";设备树解析的深入留给下一篇 [drv-dts](./11-drv-dts.md)。

## 做什么

[drv-model](./00-drv-model.md) 那篇我们说 platform 总线是"无总线设备的归宿",SoC 上那些集成外设都走它。可真要给一个具体的 SoC 外设写驱动,具体怎么动手?总线已经替我们做了"配对"——只要设备树里有这个设备的节点(带 `compatible` 字符串)、我们的驱动 `of_match_table` 里有同款 `compatible`,platform 总线的 `match` 就会把它们配起来、自动调我们的 `probe`。所以写 platform 驱动,核心就是回答三个问题:**"我怎么声明我能驱动谁"**(of_match_table)、**"配对成功后我干什么"**(probe)、**"我怎么把这一大堆样板代码写短"**(module_platform_driver 宏 + devm_ 资源管理)。

这一篇我们就把这套"嵌入式驱动标准套路"完整走一遍。读完它,你拿一个真实的 SoC 外设(比如一个虚拟的 LED 控制器、一个 GPIO 控制器)写驱动,骨架就能搭出来;剩下的只是"在 probe 里对这个具体硬件做具体初始化"的活。它是 ARM/嵌入式 Linux 驱动开发的主战场,绝大多数 BSP 驱动都是这套路的变体。

## 要了解什么

### 一、`platform_driver`:platform 驱动的结构体

一个 platform 驱动,内核里就是一个 **`struct platform_driver`**(`include/linux/platform_device.h:239`)。关键字段我们抓出来:

```c
struct platform_driver {
    int  (*probe)(struct platform_device *);         /* :240 配对成功时调,初始化设备 */
    void (*remove_new)(struct platform_device *);    /* 解绑时调,probe 的逆操作 */
    ...
    struct device_driver driver;                      /* 内嵌通用 driver(关联 drv-model) */
    const struct platform_device_id *id_table;        /* 非 device tree 的 ID 匹配(老式) */
};
```

核心是两个回调——**`probe`**(设备配对成功时调,在这里使能硬件、注册中断、映射 I/O、最后把设备注册给对应的子系统)和 **`remove_new`**(解绑时调,做 probe 的逆操作)。`driver` 字段是 [drv-model](./00-drv-model.md) 讲的通用 `device_driver`,里面挂着 `name`、`of_match_table`(下一节)、`owner`(`THIS_MODULE`)等——platform_driver 通过内嵌它接入统一设备模型。

> ⚠️ **校订:6.x 用 `.remove_new` 取代 `.remove`**
> 老(5.x 及之前)的 platform_driver 用 `.remove`,签名是 `int (*remove)(struct platform_device *)`(返回错误码);6.x 推广 **`.remove_new`**,签名 `void (*)(struct platform_device *)`——因为 remove 的返回值从来没人检查、强行返回错误还会让核心代码为难,所以新接口直接 void。6.19 里 `.remove` 仍可用(向后兼容),但新代码写 `.remove_new`,checkpatch 会建议你迁移。这是写 platform 驱动时最容易和 LDD3/老博客对不上的一个点。

### 二、`of_match_table`:声明"我能驱动谁"

platform 驱动怎么声明自己适配哪些设备?靠 `driver.of_match_table`——一张 **`struct of_device_id`** 数组(定义在 `include/linux/mod_devicetable.h`),每项的核心是 `compatible` 字符串:

```c
static const struct of_device_id pl_match[] = {
    { .compatible = "penguinlab,pl-demo", },   /* 和设备树节点里的 compatible 严格一致 */
    { /* sentinel,数组结尾必须是空项 */ },
};
MODULE_DEVICE_TABLE(of, pl_match);   /* 让模块能被 modprobe 按设备树自动加载 */
```

设备树(DTS)里对应节点写 `compatible = "penguinlab,pl-demo";`。platform 总线的 `match` 拿驱动这张表去和每个 platform_device 的 `of_node->compatible` 比对,字符串对上就算配对成功(然后调你的 probe)。`"<vendor>,<model>"` 这种"厂商前缀,型号"的命名是设备树约定,我们会在 [drv-dts](./11-drv-dts.md) 里展开 binding 文档那套规矩。

### 三、`module_platform_driver`:注册/注销的极简宏

注册一个 platform 驱动,标准做法是 `__platform_driver_register(&drv, THIS_MODULE)`(`platform_device.h:276`)在 module_init 里调、`platform_driver_unregister` 在 exit 里调。但这套样板每个驱动都要写一遍很烦,所以内核提供了 **`module_platform_driver` 宏**(`platform_device.h:294`),它展开就是"init 里 register、exit 里 unregister":

```c
#define module_platform_driver(__platform_driver) \
    module_driver(__platform_driver, platform_driver_register, \
                  platform_driver_unregister)
```

实际写驱动时,定义好 `struct platform_driver` 之后,一行收尾:

```c
module_platform_driver(pl_driver);   /* 等价于 module_init/register + module_exit/unregister */
```

这就替代了手写的 `module_init/module_exit` 两段。注意它假定驱动的 init **只做** `platform_driver_register`——如果 init 里还要干别的(比如注册字符设备的主设备号、申请次要资源),就得退回手写 init/exit。

### 四、`probe` 里干啥:获取资源 + 初始化硬件 + 注册设备

配对成功后,内核调 `pl_probe(struct platform_device *pdev)`。pdev 就是配上的那个 platform_device,所有"这个设备的硬件资源"(内存区、IRQ 号、时钟、DMA 通道)都挂在它身上,probe 里把它们一一取出来用:

```c
static int pl_probe(struct platform_device *pdev)
{
    struct device *dev = &pdev->dev;          /* 通用 device,devm_ 接口要它 */
    void __iomem *base;
    int irq, ret;

    /* 1. 获取并映射寄存器内存区(platform_get_resource + devm_ioremap 的合体) */
    base = devm_platform_ioremap_resource(pdev, 0);
    if (IS_ERR(base)) return PTR_ERR(base);

    /* 2. 获取 IRQ 号(设备树 interrupts 属性解析后的结果) */
    irq = platform_get_irq(pdev, 0);
    if (irq < 0) return irq;

    /* 3. 申请中断(devm_ 版:remove 时自动释放) */
    ret = devm_request_irq(dev, irq, pl_irq, 0, dev_name(dev), dev);
    if (ret) return ret;

    /* 4. 分配私有数据(devm_ 版:remove 自动释放) */
    struct pl_ctx *ctx = devm_kzalloc(dev, sizeof(*ctx), GFP_KERNEL);
    ctx->base = base;  ctx->irq = irq;
    platform_set_drvdata(pdev, ctx);           /* 存起来,remove/其他回调用 pdev 取回 */

    /* 5. 注册到对应子系统(misc_register/cdev_add/alloc_etherdev...) */
    /* ... 比如 devm_misc_register 把它做成 /dev 节点 ... */
    return 0;                                    /* 返回 0 表示 probe 成功,设备-驱动绑定 */
}
```

几个要点:`platform_get_irq`(`:103`)/`platform_get_resource`(`:58`)从 pdev 取硬件资源(这些资源是内核解析设备树后填进 pdev 的);`platform_set_drvdata`/`platform_get_drvdata` 在 pdev 上挂一份私有数据(回调之间共享);probe 的返回值决定配对成功与否,返回非 0 内核就认为这个驱动适配失败、换别的驱动试。注意 probe 里**注册的子系统设备(第 5 步)也要是 devm_ 版或 remove 里手动注销**,否则 remove 时泄漏。

### 五、`devm_`:设备管理资源的"自动释放"魔法

你可能注意到上面 probe 里清一色 `devm_` 前缀——这是 device-managed(设备托管)资源,driver model 的"生命周期托管"机制,platform 驱动的标配。**`devm_kzalloc`/`devm_ioremap_resource`/`devm_request_irq`/`devm_clk_get` 这些函数,申请的资源都和传入的 `struct device *dev` 绑定:当这个 device 被解绑(driver remove 或设备注销)时,内核自动按申请的逆序释放它们**——你不用手写 `kfree`/`iounmap`/`free_irq`/`clk_put` 的清理代码。

这套机制的价值在 probe 失败时最明显:传统写法里,probe 走到第 3 步失败,前两步申请的资源都得手动 goto 清理(`fail_irq:`/`fail_map:` 那套);用 devm_ 的话,直接 `return ret`,内核看你 device 解绑了、自动把前面 devm_ 申请的都回收。代码量少一大截、还不会泄漏。所以现代 platform 驱动 probe 里**几乎全用 devm_**,remove_new 经常只剩"注销第 5 步那个子系统设备"(如果它不是 devm_ 版)。这是 driver model 给驱动作者最大的工程红利之一。

### 六、一个 platform 驱动的完整骨架

把前面几节缝起来,一个 platform 驱动的骨架就这么长(真实驱动主要在 probe 里填充具体硬件初始化):

```c
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of_device.h>

static const struct of_device_id pl_match[] = {
    { .compatible = "penguinlab,pl-demo", },
    { /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, pl_match);

static int pl_probe(struct platform_device *pdev)  { /* 第四节那套 */ return 0; }
static void pl_remove_new(struct platform_device *pdev) { /* 注销子系统设备 */ }

static struct platform_driver pl_driver = {
    .probe      = pl_probe,
    .remove_new = pl_remove_new,             /* 6.x 用 remove_new */
    .driver = {
        .name           = "pl-demo",
        .of_match_table = pl_match,
        .owner          = THIS_MODULE,
    },
};
module_platform_driver(pl_driver);           /* 第三节:注册/注销一键收 */

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PenguinLab");
MODULE_DESCRIPTION("a platform driver skeleton");
```

对应的设备树节点(下一篇 [drv-dts](./11-drv-dts.md) 展开)大致是:

```dts
pl-demo@4000_0000 {
    compatible = "penguinlab,pl-demo";   /* ← 和驱动的 of_match_table 对上 */
    reg = <0x0 0x40000000 0x0 0x1000>;   /* 寄存器区 → platform_get_resource */
    interrupts = <0 32 4>;               /* IRQ → platform_get_irq */
};
```

设备树节点 + 这份驱动骨架,就是"一个 platform 设备 + 它的驱动"的最小可工作组合。内核解析设备树生成 platform_device(填好 reg/interrupts 等资源)、你的驱动 `of_match_table` 配对、probe 取资源初始化、注册成 `/dev` 节点或网络/块设备——整条链在 [drv-model](./00-drv-model.md) 的 match/probe 框架里跑通。

## 动手试试

> example 随亲测补到 `example/mini/`:一个 platform 驱动骨架 + 对应的设备树节点(QEMU virt 机型可加自定义节点)。

1. 在 QEMU 的设备树(或 `qemu-run.sh` 传的 `-append`/dtb)里加一个 `penguinlab,pl-demo` 节点,带 `reg` 和 `interrupts`
2. 写本篇第六节的 platform 驱动骨架,probe 里只做"打印我配上了 + 用 `devm_platform_ioremap_resource` 取 reg + `platform_get_irq` 取 irq 并打印",`module_platform_driver` 注册
3. `insmod` 后 `dmesg` 看 probe 被调(说明 of_match 成功),`ls /sys/bus/platform/drivers/pl-demo/` 看驱动注册上来、且 `module` 软链接正确
4. 故意把 of_match_table 的 compatible 写错(和设备树不一致),重新编译加载——观察 probe **不**被调,体会"match 是配对的前置闸门"
5. 进阶:把 probe 里把 `devm_request_irq` 换成老式 `request_irq`(非 devm_),remove_new 里就必须配 `free_irq`,体会 devm_ 省了什么
6. 思考题:为什么 probe 里强烈推荐用 `devm_` 系列?结合本篇第五节,讲出它在"probe 多步、中途可能失败"场景下省下的麻烦

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/platform_device.h:239 struct platform_driver`、`:240 probe`、`:294 module_platform_driver`、`:50 to_platform_device`(container_of)、`:58 platform_get_resource`、`:103 platform_get_irq`、`:116 platform_get_irq_byname`;`of_match_table` 的 `struct of_device_id` 在 `include/linux/mod_devicetable.h`,`of_match_node` 在 `include/linux/of.h:378`;devm_ 资源管理核心在 `drivers/base/devres.c`、各 `devm_*` 散在对应子系统头文件(`include/linux/slab.h` 的 `devm_kzalloc`、`include/linux/io.h` 的 `devm_ioremap_resource` 等);platform 核心实现 `drivers/base/platform.c`。
- 关联本站:本篇把 [00 driver model](./00-drv-model.md) 的 match/probe 框架落到了 platform 总线上;probe 里申请中断的细节在 [05 硬件中断](./05-drv-irq.md);设备树(compatible/reg/interrupts 的含义与 binding 文档)下一篇 [11 设备树](./11-drv-dts.md) 展开;`container_of`(`to_platform_device` 用的)在 [内核数据结构](../foundations/12-kernel-data-structures.md)。
- 经典纸面参考:LDD3 时代还没有 platform 驱动这套完整框架,LDD3 的字符设备驱动是"直接 file_operations + 手动注册",和现代 platform 驱动的"of_match + probe + devm_"差别很大,结合本篇和 `drivers/base/platform.c` 源码看;`Documentation/driver-api/platform.rst` 是 platform 的官方文档。
