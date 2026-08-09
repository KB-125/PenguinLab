---
title: "设备树:把硬件描述从代码里解放出来"
slug: drv-dts
prerequisites:
  - drv-platform
  - drv-model
next:
  - drv-threaded-irq
difficulty: intermediate
tags: [device-tree, dts, dtb, of_api, binding, compatible, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/devicetree/overview.html
  - source: third_party/linux（6.19）drivers/of/、include/linux/of*.h、Documentation/devicetree/
maturity: drafting
related:
  - /tutorials/drivers/10-drv-platform
  - /tutorials/drivers/00-drv-model
---

> 🔨 **整理中** · 这一篇讲**设备树(Device Tree, DT)**——ARM/嵌入式世界描述硬件的事实标准。[drv-platform](./10-drv-platform.md) 里我们说"设备的 reg/interrupts 来自设备树",这一篇就拆开讲:设备树是什么、`compatible` 怎么当设备-驱动的配对钥匙、binding 文档是什么契约、内核里 `of_*` 这套 API 怎么读设备树属性。素材以 6.19 源码 + kernel.org [DT 文档](https://docs.kernel.org/devicetree/overview.html) 为权威。动手部分在 QEMU 亲手验过之前标"待亲测"。

## 做什么

x86 世界里,PCI/USB 设备能被总线**枚举**出来——硬件自己会报告"我是谁、我的资源在哪",内核问一遍就知道。可 ARM/嵌入式 SoC 上,那些集成外设(UART/I2C/GPIO/定时器)挂在 SoC 内部总线上,**没有自我描述能力**——内核没法"问"出来它有什么。那内核怎么知道这块板子上有哪些外设、各自的寄存器地址和中断号?

答案就是**设备树**:一块文本(编译成二进制)描述这整块板子的硬件拓扑——有哪些设备、每个设备的 `compatible`(型号)、`reg`(寄存器区)、`interrupts`(中断)、时钟、电源域、和谁连着。引导加载器(UEFI/U-Boot)把这棵 DTB 传给内核,内核启动时解析它、为每个节点生成对应的 `platform_device`(等设备-驱动配对)。这样**硬件描述就和驱动代码解耦了**——同一份驱动,只要设备树里给它配不同的节点,就能跑在不同的板子上;换板子只改设备树、不改驱动代码。这就是设备树存在的根本理由。

## 要了解什么

### 一、设备树是什么:DTS 源 + DTB 二进制 + 运行时 device_node

设备树有三个形态。**DTS**(Device Tree Source)是人写的文本源码,`.dts`/`.dtsi`(后者是可 include 的片段),语法长这样:

```dts
/* 一棵树:根节点 / 下挂子节点 */
/ {
    model = "PenguinLab QEMU virt";
    compatible = "penguinlab,virt";

    pl-demo@40000000 {
        compatible = "penguinlab,pl-demo";   /* ← 设备-驱动配对的钥匙 */
        reg = <0x0 0x40000000 0x0 0x1000>;   /* 地址 + 长度:寄存器区 */
        interrupts = <0 32 4>;               /* 中断:中断类型/号/触发方式(架构相关) */
        clocks = <&clk_mmcm 0>;              /* 引用别的节点(phandle) */
        status = "okay";                      /* okay/disabled 控制是否启用 */
    };
};
```

**DTB**(Device Tree Blob)是 DTC(设备树编译器)把 DTS 编译出的紧凑二进制,引导加载器把它和内核镜像一起加载、传给内核。**运行时**,内核把 DTB 解析成内存里的 `struct device_node` 树(每个节点一个),挂在 `of_root` 下;驱动通过 `of_*` API 查询这棵树。所以设备树从"文本描述"到"驱动能用",经历 `DTS → DTB → device_node` 三态。

### 二、`compatible`:设备-驱动配对的钥匙

[drv-platform](./10-drv-platform.md) 讲过 platform 总线靠 `of_match_table` 配对——驱动的 `of_device_id.compatible` 和设备树节点的 `compatible` 字符串严格比对。所以 `compatible` 是设备-驱动配对的**唯一钥匙**,命名约定是 `"<vendor>,<model>"`(如 `penguinlab,pl-demo`、`arm,pl011`、`ti,am335x-i2c`)。

`compatible` 可以写多个值(从特殊到一般),如 `compatible = "penguinlab,pl-demo-v2", "penguinlab,pl-demo";`——驱动只 match 后一个通用串也能配对,这样"v2 是 v1 的兼容升级"的新硬件能复用老驱动。`of_device_is_compatible`(`include/linux/of.h:359`)就是这个比对的底层函数。

### 三、binding 文档:`compatible` 的"契约"

每个 `compatible` 字符串都对应一份 **binding 文档**(在 `Documentation/devicetree/bindings/`),它规定"这个 compatible 的节点**必须/可以**有哪些属性、属性什么格式"。比如一个 UART 控制器的 binding 会说:必须有 `compatible`/`reg`/`interrupts`,可以有时钟/电源域。binding 是 `compatible` 字符串的"接口契约"——设备树写的人和写驱动的人靠它对齐。

6.x 起 binding 文档大规模转成了 **DT schema**(YAML 格式,`Documentation/devicetree/bindings/**/*.yaml`),能被工具(`make dt_binding_check`)自动校验"这份设备树是否符合这个 binding",比纯文本描述更严格。写新驱动时,配套要加一份 binding schema,这是合入主线的要求。

### 四、`of_*` API:内核怎么读设备树属性

驱动在 probe 里拿到的 `pdev->dev.of_node` 就是指向这个设备的 `device_node`,靠 `of_*` API 读它的属性。最常用的几个(`include/linux/of.h`/`of_address.h`/`of_irq.h`):

```c
/* 读属性(各种类型有对应 read 函数) */
u32 val;
of_property_read_u32(np, "my-prop", &val);          /* 读 32 位整数 */
const char *name = of_get_property(np, "label", NULL); /* 读字符串 */

/* 把 reg 属性翻译成 resource(给 platform_get_resource 用) */
of_address_to_resource(np, 0, &res);                 /* of_address.h:63 */

/* 直接映射寄存器区(reg → ioremap 一步到位) */
void __iomem *base = of_iomap(np, 0);                /* of_address.h:65 */

/* 解析 interrupts 属性拿 IRQ 号 */
int irq = of_irq_get(np, 0);                         /* of_irq.h:45 */
```

不过实际上,platform 驱动 probe 里很少直接调这些底层 `of_*`——内核解析设备树生成 platform_device 时,已经把 `reg` 翻译进了 `pdev` 的 resources、把 `interrupts` 翻译成了可 `platform_get_irq` 取的 IRQ 号。所以你写 platform 驱动,多数时候用 [drv-platform](./10-drv-platform.md) 讲的 `devm_platform_ioremap_resource`/`platform_get_irq` 就够了,它们内部替你调了 `of_*`。`of_*` API 更多用在"需要读自定义属性"(比如一个 `default-brightness-level` 配置值)的场景。

### 五、设备树 → platform_device:启动时的解析

内核启动早期(`of_platform_default_populate_init`),会遍历整棵 device_node 树,把符合条件的节点(有 `compatible` 且 `status != "disabled"`)变成 `platform_device` 注册到 platform 总线——这一步就是把"设备树描述"翻译成"driver model 里的设备实例"。之后发生的事就是 [drv-model](./00-drv-model.md) 那套:platform 总线的 match 拿驱动的 `of_match_table` 去配、配对成功调 probe。所以设备树是站在 driver model **上游**的——它负责"硬件有什么",driver model 负责"硬件用什么驱动"。

## 动手试试

> example 需要给 QEMU 的设备树加自定义节点。QEMU virt 机型可用 `-machine virt,dumpdtb=virt.dtb` 导出 dtb、反编译改后 `-machine virt,dtb=...` 传回;或用 `dtc` 工具链。

1. 用 `dtc -I dtb -O dts` 反编译 QEMU virt 的设备树,看它的结构(`/soc` 节点下挂的 UART/I2C/GIC...),体会"一棵树描述整块板子"
2. 在设备树里加一个 `penguinlab,pl-demo` 节点(带 `compatible`/`reg`/`interrupts`),传给 QEMU
3. 写 platform 驱动(`of_match_table` 配 `"penguinlab,pl-demo"`),probe 里 `devm_platform_ioremap_resource` + `platform_get_irq` 打印拿到的 reg/irq,验证设备树节点被解析成了 platform_device 并配对成功
4. 给节点加一个自定义属性(如 `my-value = <42>;`),probe 里用 `of_property_read_u32(dev->of_node, "my-value", &v)` 读出来,体会"自定义配置走 of_*"
5. 把节点 `status` 改成 `"disabled"`,重新启动,观察 probe 不再被调(说明 disabled 节点没生成 platform_device)
6. 思考题:为什么 ARM 世界用设备树、x86 世界不用?(提示:PCI/USB 可枚举 vs SoC 内部外设不可枚举)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/of.h`(`of_property_read_u32_index :325`/`of_device_is_compatible :359`)、`include/linux/of_address.h`(`of_address_to_resource :63`/`of_iomap :65`)、`include/linux/of_irq.h`(`of_irq_get :45`/`of_irq_parse_one :42`);设备树解析核心在 `drivers/of/`(`device_node`/`of_platform_populate`/`unflatten_dt` 等);binding 文档与 schema 在 `Documentation/devicetree/bindings/`。
- kernel.org:[Device Tree Overview](https://docs.kernel.org/devicetree/overview.html)、[Usage Model](https://docs.kernel.org/devicetree/usage-model.html)、bindings 的子目录里有各子系统的 binding 规范。
- 关联本站:本篇是 [10 platform 驱动](./10-drv-platform.md) 的上游("硬件有什么→platform_device→驱动配对");driver model 的 match/probe 在 [00 drv-model](./00-drv-model.md);中断号从设备树 `interrupts` 来、驱动用它 `request_irq`,深入在 [05 硬件中断](./05-drv-irq.md)。
- 工具:`dtc`(Device Tree Compiler)把 DTS 编译成 DTB、或反编译;`make dt_binding_check` 校验 binding schema;QEMU 的 `-machine virt,dumpdtb=`/`dtb=` 选项。
