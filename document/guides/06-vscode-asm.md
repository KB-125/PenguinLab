---
title: 配置 VSCode 汇编编辑环境
description: 在一台全新的 WSL2 + VS Code 上，配好内核汇编的高亮、hover、头文件跳转与宏展开——三件套各管一层
maturity: verified
---

# 配置 VSCode 汇编编辑环境

读 `arch/arm64/kernel/head.S` 这类内核汇编时，VSCode 默认只有一片白板：指令不认识、`#include <linux/linkage.h>` 是死链、`SYM_CODE_START(head)`、`__HEAD` 这种宏完全看不出展开成什么。这篇文档把「换一台设备、从零开始、十分钟配好」的完整流程钉死。

整体是**三层**，各管一件事，互不替代：

| 层 | 由谁提供 | 负责什么 | 不负责什么 |
|---|---|---|---|
| 语法高亮 | 我们自己 fork 的 asm-lsp 客户端（TextMate 语法） | 助记符、寄存器、立即数、指令、标签、宏调用、`#include` 上色 | 语义 |
| 指令语义 | `Arm.armls`（Arm 官方语言服务器） | arm64 指令 hover：操作数含义 + developer.arm.com 文档链接 | 不认识 `#include` 和内核宏 |
| CPP 层 | 同一个 fork 扩展（`src/pp.ts` + `src/kernelcpp.ts`） | `#include` 跳头文件、宏 hover（定义处 + 展开结果）、预处理器视图 | 不做完整 C 语义 |
| C 语义（可选） | `clangd` | `.c/.h` 的跳转与补全 | 不支持 `.S`（clangd 会直接报 `does not support assembly`） |

> 为什么 arm64 的指令层要用两个扩展：asm-lsp 的指令文档只有一句话（`mov [arm64]`），ArmLS 才有「Operands: 1. Xd: Register …」和官方链接，但 ArmLS 又只认它自己的语言 id `arm.aarch64-assembly`。所以仓库里的 `.vscode/settings.json` 用路径通配把 `arch/arm64/**/*.S` 单独路由给 ArmLS，其余汇编走 asm-lsp，两边各司其职。

## 0. 前提

- WSL2 + Ubuntu 24.04，VS Code 装了 **WSL** 扩展（或 Remote-SSH），从 WSL 里 `code --version` 能跑通。
- `node` / `npm`（只要用来打一次 vsix，装完可不管）：
  ```bash
  node -v && npm -v      # v18+ 即可；缺的话：sudo apt install nodejs npm
  ```
- 交叉工具链（CPP 层和 clangd 都要用）：
  ```bash
  sudo apt install gcc-aarch64-linux-gnu
  ```
- 本仓库已经 clone 好，且内核子模块在：
  ```bash
  git submodule update --init third_party/linux third_party/busybox
  ```

### 一条命令装完（推荐）

上面这些前提满足后，`scripts/setup-vscode-asm.sh` 把第 1–3 节全部做完，幂等、可反复跑：

```bash
./scripts/setup-vscode-asm.sh          # 装服务器 + 客户端扩展 + ArmLS + clangd
./scripts/setup-vscode-asm.sh check    # 只体检，不改任何东西
```

常用开关（都走环境变量）：

| 变量 | 作用 |
|---|---|
| `FORCE=1` | 已装也重下/重装（升版本、换分支时用） |
| `SKIP_ARMLS=1` / `SKIP_CLANGD=1` | 不装可选扩展 |
| `SRC_DIR=...` / `SERVER_DIR=...` | fork 克隆位置 / 服务器安装位置 |
| `ASM_LSP_VERSION=...` / `FORK_BRANCH=...` | 换服务器版本、换客户端分支 |

脚本不信任「装过就算成功」：服务器会跑 `asm-lsp version` 核对，客户端会对比安装目录里的版本号和 fork 分支的 `package.json`，不一致才重建。下面三节是它内部做的事，想手动执行或排查时照着看。

## 1. 装 asm-lsp 服务器（Rust 二进制）

客户端只是壳，真正的语言服务器是 `asm-lsp`。上游有现成的 Linux x86_64 预编译包，**不需要装 Rust**：

```bash
mkdir -p ~/.local/bin
curl -fsSL -o /tmp/asm-lsp.tar.gz \
  https://github.com/bergercookie/asm-lsp/releases/download/v0.10.1/asm-lsp-x86_64-unknown-linux-gnu.tar.gz
tar -xzf /tmp/asm-lsp.tar.gz -C /tmp asm-lsp
install -m 0755 /tmp/asm-lsp ~/.local/bin/asm-lsp

asm-lsp version      # 输出 0.10.1；注意不是 --version，那个会报错
```

`~/.local/bin` 默认在 WSL 的 PATH 里（`~/.profile` 会加）。如果 `asm-lsp version` 提示找不到，先 `export PATH="$HOME/.local/bin:$PATH"`，再确认扩展能找到它（见第 7 节的排查表）。

