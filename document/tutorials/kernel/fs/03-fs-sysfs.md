---
title: "sysfs:kobject 的影子,把设备/驱动属性暴露成一个个文件"
slug: fs-sysfs
prerequisites:
  - fs-vfs
  - fs-procfs
next:
  - fs-page-cache
difficulty: intermediate
tags: [filesystem, sysfs, kobject, kset, attribute, sysfs_ops, driver-model, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/core-api/kobject.html
  - source: third_party/linux（6.19）include/linux/kobject.h、include/linux/sysfs.h、fs/sysfs/
maturity: drafting
related:
  - /tutorials/kernel/fs/02-fs-procfs
  - /tutorials/foundations/09-kernel-module-params
---

> 🔨 **整理中** · 这一篇讲 sysfs——挂在 `/sys`、基于 kobject 的伪文件系统,是现代内核"暴露设备/驱动属性"的规范渠道。素材以 6.19 源码为权威、kernel.org 的 [kobject 文档](https://docs.kernel.org/core-api/kobject.html) 做框架,本藤无读书笔记、靠现查原料。结构体行号对照 `third_party/linux/`;动手部分(给一个 kobject 加属性文件)在 QEMU 亲手跑过之前标"待亲测"。

## 做什么

上一篇 procfs 末尾我们说了一句"现代内核新代码暴露设备属性,优先走 sysfs 而不是 procfs"。这一篇就拆 sysfs:它和 procfs 一样是伪文件系统(不落盘、现造),但组织方式完全不同——procfs 是"一份份多行文本"的杂物间,sysfs 是**严格结构化的"每个文件一个属性"**:每个文件只代表一个值(或一小段内容),对应内核里某个 kobject 的一项 attribute。

这种严格结构不是洁癖,是有来由的:sysfs 是内核 **driver model**(设备/总线/驱动/类的统一抽象)的"用户态可见面孔"。内核里每个 `kobject`(这个结构体是 driver model 的基类)在 `/sys` 里对应**一个目录**,目录下每个文件对应这个对象的一个**属性(attribute)**。所以你在 `/sys/devices/...`、`/sys/class/...`、`/sys/bus/...` 下看到的那一树目录文件,本质是内核里 kobject 树的镜像。这一篇我们讲清楚三件事:这个"基类" kobject 是什么、attribute 怎么变成 `/sys` 下的文件、以及读写那个文件时内核怎么分派。

## 要了解什么

### 一、sysfs 是什么:kobject 树的镜像

先把 sysfs 和它的挂载方式定位清楚。sysfs 也是个伪文件系统,走 [VFS](./01-fs-vfs.md) 那篇讲的 `get_tree_nodev` 路线挂载到 `/sys`。它最大的特点是:**目录结构不是手动 `proc_mkdir` 一个个建的,而是自动镜像内核里的 kobject 层级**——每创建一个 kobject(把它加进 kset),sysfs 里就自动出现对应的目录;每给一个 kobject 添加一个 attribute,sysfs 里就自动出现对应的文件。换句话说,**sysfs 文件系统的"内容"完全由 kobject 树决定,sysfs 自己几乎不存独立状态**。这也是为什么 sysfs 的源码(`fs/sysfs/`)非常薄——它本质上是个"把 kobject 树翻译成 VFS 目录树"的适配层。

### 二、`kobject` / `kset` / `kobj_type`:driver model 的基类三件套

要懂 sysfs,必须先懂 kobject。**`struct kobject`**(`include/linux/kobject.h:64`)是 driver model 的"基类"——用 C 的面向对象方式,让 `device`、`bus`、`driver`、`kclass` 这些结构体都"内嵌"一个 kobject,从而共享引用计数、父子层级、sysfs 暴露这套公共能力。可以把 kobject 理解成"**能在 sysfs 里出现的对象**的最小公分母":它本身不携带设备语义,只负责"我是个对象、我有父母孩子、我有引用计数、我在 sysfs 有个目录"这些共性。

围绕 kobject 有两个伙伴:**`struct kset`**(`kobject.h:168`)是一组相关 kobject 的集合(它自己也是个 kobject,所以 kset 也能套 kset);**`struct kobj_type`**(`kobject.h:116`)描述"这一类 kobject 的行为",最关键的是它挂着 `sysfs_ops` 和 `default_attrs`(下一节)——决定这个 kobject 在 sysfs 里有哪些默认属性文件、读写它们怎么分派。三者的关系可以这样记:**kobject 是对象,kset 是装对象的篮子,kobj_type 是对象的"类描述"(含 sysfs 行为)**。kobject 的生命周期靠引用计数管理(`kobject_get`/`kobject_put`),归零时通过 kobj_type 的 `release` 方法释放——这是内核"引用计数 + release 回调"模式的典范,和 [chardev](../../drivers/01-drv-chardev.md) 里 cdev 的生命周期是同一种套路。

### 三、`attribute` + `sysfs_ops`:每个文件就是一个属性

现在看 sysfs 文件本身。一个 sysfs 文件,内核里对应的就是一个 **`struct attribute`**(`include/linux/sysfs.h:30`):

```c
struct attribute {
    const char      *name;   /* 文件名 */
    umode_t          mode;   /* 权限(如 0644) */
#ifdef CONFIG_DEBUG_LOCK_ALLOC
    ...
#endif
};
```

它只是"名字 + 权限",非常瘦——具体的读写行为不在这里,而是由**所属 kobject 的 `kobj_type` 指向的 `sysfs_ops`** 统一提供。**`struct sysfs_ops`**(`sysfs.h:392`)只有两个方法:

```c
struct sysfs_ops {
    ssize_t (*show)(struct kobject *kobj, struct attribute *attr, char *buffer);
    ssize_t (*store)(struct kobject *kobj, struct attribute *attr,
                     const char *buffer, size_t size);
};
```

这里有个 sysfs 设计的精髓:**同一个 kobject 的所有 attribute,共用同一组 `show`/`store`**。用户态 `cat /sys/.../某属性`,VFS 分派到这个 kobject 的 `sysfs_ops.show(kobj, attr, buffer)`;`echo ... > /sys/.../某属性`,分派到 `store`。`show`/`store` 拿到的 `attr` 指针告诉它"用户实际操作的是哪个属性",回调内部通常用 `container_of(attr, 具体属性结构体, attr)` 把这个通用指针还原成"带类型/带数据的属性结构",再针对性处理。

> 💡 **为什么所有属性共用一对 show/store**
> 这种"一个 vtable 管一类属性"的设计,是为了让 driver model 里成千上万个属性不必各自带函数指针——它们共享 `kobj_type` 上的一对回调,靠 `container_of` 在回调里区分。对比 procfs"每个文件各自一套 `proc_ops`",sysfs 的粒度是"每个 kobject 一套 ops",更适合"一个设备有一堆属性"的场景。本质还是 [VFS](./01-fs-vfs.md) 那种"用 vtable 分派"的范式,只是分派轴从"文件"挪到了"kobject"。

### 四、`show`/`store`:读写属性的回调

`show(kobj, attr, buffer)` 在用户 `read` 时触发:它要把这个属性的当前值,格式化成字符串写进 `buffer`(注意 buffer 大小有限,一般一页),返回写入的字节数。`store(kobj, attr, buffer, size)` 在用户 `write` 时触发:把用户写进来的 `buffer`(长度 `size`)解析出来、更新内核状态,返回消费的字节数。

因为手写 `show`/`store` 的"解析字符串、校验、转整数"很啰嗦,内核提供了大量 helper 宏让"定义带类型的属性"变简洁——比如 `DEVICE_ATTR_RW(name)` / `DEVICE_ATTR_RO(name)` 会展开成一个带 `show`/`store` 的 `device_attribute` 结构体(它内嵌 `attribute` 加上带类型的 show/store 指针),用 `container_of` 就能把"通用 attr"还原回来。这套宏(还有 `BUS_ATTR`/`DRIVER_ATTR`/`CLASS_ATTR`)是写驱动时定义 sysfs 属性的标配,底层最终都落到 `sysfs_ops` 的分派上。

### 五、创建属性文件:`sysfs_create_file` / `sysfs_create_group`

手动给一个 kobject 添加属性文件,用这组 API(`include/linux/sysfs.h`):

```c
int sysfs_create_file_ns(struct kobject *kobj,
                         const struct attribute *attr, const void *ns);
int sysfs_create_group(struct kobject *kobj,
                       const struct attribute_group *grp);
```

`sysfs_create_file` 给 kobject 加单个属性文件;`sysfs_create_group` 加一组(常用于"一个设备有一堆相关属性,打包成 group")。不过实际写驱动时很少直接调这些——`device_create` 创建设备时,kobj_type 的 `default_attrs`(或更现代的 `default_groups`)会**自动**把一组默认属性文件创建出来,驱动只需用 `DEVICE_ATTR_*` 宏声明它们。手动 `sysfs_create_file` 多见于"运行时动态加属性"的场景。

> ⚠️ **sysfs 属性值的纪律**
> sysfs 有条不成文的约定:**单个属性的值应当是一个、最多几个值,不要把一大段多行文本塞进一个 sysfs 文件**(那是 procfs 的活)。比如一个电池设备的 `capacity` 文件就输出一个百分比数字、`status` 文件输出 `Charging`/`Discharging` 这种单词。遵守这条约定,用户态工具(udev、各种 sysfs 客户端)才能可靠解析。把 procfs 那种"一份大文本"的写法搬进 sysfs,会被内核维护者打回。

### 六、kobject 与 driver model:为什么 sysfs 长成 `/sys/devices`、`/sys/class`、`/sys/bus` 这幅样子

把前几节拼起来,就能看懂 `/sys` 的目录结构为什么是那样。内核的 driver model 里,`device`/`bus`/`driver`/`kclass` 这些结构体都内嵌了 kobject,它们的父子层级(设备挂在哪个 bus 上、属于哪个 class、父设备是谁)就是 kobject 的父子层级——sysfs 自动把这棵 kobject 树镜像成目录树,于是你看到:

- `/sys/devices/**`:按硬件拓扑组织的设备树(设备的"真实"位置,kobject 父子 = 硬件父子)
- `/sys/class/**`:按功能分类(网络设备都在 `net/`、块设备都在 `block/`),这里的目录是"软链接"到 `/sys/devices/` 下真实设备的
- `/sys/bus/**`:按总线组织(usb/pci/platform...),每个 bus 下 `devices/` 和 `drivers/` 两套
- `/sys/module/**`:每个已加载模块一个目录(包括它的 `parameters/` ——还记得 [模块参数](../../foundations/09-kernel-module-params.md) 里 `/sys/module/<mod>/parameters/` 吗?它就是 sysfs 自动给模块 kobject 暴露的属性文件)

所以 sysfs 不是谁手动建的目录,它是内核对象关系的**投影**。这一点想通,你就明白为什么"加一个设备属性 = 在 `/sys/devices/.../` 下多一个文件",以及为什么 sysfs 是"结构化的 procfs"。

### 七、procfs / sysfs / debugfs:三个伪 fs 的分工

最后把三个伪文件系统放一起,记一个分工:

- **procfs(`/proc`)**:进程信息 + 少数传统系统项;新代码不建议往里加。内容形式:多行文本。
- **sysfs(`/sys`)**:基于 driver model 的设备/驱动/总线/类属性;新代码暴露设备状态走这里。内容形式:一个文件一个属性。
- **debugfs(`/sys/kernel/debug`)**:给开发者用的调试接口,最自由(任意格式、任意内容),不承诺 ABI 稳定;[动态调试](../../debugging/10-debug-dynamic-debug.md) 的 control 文件、各种 per-device 调试开关常放这里。

选型原则:面向生产、面向用户态工具的稳定接口 → sysfs;给开发者临时看、格式自由 → debugfs;进程/传统系统信息 → procfs(但别新增)。

## 动手试试

> example 随亲测补到 `example/mini/`:一个创建 kobject + 几个 attribute 的模块。

1. QEMU 启动后先逛 `/sys`:`ls /sys/devices/`、`ls /sys/class/net/`、`ls /sys/module/printk/parameters/`(如果开了) ——直观感受 sysfs 是 kobject 树的镜像
2. 读一个现成属性:`cat /sys/class/net/lo/mtu`(lo 回环的 MTU)、`cat /sys/class/net/lo/operstate`,体会"一个文件一个值"
3. 写一个模块:用 `kobject_create_and_add("penguinlab", kernel_kobj)` 在 `/sys/kernel/penguinlab` 建个目录;用 `sysfs_create_file` 加一个 `attribute`(配一对 `show`/`store`,show 输出一个计数器、store 接收一个整数更新它);`insmod` 后 `cat /sys/kernel/penguinlab/<attr>` 和 `echo 42 > ...` 验证读写
4. 用 `DEVICE_ATTR_RO`/`DEVICE_ATTR_RW` 宏(配合一个简易的 `device` 或 platform device)重新实现上一步,对比"裸 kobject + attribute"和"驱动模型宏"两种写法,体会 `container_of` 还原类型化属性的过程
5. 思考题:对照 procfs 的"每个文件一套 `proc_ops`"和 sysfs 的"每个 kobject 一套 `sysfs_ops` + 多个 attribute",为什么后者更适合"一个设备有一堆属性"的场景?(提示:共享回调 + container_of 区分 vs 每文件独立回调)

## 延伸阅读

- kernel.org:[Everything you never wanted to know about kobjects, ksets, and ktypes](https://docs.kernel.org/core-api/kobject.html) 是 kobject/driver model 的官方权威文档(讲 kobject 生命周期、kset/kobj_type 关系、与 sysfs 的绑定),本篇的核心素材。
- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/kobject.h:64 struct kobject`、`:116 struct kobj_type`、`:168 struct kset`;`include/linux/sysfs.h:30 struct attribute`、`:392 struct sysfs_ops`、以及 `sysfs_create_file_ns`/`sysfs_create_group`;sysfs 文件系统本体在 `fs/sysfs/`(很薄,主要是把 kobject 树适配到 VFS);带类型属性的宏 `DEVICE_ATTR_*`/`BUS_ATTR_*` 等散在 driver model 各头文件。
- 关联本站:本篇承接 [01 VFS 框架](./01-fs-vfs.md) 和 [02 procfs](./02-fs-procfs.md)(sysfs 是第三个伪 fs 应用);kobject 的"引用计数 + release 回调"生命周期与 drivers 藤的 chardev/cdev 同源(见 [drivers/01 chardev](../../drivers/01-drv-chardev.md));`/sys/module/<mod>/parameters/` 的来源在 [模块参数](../../foundations/09-kernel-module-params.md);debugfs 的定位见 [动态调试](../../debugging/10-debug-dynamic-debug.md) 那篇的 control 文件讨论。
- 经典纸面参考:LDD3 第 14 章《设备模型》讲 kobject/kset/sysfs,部分 API(尤其 default_attrs → default_groups 的迁移)在 6.x 有更新,结合源码看。
