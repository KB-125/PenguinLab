---
title: "of_ 接口速查:在内核里遍历设备树、读属性"
slug: drv-of-api
prerequisites:
  - drv-dts
  - drv-platform
difficulty: intermediate
tags: [device-tree, of_api, of_property_read, of_find_node, of_platform, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - source: third_party/linux（6.19）include/linux/of.h、of_address.h、of_irq.h、of_platform.h
maturity: drafting
related:
  - /tutorials/drivers/11-drv-dts
  - /tutorials/drivers/10-drv-platform
---

> 🔨 **整理中** · 这一篇是 **of_ 接口完整速查**——[drv-dts](./11-drv-dts.md) 第四节讲了 of_ 基础几个,这里把内核里设备树操作的全部 of_ API 按类列全(找节点/读属性/地址/IRQ/phandle/platform),给驱动作者当参考。素材来自 6.19 源码头文件。

## 做什么

写设备驱动时,经常要从设备的 device_node 读自定义属性、或遍历设备树找特定节点——这套 API 就是 `include/linux/of.h` 和它的 `of_*.h` 家族(`of_address.h`/`of_irq.h`/`of_platform.h`...)。这篇按"找节点 / 读属性 / 地址 IRQ / phandle 引用 / platform"几类,把常用 of_ 列出来 + 用法 + 行号,作参考手册。

## 要了解什么

### 一、找节点:遍历 device_node 树

`include/linux/of.h`:

| API | 用途 |
|:--|:--|
| `of_find_node_by_name(np, "name")` | 按名字找节点 |
| `of_find_node_by_type(np, "type")` | 按 device_type 找 |
| `of_find_compatible_node(np, type, "vndr,model")` | 按 compatible 找(最常用) |
| `of_find_node_with_property(np, "prop")` | 找含某属性的节点 |
| `of_find_all_nodes(NULL)` | 遍历所有节点 |
| `of_get_parent(np)` / `of_get_next_child(parent, prev)` / `of_get_next_available_child` | 父/子遍历 |
| `of_get_next_parent(np)` | 父(不解引用计数) |
| `for_each_child_of_node(parent, child)` / `for_each_available_child_of_node` | 遍历子节点(宏) |
| `of_node_get(np)` / `of_node_put(np)` | 引用计数(用完要 put) |

### 二、读属性:`of_get_property` / `of_property_read_*`

| API | 用途 |
|:--|:--|
| `of_get_property(np, "name", &lenp)` | 原始读(返回 void*,自己解释) |
| `of_property_read_u32(np, "name", &val)` / `_u64` | 读单个整数 |
| `of_property_read_u32_array(np, name, arr, n)` / `_u64_array` | 读整数数组 |
| `of_property_read_string(np, "name", &str)` | 读字符串 |
| `of_property_read_string_array(np, name, arr, n)` | 读字符串数组 |
| `of_property_read_bool(np, "name")` | 读布尔(属性存在=真) |
| `of_property_count_*_elems(np, name)` | 数组元素数 |
| `of_property_read_variable_*_array(np, name, arr, min, max)` | 变长数组 |

`of_property_read_*` 返回 `-EINVAL`(属性不存在)/`-ENODATA`(空)/`-EOVERFLOW`(类型不匹配),驱动按返回值处理。

### 三、地址 & IRQ:`of_address.h` / `of_irq.h`

| API | 用途 |
|:--|:--|
| `of_address_to_resource(np, idx, &res)`(`of_address.h:63`) | reg 属性 → resource |
| `of_iomap(np, idx)`(`:65`) | reg → ioremap 一步到位 |
| `of_io_request_and_map(np, idx, name)` | reg → request + iomap |
| `of_irq_get(np, idx)`(`of_irq.h:45`) | interrupts → IRQ 号 |
| `of_irq_count(np)` | interrupts 个数 |
| `of_irq_to_resource(np, idx, &res)` | interrupts → resource |
| `of_irq_parse_one(np, idx, &oirq, ...)` | 底层解析(一般不直接用) |

注意:platform 驱动 probe 里通常不直接调这些——内核解析设备树生成 platform_device 时,已把 reg 翻译进 `pdev->resources`、interrupts 翻译成可 `platform_get_irq` 取的 IRQ。`of_*` 多用于"读自定义属性"、或非 platform 的设备树节点处理。

### 四、phandle 引用:`of_parse_phandle` 等

设备树里 `clocks = <&clk_mmcm 0>;` 这种引用别的节点(phandle):

- `of_parse_phandle(np, "clocks", 0)`:取引用的目标 `device_node *`。
- `of_parse_phandle_with_args(np, "clocks", "#clock-cells", 0, &args)`:取目标 + 解析它的 cells 参数(到 `struct of_phandle_args`)。
- `of_parse_phandle_with_fixed_args`:固定 cells 数。

用完返回的 `device_node *` 要 `of_node_put`。

### 五、platform:设备树 → platform_device

`include/linux/of_platform.h`:

- `of_platform_populate(root, matches, parent, pdev)`:遍历 root 子树,给匹配的节点生成 platform_device 注册——启动时 `of_platform_default_populate_init` 自动调它。
- `of_platform_device_create(np, bus_id, parent)`:手动给某节点建 platform_device。
- `of_find_device_by_node(np)`:从 device_node 反查已生成的 platform_device。

这套是"设备树节点变成 driver model 设备实例"的桥(关联 [drv-model](./00-drv-model.md)/[drv-platform](./10-drv-platform.md))。

## 动手试试

1. `grep -rn 'of_find_compatible_node\|of_property_read_u32' drivers/` 看真实驱动怎么用
2. 写个模块:`of_find_compatible_node(NULL, NULL, "penguinlab,pl-demo")` 找你的节点,逐个 `of_property_read_*` 读它的属性、打印
3. 用 `of_get_next_child`/`for_each_child_of_node` 遍历某节点的子节点
4. 读 `include/linux/of.h`/`of_address.h`/`of_irq.h` 看 of_ API 全清单(每个都有详细 doc 注释)
5. 思考题:为什么 platform 驱动 probe 里很少直接用 of_iomap/of_irq_get?(提示:内核已把 reg/interrupts 翻进 platform_device resources)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/of.h`(找节点 + 读属性 of_property_read_* 全家)、`of_address.h`(`of_address_to_resource :63`/`of_iomap :65`)、`of_irq.h`(`of_irq_get :45`)、`of_platform.h`(`of_platform_populate`);实现 `drivers/of/`(`base.c`/`property.c`/`platform.c`/`irq.c`/`address.c`)。
- 关联本站:本篇是 [11 drv-dts](./11-drv-dts.md) 第四节 of_ 的完整展开;[10 drv-platform](./10-drv-platform.md) 的 `devm_platform_ioremap_resource`/`platform_get_irq` 内部就是 of_;[00 drv-model](./00-drv-model.md) 的"设备树 → platform_device"靠 `of_platform_populate`。
