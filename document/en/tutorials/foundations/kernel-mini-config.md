## What We're Doing

In this section, we're going to do something many people won't tell you about — designing a streamlined kernel configuration from scratch, instead of blindly using `defconfig`. We'll end up with a kernel config containing only the minimal feature set required to boot the QEMU virt machine. It has just 575 `=y` config options, whereas `defconfig` has 3305.

Wait, we're getting our hands dirty this soon? Yep, why not? Haha! Building a kernel config ourselves from the ground up — isn't that awesome?

## What to Know

### The Problem with defconfig

`defconfig` is a predefined default configuration in the kernel source tree. For ARM64, it's located at `arch/arm64/configs/defconfig`. Running `make defconfig` gives you a "working" kernel config, which sounds great. The problem is that this config includes drivers for a massive number of real SoCs — GPUs, audio, and various board peripheral drivers. For kernel learning with the QEMU virt machine, we don't need any of this hardware support. It does nothing but slow down compilation and distract us.

To put it bluntly, more than half of the 3305 `=y` options are things we'll never use. The hundreds of extra drivers compiled in are all dead code inside QEMU. Rather than learning inside a bloated kernel, we're better off trimming it down ourselves.

### The Three-Step Configuration Process

Our strategy is "start from zero, enable on demand," broken down into three steps.

First, we use `allnoconfig` to generate a baseline config with almost everything disabled. This target sets all non-essential options to `n`, keeping only the hard dependencies of the architecture itself. For ARM64, the generated `.config` has only a few dozen options enabled, with everything else turned off.

```bash
cd third_party/linux
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     O=../../out/build_latest_arm64 allnoconfig
```

Second, we use `merge_config.sh` to merge in our prepared config fragment. This script lives in the `scripts/kconfig/` directory of the kernel source. It merges the fragment's options into a base config one by one — `=y` enables them, `=m` sets them as modules.

Two parameters are easy to mix up: `-m` is just a switch meaning "only merge, do not run make" (it takes no path); what determines where the result goes is `-O <dir>` — the script writes the merged config to `$OUTPUT/.config`, and without `-O` it writes to `./.config` in the current directory. The first positional argument is the base `.config`; the fragments follow. So the correct invocation is:

```bash
scripts/kconfig/merge_config.sh -m -O ../../out/build_latest_arm64 \
    ../../out/build_latest_arm64/.config \
    ../../configs/arm64-qemu-virt-learn.config
```

Do not drop `-O`. If you run this inside `third_party/linux` without it, the merged config lands in the source tree's `.config` while `out/build_latest_arm64/.config` stays the untouched `allnoconfig`; and since `-m` never runs make, nothing validates it — the mistake is carried silently all the way to build and boot (see the pitfalls below).

Third, we use `olddefconfig` to have the kernel build system automatically fill in all dependencies. Our hand-written fragment only lists the options "we know we need," but kernel configs have tons of implicit dependencies — for example, enabling `CONFIG_PRINTK=y` might require several other config options. `olddefconfig` traverses the entire config tree, automatically filling in all missing dependencies and applying default values to any newly introduced options:

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     O=../../out/build_latest_arm64 olddefconfig
```

After merging, check the four critical options are present (run this from the repository root):

```bash
grep -E '^CONFIG_(SERIAL_AMBA_PL011|SERIAL_AMBA_PL011_CONSOLE|BLK_DEV_INITRD|RD_GZIP)=' \
     out/build_latest_arm64/.config
