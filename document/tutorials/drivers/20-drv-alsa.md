---
title: "ALSA:音频子系统与 PCM 流"
slug: drv-alsa
prerequisites:
  - drv-model
  - drv-dma
next: []
difficulty: advanced
tags: [driver, alsa, pcm, snd_card, audio, dma, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/sound/
  - source: third_party/linux（6.19）include/sound/、sound/
maturity: drafting
related:
  - /tutorials/drivers/00-drv-model
  - /tasks/drivers/17-drv-dma
---

> 🔨 **整理中** · 这一篇讲 **ALSA(Advanced Linux Sound Architecture)**——Linux 音频子系统,管声卡、PCM(数字音频)流、控制(音量/开关)。素材以 6.19 源码 + kernel.org [Sound 文档](https://docs.kernel.org/sound/) 为权威。它和 DMA 关系紧密:PCM 数据流靠 **DMA 循环传输**(`device_prep_dma_cyclic`,见 [17 DMA](./17-drv-dma.md))在内存和音频 codec 间搬。

## 做什么

音频驱动要让"用户态程序(aplay/arecord)写的样本数据"实时流到声卡 codec 的 FIFO、变成模拟声音;反过来录音是 codec 的数据流回用户态。ALSA 子系统(`sound/`)提供这套框架:`snd_card`(声卡)、`snd_pcm`(数字音频流)、`snd_kcontrol`(音量/开关控制)。驱动作者填这些结构 + 回调,用户态通过 alsa-lib(`/dev/snd/*`)访问。这一篇拆 ALSA 驱动的核心:声卡怎么注册、PCM 流怎么用环形 buffer + DMA 周期搬、控制接口怎么暴露音量。

## 要了解什么

### 一、ALSA 框架:`snd_card` + `snd_device`

ALSA 的顶层容器是 **`struct snd_card`**(`include/sound/core.h`)——一张"声卡"的化身,它下面挂一堆 `snd_device`(PCM/控制/MIDI/sequencer 等都算 snd_device)。驱动 `snd_card_new(&pdev->dev, SNDRV_DEFAULT_IDX1, ...)` 分配声卡,接着往里挂 PCM/控制等组件,最后 `snd_card_register` 注册(注册后 `/dev/snd/controlC<N>`/`pcmC<N>D<p/c>` 设备节点出现)。

### 二、PCM 流:`snd_pcm` + `snd_pcm_hardware`

数字音频(PCM = Pulse Code Modulation)是 ALSA 最常用的流。**`struct snd_pcm`** 描述一个 PCM 设备(可能多个 substream,每个是一次播放/录音)。驱动填 **`struct snd_pcm_hardware`** 描述硬件能力:

- `.info`、`.formats`(`SNDRV_PCM_FMTBIT_S16_LE` 等)、`.rates`(支持的采样率)
- `.channels_min/max`、`.buffer_bytes_max`、`.period_bytes_min/max`

以及 **`struct snd_pcm_ops`** 回调:`open`/`close`/`hw_params`(用户态 `snd_pcm_hw_params` 时调,这里分配 buffer/DMA)、`prepare`(每次启动前准备)、`trigger`(开始/停止:`START`/`STOP`)、`pointer`(报告当前 DMA 指针到哪了,给 ALSA 知道进度)。

### 三、环形 buffer + period + DMA 循环

PCM 流的核心是**环形 buffer(ring buffer)** + **period**:

- ALSA 给每次播放分配一个大 `buffer`(几万字节),分成若干 **period**(每个几十~几百微秒的数据)。
- DMA 设成 **cyclic 循环模式**(`device_prep_dma_cyclic`,见 [17 DMA](./17-drv-dma.md))——DMA 搬完一个 period 不停,自动接着搬下一个、循环回开头。
- 每搬完一个 period,DMA 中断触发 → ALSA 驱动 → 上层"哪个 period 空了、可以填新数据"。

这套"DMA 环形搬 + period 中断通知"让用户态只需保证"始终把数据填到环形 buffer 的空段",音频就能连续播放——这是所有音频驱动的核心模型。

### 四、控制接口:`snd_kcontrol`

除了 PCM(数据流),声卡还有**控制**:音量、静音、输入源选择、MIDI 等。这些通过 **`struct snd_kcontrol`**(`include/sound/control.h`)暴露——一个 kcontrol 对应一个"可读可写的控制值"(如 `Master Playback Volume`)。驱动 `snd_ctl_add(card, snd_kcontrol_new(...))` 注册。用户态 `amixer`/alsamixer 看到的音量滑条,就是遍历这些 kcontrol。

### 五、用户态:alsa-lib → PulseAudio/PipeWire

用户态音频程序通过 **alsa-lib**(`libasound`,`snd_pcm_*` API)访问 ALSA:`aplay test.wav`/`arecord`。再上层,现代桌面有 **PulseAudio**(老)或 **PipeWire**(新)做音频服务器,统管多应用音频流、路由、音效,再 sink 到 ALSA。所以"应用 → PulseAudio/PipeWire → alsa-lib → ALSA 驱动 → DMA → codec → 喇叭"是完整音频栈。

## 动手试试

1. `aplay -l`/`arecord -l`(宿主机)列出声卡和 PCM 设备;`cat /proc/asound/cards`
2. `amixer contents` 看所有 kcontrol(音量/开关)
3. 读一个简单 ALSA 驱动(如 `sound/drivers/dummy.c`,虚拟声卡,纯软件无硬件)或 `sound/soc/codecs/` 下某 codec,看 `snd_pcm_ops`/`snd_kcontrol` 怎么填
4. 进阶:`cat /proc/asound/cardN/pcm0p/sub0/hw_params`(播放时)看当前 period_size/buffer_size/格式,对照本篇第三节
5. 思考题:为什么音频用"环形 buffer + period 中断",而不是"一次性搬完整个 buffer"?(提示:实时性 + 无限流)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/sound/core.h`(`snd_card`)、`include/sound/pcm.h`(`snd_pcm`/`snd_pcm_hardware`/`snd_pcm_ops`)、`include/sound/control.h`(`snd_kcontrol`);实现在 `sound/core/`(`sound.c`/`pcm.c`/`control.c`);简单驱动参考 `sound/drivers/dummy.c`、ASoC(嵌入式音频)在 `sound/soc/`。
- kernel.org:[Sound](https://docs.kernel.org/sound/)、`Documentation/sound/` 各专题(alsa-configuration/ALSA-SoC/...)。
- 关联本站:本篇是 [00 driver model](./00-drv-model.md) 的音频子系统类型;PCM 的 DMA 循环传输见 [17 DMA](./17-drv-dma.md);`snd_pcm_ops` 回调表和 [VFS ops](../kernel/fs/01-fs-vfs.md)/[sched_class](../kernel/sched/01-sched-overview.md) 是同一套"vtable 分派"范式。