## 2. 装客户端扩展（本仓库的 fork）

上游客户端只能上色一种 `asm`，没有语法文件、没有 CPP 层、hover 到不认识的 token 还会弹 `No information available` 通知。这些都在 fork 里修好了，直接装 fork 的版本：

```bash
git clone -b kernel-asm-support https://github.com/KB-125/asm-lsp.git ~/tools/asm-lsp-src
cd ~/tools/asm-lsp-src/editors/code
npm ci
npm run package                      # 产出 asm-lsp.vsix
code --install-extension asm-lsp.vsix --force
```

装完 `code --list-extensions --show-versions | grep asm-lsp` 应看到 `asm-lsp.asm-lsp@1.0.2`。

fork 相对上游的改动（都在 `editors/code/`，Rust 服务器一行没动）：

- `syntaxes/gas.tmLanguage.json`：GAS 语法（助记符、寄存器、立即数、标签、宏、`#include`、`.macro`/伪指令）；
- `src/pp.ts`：读 `compile_commands.json` 里该 `.S` 的真实编译命令，跑 `-E -dD`，按 `# <line> "<file>"` 标记回映射到源行；
- `src/kernelcpp.ts`：`#include` 的 hover/F12、宏 hover（`#define` 原文 + 定义位置 + 预处理后实际展开）+ `ASM Tools: Show Preprocessed Source` 命令；
- `src/extension.ts`：middleware 吞掉服务器对未知 token 返回的 `-32803`（否则每次 hover 都弹一条错误通知）；
- `package.json`：额外注册语言 id `arm.aarch64-assembly`（`extensions: []`，不抢文件），两条 grammar 都指向同一份语法。

> 想让它自带服务器二进制（离线分发用）：把 `asm-lsp` 拷到 `editors/code/bin/linux-x64/asm-lsp` 再 `npm run package`。仓库版不带，运行时按 `bin/` → `~/.local/bin/asm-lsp` → `PATH` 顺序找。

## 3. 装 ArmLS（arm64 指令语义）

```bash
code --install-extension Arm.armls
```

这条命令会带上它自带的语言服务器（`tools/armls/armls`），不需要额外下载。装完在扩展面板能看到 `Arm Assembly Support`。

## 4. 放两份配置文件

这两份文件已经在仓库里，clone 下来就有，**不用手写**；换项目时复制过去改路径即可。

**`.asm-lsp.toml`**（工作区根目录）— 告诉 asm-lsp 每个目录用哪套指令集，并关掉诊断：

```toml
[default_config]
assembler = "gas"
instruction_set = "arm64"

[default_config.opts]
diagnostics = false
default_diagnostics = false

[[project]]
path = "third_party/linux/arch/arm64"
assembler = "gas"
instruction_set = "arm64"

[project.opts]
diagnostics = false
default_diagnostics = false
```

上面只摘了 arm64 一条；仓库文件里还有 `arch/x86`（`instruction_set = "x86/x86-64"`）和 `arch/riscv` 两条，结构完全一致。

两个容易踩的点：

- `opts` 必须写在 `[default_config.opts]` 或每个 `[project.opts]` 下面，**顶层的 `[opts]` 会被静默忽略**；
- `opts` 不会继承，每个 `[[project]]` 都要单独写一遍，否则该目录下的诊断又会被打开。

为什么要关诊断：asm-lsp 默认会真的调 `gcc`/`clang` 去汇编当前 `.S`。内核汇编依赖 CPP 的上下文，单独汇编必然报 `fatal error: linux/linkage.h: No such file or directory`，满屏红线。关掉后只剩 hover / 补全 / 跳转。

**`.vscode/settings.json`** — 路由 + ArmLS 的开关（下面是节选，完整版以仓库文件为准，里面还有 semantic highlighting 和 clangd 参数）：

```json
{
  "files.associations": {
    "*.S": "asm",
    "*.s": "asm",
    "*.dis": "asm",
    "**/arch/arm64/**/*.S": "arm.aarch64-assembly"
  },
  "armls.defaultArchitecture": "A64",
  "armls.diagnostics.enable": false,
  "[asm]": {
    "editor.tabSize": 8,
    "editor.insertSpaces": false,
    "editor.wordBasedSuggestions": "off"
  }
}
```

- 含 `/` 的 pattern 会匹配**完整路径**（VSCode 的 `filepatternOnPath` 逻辑），所以能按 `arch/arm64` 精确分流；不写这条就全部走 asm-lsp。
- `armls.diagnostics.enable: false` 同理：ArmLS 不解析 CPP，会把 `__HEAD`、`SYM_CODE_START` 逐个报成 `unrecognised instruction`（head.S 上有 83 条）。
- 如果只装 fork、不装 ArmLS：删掉 `**/arch/arm64/**/*.S` 那一行，全部 `.S` 走 `asm`，高亮/宏/跳转照常，只是 arm64 指令 hover 退化成 asm-lsp 的一句话版本。

