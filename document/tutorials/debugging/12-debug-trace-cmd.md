---
title: "trace-cmd:ftrace 的命令行封装与 KernelShark"
slug: debug-trace-cmd
prerequisites:
  - debug-ftrace
difficulty: intermediate
tags: [debugging, trace-cmd, ftrace, kernelshark, arm64]
architectures: [arm64, x86_64]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/trace/ftrace.html
  - source: trace-cmd(用户态工具)、kernelshark(GUI)
maturity: drafting
related:
  - /tutorials/debugging/06-debug-ftrace
---

> 🔨 **整理中** · 这一篇讲 **trace-cmd**——[ftrace](./06-debug-ftrace.md) 的命令行封装,把"echo 到 tracefs 各文件"那套操作包成易用的 `trace-cmd` 命令,还能把 trace 存成 `trace.dat` 离线分析、用 KernelShark GUI 可视化。它是 [debug-bug-classification](./00-debug-bug-classification.md) 矩阵里"生产/运行时追踪 → Ftrace/trace-cmd"那一格的工具展开。

## 做什么

[06 ftrace](./06-debug-ftrace.md) 讲了内核 ftrace 框架——它的接口是"向 `tracefs` 的各文件 echo"(echo 要追踪的函数到 set_ftrace_filter、echo 1 到 tracing_on、cat trace 看结果),原始但繁琐。**trace-cmd** 把这套包成命令行工具,常用操作一行搞定:`trace-cmd record -p function_graph -l my_func` 一条命令完成"设 tracer + filter + 录制 + 停",录完存成 `trace.dat` 二进制文件。还能跨机器——你在板子上 `trace-cmd record`、把 `trace.dat` 拷到桌面、`trace-cmd report` 或 KernelShark 打开分析。这一篇就是 trace-cmd 的速查。

## 要了解什么

### 一、核心命令:`record`/`report`/`extract`/`start`/`stop`

- **`trace-cmd record [options] <command>`**:录——设 tracer/event/filter,跑 command(或不带 command 持续录到 Ctrl+C),把数据存进 `trace.dat`。常用 `-p function_graph`(函数调用图)/`-p function`/`-p wakeup`(唤醒延迟)/`-e <event>`(tracepoint)/`-l <func>`/`-g <func>`(过滤)。
- **`trace-cmd report trace.dat`**:把 `trace.dat` 翻译成人读的事件列表。
- **`trace-cmd extract`**:把当前内核 trace buffer 的内容存成 `trace.dat`(录制已发生的事后提取)。
- **`trace-cmd start`/`stop`/`reset`**:对应 ftrace 的 tracing_on 1/0 + 清空,适合脚本控制。

trace-cmd 的 `-p`(plugin/tracer)对应 ftrace 的 `current_tracer`,`-e`(event)对应 `events/` 下的事件、`-l`/`-g`/`-v` 对应 filter——它没有引入新能力,只是把 ftrace 的接口包好用了。

### 二、KernelShark:GUI 可视化

`trace.dat` 还能用 **KernelShark** 打开(图形界面),事件在时间轴上铺开、可缩放/过滤/检索/按 CPU/进程着色。比起文本 `trace-cmd report`,KernelShark 看复杂时序(如多 CPU 上的调度/唤醒/中断交错)直观得多——典型场景:板子上 `trace-cmd record` 一段、拷回桌面 KernelShark 打开,是排查时序类 bug 的标准流程。

### 三、典型用法

```bash
# 录某驱动的函数调用图,跑 5 秒
trace-cmd record -p function_graph -l my_drv_* -c sleep 5

# 录调度类事件(CPU 调度切换)
trace-cmd record -e sched:sched_switch -e sched:sched_wakeup

# 看
trace-cmd report trace.dat | less
# 或 GUI
kernelshark trace.dat
```

## 动手试试

1. 宿主机上 `trace-cmd record -p function ls /` + `trace-cmd report` 看 `ls` 的内核函数调用
2. `trace-cmd record -e sched:sched_switch sleep 1`,看一秒内 CPU 上的调度切换
3. KernelShark 打开 `trace.dat`,练习缩放/过滤/按 CPU 分列
4. 思考题:trace-cmd 相比直接用 ftrace 的 echo 接口,赢在哪?(提示:易用 + trace.dat 离线/跨机)

## 延伸阅读

- 源码/工具:trace-cmd 是用户态工具(项目 `kernel.org/pub/scm/utils/trace-cmd`),本仓库不含其源码;它的内核侧后端就是 [06 ftrace](./06-debug-ftrace.md) 讲的内核 ftrace + tracefs。
- kernel.org:[ftrace](https://docs.kernel.org/trace/ftrace.html)、[trace-cmd(工具文档见项目 README)](https://git.kernel.org/pub/scm/utils/trace-cmd/trace-cmd.git/)。
- 关联本站:本篇是 [06 ftrace](./06-debug-ftrace.md) 的命令行封装;trace-cmd 录的事件 tracepoint 在 ftrace 里展开;性能分析场景配合 [perf](./13-debug-perf.md)。
