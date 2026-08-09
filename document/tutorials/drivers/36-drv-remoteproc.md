---
title: "remoteproc / rpmsg:异构多核——A7 跑 Linux,M4/DSP 跑 RTOS"
slug: drv-remoteproc
prerequisites:
  - drv-platform
  - virt-overview
  - drv-dma
difficulty: advanced
tags: [driver, remoteproc, rpmsg, heterogeneous, m4, dsp, virtio, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/staging/remoteproc.html
  - source: third_party/linux（6.19）include/linux/remoteproc.h、include/linux/rpmsg.h、drivers/remoteproc/、drivers/rpmsg/
maturity: drafting
related:
  - /tutorials/drivers/10-drv-platform
  - /tutorials/virtualization/01-virt-overview
---

> 🔨 **整理中** · 这一篇深入讲 **remoteproc + rpmsg**——异构多核 SoC(i.MX 8M 的 A53 + M4、TI AM62 的 A53 + R5F/M4、Xilinx Zynq 的 A53 + R5)上,"主核 Linux 怎么管理 + 通信"协处理器(M4/DSP/R5)的子系统。素材以 6.19 源码 + kernel.org [remoteproc](https://docs.kernel.org/staging/remoteproc.html)/[rpmsg](https://docs.kernel.org/staging/rpmsg.html) 文档为权威。

## 做什么

现代嵌入式 SoC 常是**异构多核**:几个 A 类核(ARM Cortex-A)跑 Linux(用户态 + 网络栈 + UI),外加几个 M 类核(Cortex-M)/R5/DSP 跑**实时/专用任务**——M4 跑电机控制(硬实时)、R5 跑功能安全、DSP 跑音频/视频编解码、NPU 跑神经网络。Linux 在 A 核上跑,但要能**启动/停止/加载固件**到协处理器、并和协处理器**双向通信**(发命令、收数据)。这套就是 **remoteproc**(管协处理器生命周期)+ **rpmsg**(核间消息)两个子系统干的。这一篇拆 remoteproc 的 rproc + rproc_ops、固件加载流程、rpmsg 的基于 virtio 的消息模型。

## 要了解什么

### 一、异构多核场景:为什么需要 remoteproc

A 核跑 Linux、M4 跑 RTOS(或裸程序),两者**独立运行、共享 SoC 外设**。Linux 侧需要:

1. **加载 M4 固件**:把编译好的 M4 固件(`.elf`)从 Linux 文件系统搬到 M4 的执行内存(Tightly Coupled Memory / 共享 DDR 某段)。
2. **启动/停止 M4**:让 M4 从入口地址开始跑(时钟/复位/向量表),需要时停。
3. **核间通信**:A 发命令给 M4("读这个传感器")、M4 回结果,可靠双向。
4. **资源协调**:共享内存(谁用哪段)、共享外设(谁占 I2C0)、共享中断。

**remoteproc**(`drivers/remoteproc/`)管 1+2+4(生命周期 + 资源),**rpmsg**(`drivers/rpmsg/`)管 3(通信)。

### 二、remoteproc:`rproc` + `rproc_ops`

**`struct rproc`**:一个远程处理器的化身,含 `name`/`firmware`(固件文件名)/`ops`/`state`(OFFLINE/DETACHED/RUNNING/...)/已加载的 `carveouts`(共享内存段)等。生命周期 API:`rproc_boot(rproc)`(启动,加载固件 + 跑)/`rproc_shutdown`(停)/`rproc_attach`(attach 到已跑的远程核,如 boot ROM 启动的)。

**`struct rproc_ops`**:SoC 特定的回调:

- `load(rproc, fw)`:把固件 ELF 的各段拷到目标内存(TCM/DDR)。
- `start(rproc)`/`stop(rproc)`:启动/停止远程核(时钟/复位/向量)。
- `attach`/`detach`:attach 到已跑的。
- `da_to_va`:设备地址(DA,M4 视角的地址)→ Linux 虚拟地址(VA)翻译(用于共享内存访问)。
- `get_loaded_rsc_table`:已 attach 场景读远程核的资源表。

SoC 厂商写 remoteproc 驱动(`drivers/remoteproc/imx_rproc.c`/`ti_k3_r5_remoteproc.c`/`qcom_q6v5_pas.c`...)填这套 ops,注册成 `rproc`。用户态 `/sys/class/remoteproc/remoteprocN/{firmware,state,recover}` 操作。

### 三、固件加载 + resource table

`rproc_boot` 流程:

1. `request_firmware` 从 `/lib/firmware/<name>` 加载 ELF 固件。
2. `load` 解析 ELF、把段拷到 M4 内存(DA 翻 VA)。
3. 找固件里的 **resource table**(M4 固件里一段特殊 section `.resource_table`,声明"M4 要哪些资源":carveout 共享内存段、vdev(虚拟设备,给 rpmsg)、通知 ID)。
4. 注册资源(carveout 分配、vdev 注册)。
5. `start` 启动 M4。

resource table 是 A 和 M4 的"契约"——M4 编译时声明"我要这些资源",A 启动时按表配。

### 四、rpmsg:基于 virtio 的核间消息

通信靠 **rpmsg**(Remote Processor Message),它复用 [virtio](../virtualization/03-virt-qemu-kvm.md) 机制(双核间用共享内存 + virtqueue 做消息队列):

- **`struct rpmsg_device`**(`include/linux/rpmsg.h:53`):一个 rpmsg 端点设备(主从核间的一个通信信道)。
- **`struct rpmsg_driver`**:rpmsg 驱动(类似 platform/i2c 的 `probe`/`remove` + `id_table`,匹配靠 service name 字符串如 `"rpmsg-raw"`)。
- **`struct rpmsg_endpoint`**:一个端点(有 4-bit src/32-bit dst 地址),`rpmsg_send(ept, buf, len)` 发、收到时回调 `ept->cb`。

典型用法:

```c
/* rpmsg 驱动,匹配 service "my-channel" */
static const struct rpmsg_device_id my_id[] = { { .name = "my-channel" }, {} };
static struct rpmsg_driver my_drv = {
    .probe  = my_probe, .remove = my_remove,
    .callback = my_rx_cb,         /* 收到消息时调 */
    .id_table = my_id,
    .driver = { .name = "my-rpmsg", },
};

/* 发消息 */
rpmsg_send(to_ept, &cmd, sizeof(cmd));
/* M4 那边收到 → 处理 → rpmsg_send 回 → my_rx_cb 被调 */
```

rpmsg 在 A 侧看起来就是个字符设备/平台,`/dev/rpmsg<N>`(由 rpmsg_chr/rpmsg_ns 暴露),用户态也能 `read`/`write`。

### 五、用途 + 典型场景

- **i.MX RPMsg**:i.MX 8M A53 + M4,典型"Linux UI + M4 实时控制"组合。M4 固件跑裸程序/RT-Thread/MicroPython,A 用 rpmsg 发命令、收传感器/控制数据。NXP 的 `imx_rproc.c` + `imx-rpmsg`。
- **TI K3 R5F**(AM62/A Sitara):A53 + R5F(功能安全/低延迟控制),`ti_k3_r5_remoteproc.c`。
- **DSP**(C66/C71):A53 + DSP(音频/视觉算法),`ti_k3_dsp_remoteproc.c`。
- **NPU/GPU 协处理器**:某些 SoC 用 remoteproc 管加速器固件。

### 六、踩坑

- **地址翻译(DA vs VA)**:M4 视角的地址(DA,如 TCM 的 `0x00000000`、DDR 的 `0x8000_0000`)和 Linux 视角的虚拟地址(VA)不同。`rproc_ops.da_to_va` 必须正确翻译,否则 A 访问 M4 内存出错。ioremapping 共享 DDR 时尤其注意。
- **resource table 不匹配**:M4 固件没声明 resource table,或声明了 A 给不了的资源(carveout 太大、地址冲突),`rproc_boot` 失败。固件和 SoC 配置要对齐。
- **M4 的中断到 A**:M4 通过触发某个 SoC 中断/邮箱(mailbox)通知 A "有消息",mailbox 子系统(`drivers/mailbox/`)是 rpmsg 的底层通知机制。mailbox 没配好,rpmsg 收发不工作。
- **M4 固件崩溃恢复**:M4 跑挂了,A 侧 `rproc` 检测到(看门狗/无响应)→ `/sys/class/remoteproc/.../recover` 触发重启 M4。

## 动手试试

1. `ls /sys/class/remoteproc/`(若有真板);`cat .../remoteproc0/{firmware,state}`;`echo stop > state`/`echo <fw>.elf > firmware && echo start > state`(真板,重启 M4)
2. QEMU 对 remoteproc 支持有限(虚拟 SoC),主要在真板(i.MX/TI/Xilinx)实验
3. 读 `drivers/remoteproc/imx_rproc.c`(i.MX)或 `ti_k3_r5_remoteproc.c`(TI)看 `rproc_ops`(`load`/`start`/`da_to_va`)怎么填
4. 读 `drivers/rpmsg/virtio_rpmsg_bus.c`(rpmsg 基于 virtio 的核心)看 `rpmsg_device`/`rpmsg_send` 实现
5. 思考题:为什么 rpmsg 复用 virtio(virtqueue),而不是自己发明消息格式?(提示:virtio 已成熟、零拷贝、共享内存高效)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/remoteproc.h`(`struct rproc`/`struct rproc_ops`/`rproc_boot`/`rproc_put`/`rproc_add_subdev`);`include/linux/rpmsg.h:53 struct rpmsg_device`、`struct rpmsg_driver`、`struct rpmsg_endpoint`/`rpmsg_send`/`rpmsg_sendto`;remoteproc core `drivers/remoteproc/remoteproc_core.c`;rpmsg core `drivers/rpmsg/virtio_rpmsg_bus.c`/`rpmsg_core.c`;SoC 驱动 `drivers/remoteproc/imx_rproc.c`/`ti_k3_*.c`/`qcom_q6v5_pas.c`;mailbox(通知底层)`drivers/mailbox/`。
- kernel.org:[remoteproc](https://docs.kernel.org/staging/remoteproc.html)、[rpmsg](https://docs.kernel.org/staging/rpmsg.html)、`Documentation/devicetree/bindings/remoteproc/`/`bindings/rpmsg/`。
- 关联本站:[00 driver model](./00-drv-model.md) rproc/rpmsg 都接 driver model、[virt-overview](../virtualization/01-virt-overview.md) rpmsg 复用 virtio、[17 dma](./17-drv-dma.md) 共享内存 DMA;OpenAMP 开放标准是这套的上层规范。
