---
title: "DRM/KMS:现代显示与图形子系统"
slug: drv-drm
prerequisites:
  - drv-model
next:
  - drv-alsa
difficulty: advanced
tags: [driver, drm, kms, gpu, display, gem, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/gpu/
  - source: third_party/linux（6.19）include/drm/、drivers/gpu/drm/
maturity: drafting
related:
  - /tutorials/drivers/00-drv-model
---

> 🔨 **整理中** · 这一篇讲 **DRM/KMS**——Linux 现代显示/图形子系统,取代老的 fbdev。素材以 6.19 源码 + kernel.org [GPU 文档](https://docs.kernel.org/gpu/) 为权威。它分两半:**DRM**(Direct Rendering Manager,管 GPU/显存/渲染)和 **KMS**(Kernel Mode Setting,管显示管线:谁输出到屏幕、什么分辨率)。现代桌面(Wayland/X)和移动显示都基于它。

## 做什么

老内核显示用 fbdev(framebuffer)——简单但功能弱、不支持多屏/3D 加速/原子模式设置。现代内核用 **DRM/KMS**:`DRM` 管图形渲染侧(GPU 命令、显存对象 GEM),`KMS` 管显示管线(把 framebuffer 送到屏幕)。一个完整 DRM 驱动既实现 DRM(让用户态能提交 GPU 命令、分配显存)又实现 KMS(配置显示管线)。这一篇讲清这套框架的核心概念——不深入 GPU 驱动(那是巨大话题),只让你看懂"DRM 是什么、KMS 对象管线长什么样、用户态怎么用它"。

## 要了解什么

### 一、DRM:渲染侧

DRM 给用户态提供:提交 GPU 命令的接口(`DRM_IOCTL_MODE_*`/厂商自定义 ioctl)、显存管理(**GEM**——Graphics Execution Manager,`drm_gem_object`,显存对象的抽象)、多进程共享 GPU 的同步。每个 GPU 内核里一个 `drm_device`,驱动用 **`struct drm_driver`**(`include/drm/drm_drv.h`)描述——`open`/`postclose`/`ioctls`/`fops` 等。注册:`drm_dev_alloc` + `drm_dev_register`。

用户态(Mesa/Wayland)通过打开 `/dev/dri/cardN`、用 DRM ioctl 提交渲染命令、用 GEM 分配显存、mmap 它到用户空间。现代图形栈(OpenGL/Vulkan 经 Mesa → DRM)全跑在这套之上。

### 二、KMS:显示管线(显示侧)

KMS 描述"显示管线"——像素数据怎么从内存走到屏幕。核心是五类**对象**串成的链:

- **framebuffer**(`drm_framebuffer`):一块内存里的图像(用户态渲染的结果)。
- **plane**(`drm_plane`):从 framebuffer 取一块(可能缩放/格式转换),喂给 CRTC。primary plane 是主图层,cursor plane 是鼠标,overlay plane 是视频。
- **CRTC**(`drm_crtc`):把 plane 的数据按时序扫出来,可多 plane 叠加。
- **encoder**(`drm_encoder`):把 CRTC 扫出的信号编码成 TMDS/DSI/LVDS 等物理格式。
- **connector**(`drm_connector`):物理接口(HDMI/DP/DSI/eDP/DSI-bridge),它接屏幕、读 EDID(屏幕能支持什么分辨率)。

链路:`framebuffer → plane → CRTC → encoder → connector → 屏幕`。KMS 驱动按 SoC 的显示控制器能力创建这些对象、填它们的回调。用户态通过 KMS ioctl 设置"用哪个 framebuffer、什么分辨率、什么 connector 输出"——这套**原子模式设置(atomic mode set)** 是 KMS 的核心接口,一次性原子地配置整条管线(避免中间状态闪屏)。

### 三、fbdev 兼容层

为兼容老的 fbdev 用户态(控制台 console、老的 framebuffer 程序),DRM 提供 **fbdev 兼容层**——`drm_fbdev_generic_setup`,它基于 DRM/KMS 模拟出一个 fbdev 设备,让 console 和老程序在 DRM 之上仍能用。新代码应直接用 DRM/KMS,fbdev 只是兼容。

### 四、用户态:DRI/GBM/Wayland

用户态访问 DRM 通过 libdrm(DRM ioctl 的封装)。更高层:Mesa(OpenGL/Vulkan 实现)用 DRM 渲染;Wayland 合成器用 KMS 设置显示 + GBM(Buffer Manager,基于 GEM)管理 buffer;X 用 DRI 类似。这套 DRM/KMS + libdrm + Mesa + Wayland 是现代 Linux 桌面图形的完整栈,内核侧的入口就是这篇讲的 DRM 驱动。

## 动手试试

1. 宿主机上 `ls /dev/dri/`(`cardN`/`renderN`);`modetest`(libdrm 工具)看 KMS 对象、可用模式、connector 信息
2. `cat /sys/class/drm/card*/device/uevent` 看 DRM 设备
3. 读一个简单 DRM 驱动(如 `drivers/gpu/drm/tiny/simpledrm.c`,纯软件 framebuffer 转 DRM 的简单驱动)看 `drm_driver`/KMS 对象怎么填
4. 进阶:QEMU virtio-gpu(`-device virtio-gpu`)提供 DRM 设备,Guest 里跑图形栈测试
5. 思考题:为什么 KMS 要用"atomic mode set"(一次性原子配置整条管线),而不是分步设每个对象?(提示:中间状态闪屏)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/drm/`(`drm_drv.h` 的 `drm_driver`、`drm_crtc.h` 的 KMS 对象、`drm_gem.h` 的 GEM);实现在 `drivers/gpu/drm/`(`drm_drv.c`/`drm_mode_config.c`/`drm_atomic.c`);简单驱动参考 `drivers/gpu/drm/tiny/simpledrm.c`,真实 SoC 騈动在各厂商目录(`msm/`/`meson/`/`imx/`...)。
- kernel.org:[GPU Driver Developer's Guide](https://docs.kernel.org/gpu/introduction.html)、`Documentation/gpu/` 各专题。
- 关联本站:本篇是 [00 driver model](./00-drv-model.md) 的显示子系统类型;DRM 也是 character device + ioctl(关联 [01 chardev](./01-drv-chardev.md)/[02 ioctl](./02-drv-ioctl.md));显存 GEM 对象的生命周期用 [内核数据结构](../foundations/12-kernel-data-structures.md) 的引用计数套路。
