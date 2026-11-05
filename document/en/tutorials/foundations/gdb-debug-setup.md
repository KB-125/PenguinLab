## What We're Doing

In this post, we set up the foundational infrastructure for kernel debugging — GDB remote debugging of an ARM64 kernel. We'll rely on this toolchain later when writing kernel modules, debugging drivers, and tracking down panics, so it's worth taking the time to get it right. Honestly, this process is more convoluted than it seems. We ran into four layers of issues: `vmlinux` had no debug info at all, QEMU did not expose a debug port, VSCode's debug configuration used the wrong GDB, and KASLR caused breakpoint address mismatches. None of these are complex in isolation, but stacked together they produce the blood-pressure-spiking phenomenon of "the breakpoint is red but the kernel just runs right past it." We'll break this down from start to finish so you can quickly pinpoint similar issues using this troubleshooting hierarchy in the future.

## What You Need to Know

### Layer 0: `vmlinux` Must Actually Contain Debug Info

This layer is neither on the QEMU side nor the GDB side — it is inside the kernel itself. If `vmlinux` has no debug info, GDB still connects and breakpoints still hit, but `list` only shows disassembly, `info locals` shows no variables, and single-stepping has no source line numbers. Many people mistake this for a GDB or KASLR problem, when the kernel was simply built without DWARF. We hit exactly this when configuring the kernel following [02 mini config](./02-kernel-mini-config.md): the fragment contained `CONFIG_DEBUG_INFO=y`, but `olddefconfig` quietly dropped it (the cause and fix are in the "`CONFIG_DEBUG_INFO=y` Is Set but `vmlinux` Has No Debug Info" section over there).

Spend ten seconds verifying before connecting GDB:

```bash
aarch64-linux-gnu-readelf -S out/build_latest_arm64/vmlinux | grep -c '\.debug_'
```

It should print a positive number (the number of DWARF debug sections). If it prints `0`, the symbol table carries no debug info — go back to 02 and check `CONFIG_DEBUG_KERNEL` and `CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT` in the fragment. The fastest corroborating signal is file size: a `vmlinux` with debug info is tens of MB, one without is around 7 MB.

### Layer 1: QEMU Must Expose the GDB Port

By default, when QEMU launches a kernel, it runs straight through without pausing anywhere to wait for a debugger connection. To give GDB a chance to intervene, we need two startup parameters: `-s` is shorthand for `-gdb tcp::1234`, which tells QEMU to listen on port 1234 for the GDB remote debugging protocol; `-S` freezes the CPU immediately after launch, preventing it from executing the first instruction until GDB sends the `continue` command to continue.

Our [qemu-run.sh](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/scripts/qemu-run.sh) script adds a `debug` command for this, automatically appending `-s -S` when building the QEMU command:

```bash
./scripts/qemu-run.sh debug
```

This way, QEMU pauses in its initial state after launch, waiting for GDB to connect. If we start it directly with the `run` command, the kernel runs to completion without waiting, leaving no window for GDB to connect.

### Layer 2: We Must Use a Cross-Debugger

This is the pitfall we actually fell into. Initially, our VSCode `launch.json` configuration used the local `/usr/bin/gdb` — an x86_64 GDB that doesn't understand the ARM64 instruction set at all. While connecting to QEMU's GDB stub doesn't inherently require understanding the target architecture (the GDB remote protocol is architecture-agnostic), operations like parsing symbols, setting breakpoints, and single-stepping all require understanding the target binary's instruction encoding and register layout — things an x86 GDB simply can't do.

The correct approach is to use the `aarch64-linux-gnu-gdb` included with our cross-toolchain. The corrected VSCode `launch.json` configuration looks like this:

```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Kernel Debug (ARM64 QEMU)",
            "type": "cppdbg",
            "request": "launch",
            "program": "${workspaceFolder}/out/build_latest_arm64/vmlinux",
            "MIMode": "gdb",
            "miDebuggerPath": "/usr/sbin/aarch64-linux-gnu-gdb",
            "miDebuggerServerAddress": "localhost:1234",
            "cwd": "${workspaceFolder}",
            "setupCommands": [
                {
                    "text": "set architecture aarch64",
                    "ignoreFailures": false
                }
            ]
        }
    ]
}
```

There are a few key points here. `program` points to `vmlinux` rather than `Image`, because GDB needs an ELF file to read the symbol table and debug information (`Image` is a raw binary stripped of that information). `miDebuggerPath` points to the cross-debugger. `miDebuggerServerAddress` tells VSCode the address and port of the GDB stub. Note that we should not redundantly add `target remote localhost:1234` inside `setupCommands` — the `miDebuggerServerAddress` field itself causes the cppdbg adapter to automatically execute a `target remote` connection, and doing it manually again will trigger a duplicate connection error.

If you're on Ubuntu/Debian and only have `gdb-multiarch` installed (as on our machine — `/usr/bin/gdb-multiarch` exists, but `aarch64-linux-gnu-gdb` is not in PATH), simply replace `aarch64-linux-gnu-gdb` with `gdb-multiarch` in every command above; it has built-in AArch64 support and works exactly the same.