## 5. 生成 compile_commands.json（CPP 层的数据来源）

宏展开、`#include` 解析都要知道这个 `.S` 是怎么被编译的。内核自带生成目标：

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=out/build_latest_arm64 compile_commands.json
```

产物是 `out/build_latest_arm64/compile_commands.json`，正好是扩展的默认路径（设置项 `asmTools.compileCommands` 可改）。前提是这个构建目录已经有 `.config`（没配过就先跑 `ARCH=aarch64 LINUX_DEFCONFIG=defconfig scripts/linux-action-scripts.sh config`），否则 `make` 会先弹一堆配置问题。没有它也不会报错，只是 CPP 层静默不工作——这是最常见的一句「宏 hover 没反应」的根因。

## 6. 验证清单

`Reload Window` 之后打开 `third_party/linux/arch/arm64/kernel/head.S`，逐条对照：

| 动作 | 期望结果 |
|---|---|
| 看状态栏语言模式 | `Arm Assembly`（不是 `Assembly` / `Plain Text`） |
| 助记符颜色 | `mov` / `adrp` / `msr` 有指令色，`x0` 有寄存器色，`__HEAD` 有宏色 |
| hover `adrp` | 「Form PC-relative address to 4KB page」+ Operands 列表 + developer.arm.com 链接 |
| hover `__HEAD` | 一个 `c` 代码块给出 `#define __HEAD` 原文 + 定义位置链接 + 「预处理后」的 ` .section ".head.text","ax"` |
| F12 点 `#include <linux/linkage.h>` | 跳到 `third_party/linux/include/linux/linkage.h` |
| F12 点 `SYM_CODE_START` | 跳到 `include/linux/linkage.h` 里 `#define SYM_CODE_START` 那一行 |
| 命令面板 `ASM Tools: Show Preprocessed Source` | 新开一个只读预览，按 `; >>> 文件:行` 分节展示预处理结果 |
| 输出面板选 `ASM Tools` | 有 `[cpp] head.S: <n> macros, <n> includes (...)` 之类的日志 |

x86 与 RISC-V 的 `.S` 走 asm-lsp：hover 也能出指令说明（`movq [x86]`、`addi [riscv]`），但没有 ArmLS 那种操作数级细节。

## 7. 排查表

| 现象 | 原因 | 处理 |
|---|---|---|
| hover 弹出 `No information available`（`-32803`） | 用的是上游客户端，错误没被吞 | 装本仓库 fork 的 1.0.2+ |
| `clangd: Restart language server` 报 `The "path" argument must be of type string` | 某个扩展在 `contributes.configurationDefaults` 里给**带点号的语言 id**（如 `[arm.aarch64-assembly]`）写了默认值，触发 VSCode 内部 `Object.keys(undefined)`，默认配置模型构建中断，`clangd.path` 等键永久缺失 | 已在本 fork 里移除；如果你自己改过 `package.json`，删掉 `configurationDefaults` 整段 |
| 完全没高亮，状态栏是 `Plain Text` | 扩展没装 / 语言模式没关联 | `code --list-extensions \| grep asm-lsp`；检查 `files.associations` |
| 满屏 `unrecognised instruction __HEAD` | ArmLS 诊断开着 | `"armls.diagnostics.enable": false` |
| 宏 hover / F12 没反应 | 缺 `compile_commands.json`，或该文件不在构建数据库里（没编译过） | 跑第 5 步；只对编过的 `.S` 生效 |
| 扩展启动报找不到服务器 | `asm-lsp` 不在 `~/.local/bin` 也不在 PATH | `install -m 0755 asm-lsp ~/.local/bin/`，或设置 `asmTools` 相关路径后重载 |
| 改了 `.asm-lsp.toml` 不生效 | 配置在启动时读取 | 重启扩展宿主（Reload Window），而不是只重开文件 |

## 8. 回退

```bash
code --uninstall-extension asm-lsp.asm-lsp
code --uninstall-extension Arm.armls
rm -f ~/.local/bin/asm-lsp .asm-lsp.toml
```

再把 `.vscode/settings.json` 里的 `files.associations`、`armls.*` 两块删掉即可，其余设置（clangd）不受影响。

## 9. 参考

- fork：<https://github.com/KB-125/asm-lsp>（分支 `kernel-asm-support`）
- 上游 asm-lsp：<https://github.com/bergercookie/asm-lsp>
- ArmLS：<https://github.com/arm/armls> ｜ 扩展：<https://marketplace.visualstudio.com/items?itemName=Arm.armls>
- 内核 `compile_commands.json` 目标：`Makefile` 里的 `compile_commands.json`（调 `scripts/clang-tools/gen_compile_commands.py`）
