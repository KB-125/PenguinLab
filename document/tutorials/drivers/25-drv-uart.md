---
title: "UART / TTY 驱动:串口——嵌入式调试命脉"
slug: drv-uart
prerequisites:
  - drv-platform
  - debug-printk
difficulty: advanced
tags: [driver, uart, tty, serial_core, pl011, console, arm64]
architectures: [arm64, arm32, riscv]
kernel_version: "6.19"
sources:
  - doc: https://docs.kernel.org/driver-api/tty/
  - source: third_party/linux（6.19）include/linux/serial_core.h、drivers/tty/serial/
maturity: drafting
related:
  - /tutorials/drivers/10-drv-platform
  - /tutorials/debugging/01-debug-printk
---

> 🔨 **整理中** · 这一篇讲 **UART/TTY 驱动**——串口驱动子系统。串口是嵌入式调试命脉(printk console、shell、调试 log 全靠它)、也驱动 GPS/蓝牙模块/GSM 模块等串行外设。素材以 6.19 源码 + kernel.org [TTY 文档](https://docs.kernel.org/driver-api/tty/) 为权威。本站 QEMU virt 的串口(PL011)就是一套 UART 驱动,`printk` 输出、BusyBox shell 都走它。

## 做什么

UART(通用异步收发器)是最朴素的串口协议(TX/RX 两根线、按波特率逐位传)。SoC 上一般有几个 UART 控制器(本站 QEMU virt 用的 PL011、树莓派的 mini-uart、各 SoC 自家的),内核要给它写驱动、让用户态能 `echo > /dev/ttyAMA0` 或 `screen /dev/ttyUSB0`、并且让 `printk` 能把日志打到串口(console)。UART 驱动比 platform/i2c 复杂——它要接到 **TTY 子系统**(`drivers/tty/`,字符设备 `/dev/tty*` 的框架)和 **serial_core**(`drivers/tty/serial/`)之间。这一篇拆 UART 驱动的三件套 + console 注册。

## 要了解什么

### 一、三件套:`uart_driver` / `uart_port` / `uart_ops`

- **`uart_driver`**(`serial_core.h:888`):一个 UART 驱动(可能管多个端口/多路串口),含 `owner`/`driver_name`/`dev_name`(用户态 `/dev/` 名字,如 `ttyAMA`)/`nr`(端口数)/`major`/`minor`。`uart_register_driver`(`:1131`)注册它——把 UART 驱动挂进 TTY 子系统。
- **`uart_port`**(`:442`):一个具体 UART 端口实例——寄存器基址(`membase`)、IRQ、波特率、当前状态。每个 SoC 的每路 UART 一个 port。
- **`uart_ops`**(`:375`):端口的回调表,核心:`startup`(打开串口、申请 IRQ)、`shutdown`、`start_tx`/`stop_tx`(发/停发)、`receive_chars`(收,ISR 里调)、`set_termios`(设波特率/数据位/校验/停止位)、`type`/`release_port`/`config_port` 等。

SoC 厂商的 UART 驱动(如 `drivers/tty/serial/amba-pl011.c` 本站用的、`8250.c`、`imx.c`)做的是:定义 `uart_driver` + 每路一个 `uart_port` + 填 `uart_ops`,注册到 serial_core。

### 二、用户态视角:`/dev/ttyAMA0`

UART 驱动注册后,用户态看到的是 `/dev/ttyAMA0`(名字来自 `uart_driver.dev_name` + 序号)。`echo hello > /dev/ttyAMA0` → TTY 层 → serial_core → 你的 `uart_ops.start_tx` 把字节塞进 UART 发送寄存器;对端发来字节触发 ISR → 你的 ISR 读接收寄存器 → `tty_flip_buffer_push` 推给 TTY 层 → 用户态 `read`。整条链 UART 驱动只管"硬件收发 + 字节进出",中间的行编辑/流量控制/`termios` 设置都在 TTY/serial_core 层。

### 三、波特率/校验:`set_termios`

用户态 `stty -F /dev/ttyAMA0 115200 cs8 -cstopb -parenb`(设 115200/8N1)走 `tcsetattr` → TTY 层 → `uart_ops.set_termios(port, &termios, old)`。驱动在这里读 termios、按波特率/数据位/停止位/校验位写硬件寄存器。所以"串口能配波特率"靠 `set_termios` 实现。

### 四、console:UART 当 printk 输出

UART 驱动还能注册成 **console**(`uart_register_console`/`CON_PRINTK`),让 `printk` 的日志打到串口——本站 QEMU `console=ttyAMA0` 启动参数就是这个机制。console 注册后,内核 `printk` 调驱动的 `console.write(port, s, n)` 把字符串同步打到串口(早期引导阶段 console_write 直接写寄存器、不走 TTY 层)。这是嵌入式调试的根——内核 boot log、panic 信息全靠 UART console 出来。

## 动手试试

1. `ls /dev/ttyAMA* /dev/ttyS*` 看串口设备;本站 QEMU 的 `console=ttyAMA0`,所有 boot log 走 PL011
2. `stty -F /dev/ttyAMA0` 看当前 termios(波特率/数据位);`stty -F /dev/ttyAMA0 115200` 改
3. 读 `drivers/tty/serial/amba-pl011.c`(本站用的)看 `uart_driver`/`uart_ops`(尤其 `start_tx`/`receive_chars`/`set_termios`)怎么填;或 `8250.c`(最经典的 UART 驱动)
4. `dmesg | grep tty` 看串口注册日志;`cat /sys/class/tty/ttyAMA0/device/uevent`
5. 思考题:为什么 `printk` 在内核早期(还没挂 TTY)就能输出到串口 console?(提示:console.write 直接写寄存器,不依赖 TTY 层)

## 延伸阅读

- 源码(本仓库 `third_party/linux/`,6.19.9):`include/linux/serial_core.h:888 struct uart_driver`、`:442 struct uart_port`、`:375 struct uart_ops`、`:1131 uart_register_driver`;serial_core `drivers/tty/serial/serial_core.c`;UART 驱动 `drivers/tty/serial/amba-pl011.c`(本站 QEMU ARM64)、`8250/`(`drivers/tty/serial/8250/`,x86/老 SoC 最常见)、各 SoC `*-uart.c`;TTY 层 `drivers/tty/tty_io.c`;console 接口 `include/linux/console.h`。
- kernel.org:[TTY](https://docs.kernel.org/driver-api/tty/)、`Documentation/driver-api/serial/`。
- 关联本站:[01 printk](../debugging/01-debug-printk.md) 的 console 输出路径、[debug-bug-classification](../debugging/00-debug-bug-classification.md) 的"内核早期 console";本站 QEMU 所有 boot log 都走 PL011 UART console。