### Layer 3: KASLR Shifts Breakpoint Addresses

After fixing the first two layers, we used command-line GDB to verify that breakpoints could indeed be set successfully:

```
$ aarch64-linux-gnu-gdb -batch \
  -ex "set architecture aarch64" \
  -ex "target remote localhost:1234" \
  -ex "break start_kernel" \
  -ex "info breakpoints" \
  out/build_latest_arm64/vmlinux

Breakpoint 1 at 0xffff800080550a08: file init/main.c, line 1006.
```

The breakpoint at `start_kernel` is set at `0xffff800080550a08`, the address resolves correctly, and the source line number matches. But the kernel still didn't stop — this is the third layer of the problem.

The root cause is KASLR (Kernel Address Space Layout Randomization). The symbol addresses in the `vmlinux` file are statically linked at compile time — for example, `start_kernel` is at `0xffff800080550a08`, and the kernel base `_text` starts at `0xffff800080000000`. If KASLR takes effect, the kernel adds a random offset to its load base on every boot, so the actual runtime address diverges from the compile-time symbol address. GDB sets breakpoints using the static addresses, so naturally it can't intercept code executing at different addresses.

One clarification: our mini config starts from `allnoconfig`, which leaves `CONFIG_RANDOMIZE_BASE` off (confirm with `grep RANDOMIZE_BASE out/build_latest_arm64/.config`), so a kernel built from our config doesn't hit this layer. But it's a classic trap — the moment you switch to `defconfig` (which sets `CONFIG_RANDOMIZE_BASE=y`) or enable KASLR manually, compile-time symbol addresses no longer match runtime ones and breakpoints "set fine but never hit."

The solution is to add `nokaslr` to the kernel boot parameters, telling the kernel not to randomize addresses for this boot. We integrated this into the `debug` command so that KASLR is only disabled during debugging and remains enabled for normal runs:

```bash
build_qemu_debug_command() {
    local cmd
    cmd="$(build_qemu_command)"
    # nokaslr: 让 GDB 断点地址匹配 vmlinux 的静态符号
    cmd="${cmd/rdinit=\/init/rdinit=\/init nokaslr}"
    # -s -S: 开放 GDB 端口 + 启动时暂停
    cmd+=" -s -S"
    echo "${cmd}"
}
```

Here we use a bash string replacement trick to insert `nokaslr` into the existing `-append` parameter, rather than overwriting the entire parameter.

### The Complete Debugging Workflow

With all of the above fixed, the debugging workflow is fully connected. It takes three steps.

First, launch QEMU in debug mode in one terminal:

```bash
./scripts/qemu-run.sh debug
```

QEMU starts up and pauses, waiting for GDB to connect.

Second, connect with command-line GDB and set a breakpoint (or press F5 in VSCode):

```bash
aarch64-linux-gnu-gdb out/build_latest_arm64/vmlinux
(gdb) set architecture aarch64
(gdb) target remote :1234
(gdb) break start_kernel
(gdb) continue
```

Third, the breakpoint hits. You'll see GDB stop at the `start_kernel` function in `init/main.c`. From here, we can single-step, inspect variables, and examine the call stack.

### Troubleshooting Hierarchy Summary

Looking back, these issues form an outside-in troubleshooting hierarchy. The outermost layer is `vmlinux` itself lacking debug info — GDB can still connect and breakpoints can hit, but `list` only shows disassembly and there are no source lines or variables. Next comes QEMU startup parameters — without `-s -S`, GDB has no window to intervene at all. Then the debugging toolchain — using the wrong GDB or redundantly executing `target remote` causes connection errors. The deepest layer is the kernel's own security feature, KASLR — which causes runtime addresses to diverge from compile-time symbols. In the future, when encountering "breakpoint not hit" or "breakpoint hits but no source" issues, we recommend troubleshooting layer by layer in this order: **debug info → QEMU parameters → GDB connection → address mapping**.

## Try It Yourself

1. Run `./scripts/qemu-run.sh debug` in a terminal and check whether the output contains "Waiting for GDB connection"
2. Open another terminal, connect with command-line GDB, and verify by setting a breakpoint: `aarch64-linux-gnu-gdb -batch -ex "target remote :1234" -ex "break start_kernel" -ex "c" out/build_latest_arm64/vmlinux`
3. If using VSCode, configure `launch.json` and press F5 to confirm the breakpoint hits
4. In GDB, try `bt` (view the call stack), `list` (view source code), and `info registers` (view registers)
5. Try setting breakpoints on other functions like `rest_init` or `kernel_init` to observe different stages of kernel startup

## Further Reading

- [GDB kernel debugging documentation](https://docs.kernel.org/process/debugging/gdb-kernel-debugging.html) — The official kernel.org guide to QEMU+GDB debugging
- [Speeding up kernel development with QEMU](https://lwn.net/Articles/660404/) — A classic LWN article
- qemu-run.sh — The `build_qemu_debug_command()` function in the project script
