#!/usr/bin/env python3
"""Build a clangd compilation database for the kernel and busybox trees.

The kernel and busybox builds already write one ``.cmd`` file per object
(``.main.o.cmd`` etc.) that records the exact compiler command line.  This
script feeds those files to the kernel's own
``scripts/clang-tools/gen_compile_commands.py`` and then fixes up the result
so that one ``compile_commands.json`` can serve both source trees:

* ``gen_compile_commands.py`` always records the ``-d`` directory as the
  ``directory`` field.  Busybox is built in ``<build>/busybox`` and its
  compile commands use relative paths (``-Iinclude``, ``-include
  include/autoconf.h``), so its entries must point at that subdirectory
  instead of the build root.
* Stale entries (source file deleted since the build) are dropped.

No rebuild is required: the ``.cmd`` files are reused as-is.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def count_cmdfiles(directory: Path) -> int:
    return sum(
        1
        for path in directory.rglob("*")
        if path.is_file() and path.name.startswith(".") and path.name.endswith(".cmd")
    )


def describe(path: str, prefixes: dict[str, str]) -> str:
    for prefix, name in prefixes.items():
        if path.startswith(prefix):
            return name
    return "other"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate compile_commands.json for the ARM64 kernel + busybox build"
    )
    parser.add_argument(
        "-b",
        "--build-dir",
        type=Path,
        default=REPO_ROOT / "out/build_latest_arm64",
        help="kernel build directory containing the .cmd files (default: %(default)s)",
    )
    parser.add_argument(
        "--kernel-src",
        type=Path,
        default=REPO_ROOT / "third_party/linux",
        help="kernel source tree (default: %(default)s)",
    )
    parser.add_argument(
        "--busybox-src",
        type=Path,
        default=REPO_ROOT / "third_party/busybox",
        help="busybox source tree (default: %(default)s)",
    )
    parser.add_argument(
        "--busybox-dir",
        type=Path,
        default=None,
        help="busybox build directory (default: <build-dir>/busybox)",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="output file (default: <build-dir>/compile_commands.json)",
    )
    parser.add_argument(
        "--no-busybox",
        action="store_true",
        help="do not fix up busybox entries (kernel-only database)",
    )
    args = parser.parse_args()

    build_dir = args.build_dir.resolve()
    output = (args.output or build_dir / "compile_commands.json").resolve()
    kernel_src = args.kernel_src.resolve()
    busybox_src = args.busybox_src.resolve()
    busybox_dir = (args.busybox_dir or build_dir / "busybox").resolve()

    if not build_dir.is_dir():
        print(f"error: build directory not found: {build_dir}", file=sys.stderr)
        return 1

    cmdfiles = count_cmdfiles(build_dir)
    if cmdfiles == 0:
        print(
            f"error: no .cmd files under {build_dir};\n"
            f"       build the kernel first, e.g. ./scripts/qemu-run.sh build",
            file=sys.stderr,
        )
        return 1

    generator = kernel_src / "scripts/clang-tools/gen_compile_commands.py"
    if not generator.is_file():
        print(f"error: kernel generator not found: {generator}", file=sys.stderr)
        return 1

    output.parent.mkdir(parents=True, exist_ok=True)
    print(f"[*] {cmdfiles} .cmd files under {build_dir}")
    subprocess.run(
        [sys.executable, str(generator), "-d", str(build_dir), "-o", str(output)],
        check=True,
    )

    entries = json.loads(output.read_text())
    raw_count = len(entries)

    patched = 0
    if not args.no_busybox:
        if busybox_src.is_dir() and busybox_dir.is_dir():
            prefix = str(busybox_src) + os.sep
            for entry in entries:
                if entry["file"].startswith(prefix) and entry["directory"] != str(busybox_dir):
                    entry["directory"] = str(busybox_dir)
                    patched += 1
        else:
            print(
                f"[!] busybox tree or build dir missing, skipping patch: "
                f"{busybox_src} / {busybox_dir}",
                file=sys.stderr,
            )

    kept = []
    stale = 0
    for entry in entries:
        if os.path.exists(entry["file"]) and os.path.isdir(entry["directory"]):
            kept.append(entry)
        else:
            stale += 1

    kept.sort(key=lambda e: e["file"])
    output.write_text(json.dumps(kept, indent=2, sort_keys=True) + "\n")

    prefixes = {
        str(kernel_src) + os.sep: "kernel",
        str(busybox_src) + os.sep: "busybox",
    }
    counts = {"kernel": 0, "busybox": 0, "other": 0}
    for entry in kept:
        counts[describe(entry["file"], prefixes)] += 1

    print(f"[+] {output}")
    print(
        f"[+] {len(kept)} entries "
        f"(kernel {counts['kernel']}, busybox {counts['busybox']}, other {counts['other']})"
    )
    print(f"[+] busybox directory patched: {patched}, stale entries dropped: {stale}")
    if raw_count != len(kept):
        print(f"[i] raw entries before filtering: {raw_count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