```

All four must be `=y`. Miss any one and the kernel either prints nothing or ignores the initrd, leaving QEMU stuck at "Starting QEMU..." with no log output at all.

One more note on log format: the fragment also enables `CONFIG_PRINTK_TIME=y`, which is what puts a `[    0.000000]` boot timestamp in front of every kernel log line (as in the next article's boot log). `allnoconfig` leaves it off, which degrades the log to bare text and makes it much harder to tell where boot stalls or how long each step takes. To turn it on temporarily without touching the config, pass `printk.time=1` on the kernel command line.

After these three steps, the final `.config` inflates from a few dozen options to 575 — the extras are all dependencies automatically filled in by `olddefconfig`. This is still only about a sixth of `defconfig` (3305 options with kernel 6.19), and every enabled option can be traced back to a specific requirement in our fragment.

### Design Philosophy of the Config Fragment

Our prepared fragment file is [configs/arm64-qemu-virt-learn.config](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/configs/arm64-qemu-virt-learn.config). It's organized by functional category, with each group annotated with comments explaining "why we need these options." Of course, you might wonder what all these things are. If you're not entirely sure — a great approach is to use a recursive descent method to look up the related concepts. Let's quickly run through what these are:

First, the platform basics. The ARM64 architecture itself is mandatory, and SMP (Symmetric Multiprocessing) must be enabled since our QEMU launch will configure two CPU cores:

```
CONFIG_ARM64=y
CONFIG_64BIT=y
CONFIG_SMP=y
CONFIG_NR_CPUS=2
```

Next is the serial console. The QEMU virt machine uses the ARM PL011 UART for serial output, which is exactly what the `console=ttyAMA0` kernel boot parameter points to. Without these options, you'll see nothing after the kernel boots — no boot logs, no shell prompt, just dead silence:

```
CONFIG_TTY=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
```

Then comes initramfs support. Our rootfs will be packaged as a cpio.gz file loaded as an initrd, so the kernel must support gzip decompression to unpack it:

```
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
```

On the filesystem front, `devtmpfs` tells the kernel to automatically create device nodes under `/dev`, while `procfs` and `sysfs` provide kernel information interfaces for `/proc` and `/sys` respectively, and `tmpfs` is for memory-based filesystems. These four are the basic prerequisites for BusyBox shell to work properly. The kernel module related configs let us load and unload `.ko` modules later on, and the debugging support group (`DEBUG_KERNEL`, `DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT`, `GDB_SCRIPTS`, `KALLSYMS_ALL`) is prepared for GDB remote debugging. Note that `DEBUG_INFO` is a hidden symbol in 6.x and must be pulled in by `DEBUG_KERNEL` plus a DWARF-version choice; writing `CONFIG_DEBUG_INFO=y` directly gets silently dropped (see the pitfalls below).

The entire fragment is about 50 options in 100+ lines, with each config option accompanied by a comment explaining its purpose and dependencies. This "minimal + annotated" approach turns the config file itself into a study note.

### Pitfalls We Hit

This three-step process sounds simple, but we ran into quite a few pitfalls along the way. Here are the most noteworthy ones.

**"The source tree is not clean"**

This is the most common issue. The kernel Makefile has a check (in the `outputmakefile` target of `Makefile`) that, when using `O=` for out-of-tree builds, detects whether a `.config` file, a `include/config/` directory, or a `arch/arm64/include/generated/` directory exists in the source tree root. If it detects any of them, it deems the "source tree not clean" and refuses to continue.

What happened to us was worse. We had run `merge_config.sh` the old way (without `-O`), so the merged config was written to the `.config` in the source tree root. The following `make O=... olddefconfig` then failed with "source tree is not clean". We deleted the stray `.config` as the error suggested and reran it — and it passed, but it used the build directory's **allnoconfig that never had the fragment merged in**. The resulting kernel had neither a serial driver nor initramfs support, so QEMU produced no output at all.

The real root cause is not the dirty source tree but the fact that the config never reached the build directory. Do both:

```bash
rm -f third_party/linux/.config      # clean up the leftover from the old invocation
# then re-run the merge with -O as shown above and grep the four critical options
```

Prevention: whenever you build out-of-tree with `O=`, always pass `-O` to `merge_config.sh`, and grep the four critical options after every merge. "No error" does not mean "correct".

**merge_config.sh Parameters**

The two easiest things to mix up:

- `-m` takes no path; it merely means "merge only, do not run make".
- `-O <dir>` decides where the result is written: `$OUTPUT/.config`, defaulting to `./.config` in the current directory.

The first positional argument is the base `.config` (read and used as the starting point); the remaining ones are fragments. So the correct invocation is `merge_config.sh -m -O <output_dir> <output_dir>/.config <fragment>`, not `merge_config.sh -m <output_dir>/.config <fragment>` (the latter writes the merged result into the current directory).

**`CONFIG_DEBUG_INFO=y` Is Set but `vmlinux` Has No Debug Info**

This is the pitfall we actually hit later in the GDB article, and the most insidious kind: `merge_config.sh` and `olddefconfig` never complain — the options just quietly disappear. Three mechanisms stack up:

1. Since 6.x, `CONFIG_DEBUG_INFO` is no longer a visible switch but a hidden symbol (no prompt). Whether `vmlinux` carries debug info is decided by the "Debug information" choice, which `depends on DEBUG_KERNEL`.
2. `olddefconfig` recomputes hidden symbols according to Kconfig rules: a `CONFIG_DEBUG_INFO=y` shoved in by the fragment, with no corresponding choice option to back it, is reset to `n` and removed from `.config`.
3. `merge_config.sh` appends the whole fragment to the end of `.config`, and `olddefconfig` parses line by line — so the parent switch must come **before** the child option. `CONFIG_DEBUG_KERNEL=y` has to appear before `CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y` to take effect.

The same class of problem hits `VIRTIO` (needs `CONFIG_VIRTIO_MENU=y` first), `TRACING`/`FUNCTION_TRACER`/`KPROBE_EVENTS` (need `CONFIG_FTRACE=y` first), and `LOCKDEP` (a hidden symbol, enabled via `CONFIG_PROVE_LOCKING=y`).

Two commands are enough to tell whether you got bitten:

```bash
grep -E '^CONFIG_(DEBUG_KERNEL|DEBUG_INFO|GDB_SCRIPTS)=' out/build_latest_arm64/.config
aarch64-linux-gnu-readelf -S out/build_latest_arm64/vmlinux | grep -c '\.debug_'
```

All three lines from the first command must be `=y`; the second should print a positive number (the number of DWARF debug sections). If it's `0`, GDB can still connect and set breakpoints, but you won't see source lines or variables. As a quick hint: when bitten, `vmlinux` is only about 7 MB; once fixed it grows to tens of MB — file size itself is the fastest signal.

**Forgetting to Set ARCH and Building for x86**

This is a classic pitfall. The kernel build system determines the target architecture based on the `ARCH` variable; if unset, it defaults to the host architecture (x86_64 in WSL2). If `CROSS_COMPILE` is unset, it uses the native gcc. The result is that `make -j14` completes and outputs `arch/x86/boot/bzImage is ready` — a whole lot of compiling for nothing.

There are two solutions: either append `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-` to every make command, or export these two variables in the shell. The latter is less tedious, but keep in mind that export only affects the current shell session — close the terminal and you'll need to set them again.

**Working Directory and make -C**

Running `make O=... Image` directly from the project root `PenguinLab/` will throw a `No targets specified and no makefile found` error because the project root doesn't contain the kernel's Makefile. You either need to `cd third_party/linux` first before running make, or use `make -C third_party/linux` to explicitly specify the source directory.

## Try It Yourself

1. Confirm that `third_party/linux/Makefile` exists; if not, run `./scripts/linux-submodule.sh init` to fetch the kernel source
2. Execute the three-step configuration process in order: `allnoconfig` → `merge_config.sh` → `olddefconfig`; include `ARCH` and `CROSS_COMPILE` with steps 1 and 3, and make sure step 2 passes `-O` so it writes into the build directory
3. Use `grep -c "=y" out/build_latest_arm64/.config` to count the final number of config options — you should see around 575 with kernel 6.19
4. Use `diff <(grep "=y" out/build_latest_arm64/.config | sort) <(grep "=y" <(make ARCH=arm64 O=../../out/build_latest_arm64 defconfig && cat ../../out/build_latest_arm64/.config) | sort)` to compare it against defconfig and see what we cut out

## Further Reading

- [Kbuild Kernel Build System Documentation](https://www.kernel.org/doc/html/latest/kbuild/kbuild.html) — Official definitions for variables like `ARCH`, `CROSS_COMPILE`, and `O=`
- [Linux Kernel Build Instructions](https://docs.kernel.org/admin-guide/README.html) — The official kernel.org getting-started guide for building the kernel
- [configs/arm64-qemu-virt-learn.config](https://github.com/Awesome-Embedded-Learning-Studio/PenguinLab/blob/main/configs/arm64-qemu-virt-learn.config) — Our mini config fragment file, with comments on every config option
