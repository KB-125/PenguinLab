#!/bin/bash
#=============================================================================
# VSCode Assembly Editing Setup
#=============================================================================
# Installs the pieces needed to read Linux kernel assembly in VSCode:
#
#   1. asm-lsp server  - Rust binary, prebuilt release asset (no Rust needed)
#   2. asm-lsp client  - our fork: grammar + CPP layer + -32803 fix
#   3. Arm.armls       - AArch64 instruction/operand hover (optional)
#   4. clangd          - C/C++ jump and completion (optional)
#
# After running this once, Reload Window and open e.g.
# third_party/linux/arch/arm64/kernel/head.S.
#
# Usage:
#   ./scripts/setup-vscode-asm.sh [command]
#
# Commands:
#   install   - Install/update server and extensions (default)
#   check     - Report what is present/missing, change nothing
#   help      - Show this help message
#
# Environment Variables:
#   ASM_LSP_VERSION - Server version (default: 0.10.1)
#   FORK_REPO       - Client fork (default: https://github.com/KB-125/asm-lsp.git)
#   FORK_BRANCH     - Client branch (default: kernel-asm-support)
#   SRC_DIR         - Where the fork is cloned (default: ~/tools/asm-lsp-src)
#   SERVER_DIR      - Where the server binary goes (default: ~/.local/bin)
#   CODE_BIN        - VSCode CLI (default: code)
#   SKIP_ARMLS      - 1 to skip Arm.armls
#   SKIP_CLANGD     - 1 to skip clangd
#   FORCE           - 1 to re-download/reinstall even if up to date
#=============================================================================

set -euo pipefail

#-----------------------------------------------------------------------------
# Color output
#-----------------------------------------------------------------------------
if [ -t 1 ]; then
    COLOR_RESET='\033[0m'
    COLOR_RED='\033[0;31m'
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[0;33m'
    COLOR_BLUE='\033[0;34m'
    COLOR_CYAN='\033[0;36m'
else
    COLOR_RESET=''
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_BLUE=''
    COLOR_CYAN=''
fi

#-----------------------------------------------------------------------------
# Logging functions
#-----------------------------------------------------------------------------
log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_cmd() {
    echo -e "${COLOR_CYAN}[CMD]${COLOR_RESET} $*"
}

#-----------------------------------------------------------------------------
# Defaults
#-----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ASM_LSP_VERSION="${ASM_LSP_VERSION:-0.10.1}"
FORK_REPO="${FORK_REPO:-https://github.com/KB-125/asm-lsp.git}"
FORK_BRANCH="${FORK_BRANCH:-kernel-asm-support}"
SRC_DIR="${SRC_DIR:-${HOME}/tools/asm-lsp-src}"
SERVER_DIR="${SERVER_DIR:-${HOME}/.local/bin}"
CODE_BIN="${CODE_BIN:-code}"
SKIP_ARMLS="${SKIP_ARMLS:-0}"
SKIP_CLANGD="${SKIP_CLANGD:-0}"
FORCE="${FORCE:-0}"

CLIENT_EXT_ID="asm-lsp.asm-lsp"
ARMLS_EXT_ID="Arm.armls"
CLANGD_EXT_ID="llvm-vs-code-extensions.vscode-clangd"

#-----------------------------------------------------------------------------
# Helpers
#-----------------------------------------------------------------------------
have() {
    command -v "$1" >/dev/null 2>&1
}

installed_extension_version() {
    "${CODE_BIN}" --list-extensions --show-versions 2>/dev/null \
        | grep -i "^$1@" | head -n1 | cut -d@ -f2 || true
}

server_version() {
    local bin="${SERVER_DIR}/asm-lsp"
    [ -x "${bin}" ] || return 1
    "${bin}" version 2>/dev/null | head -n1 | awk '{print $NF}'
}

source_client_version() {
    local pkg="${SRC_DIR}/editors/code/package.json"
    [ -f "${pkg}" ] || return 1
    node -p "require('${pkg}').version" 2>/dev/null
}

check_prerequisites() {
    local missing=0

    case "$(uname -m)" in
        x86_64) ;;
        *)
            log_error "Prebuilt asm-lsp server is x86_64 only (host is $(uname -m))."
            log_error "Build from source instead: https://github.com/bergercookie/asm-lsp#installation"
            return 1
            ;;
    esac

    if ! have "${CODE_BIN}"; then
        log_error "VSCode CLI '${CODE_BIN}' not found."
        log_error "Open the project in VSCode via Remote-WSL once, or set CODE_BIN=/path/to/code."
        missing=1
    fi

    for tool in git curl tar; do
        if ! have "${tool}"; then
            log_error "Missing tool: ${tool} (sudo apt install ${tool})"
            missing=1
        fi
    done

    [ "${missing}" -eq 0 ]
}

check_node() {
    if ! have node || ! have npm; then
        log_error "node/npm not found (needed once to package the client extension)."
        log_error "Install with: sudo apt install nodejs npm   # or use nvm"
        return 1
    fi
    local major
    major="$(node -p 'process.versions.node.split(".")[0]')"
    if [ "${major}" -lt 18 ]; then
        log_warn "node $(node -v) is older than 18; 18+ is recommended."
    fi
}

#-----------------------------------------------------------------------------
# Steps
#-----------------------------------------------------------------------------
install_server() {
    local current
    current="$(server_version || true)"

    if [ -n "${current}" ] && [ "${FORCE}" != "1" ]; then
        log_info "asm-lsp server already installed: ${SERVER_DIR}/asm-lsp (${current})"
        if [ "${current}" != "${ASM_LSP_VERSION}" ]; then
            log_warn "Expected ${ASM_LSP_VERSION}; re-run with FORCE=1 to update."
        fi
        return 0
    fi

    local url="https://github.com/bergercookie/asm-lsp/releases/download/v${ASM_LSP_VERSION}/asm-lsp-x86_64-unknown-linux-gnu.tar.gz"
    local tmp
    tmp="$(mktemp -d)"

    log_cmd "curl -fsSL ${url}"
    if ! curl -fsSL -o "${tmp}/asm-lsp.tar.gz" "${url}"; then
        rm -rf "${tmp}"
        log_error "Download failed: ${url}"
        return 1
    fi

    log_cmd "tar -xzf asm-lsp.tar.gz -C ${tmp} asm-lsp"
    if ! tar -xzf "${tmp}/asm-lsp.tar.gz" -C "${tmp}" asm-lsp; then
        rm -rf "${tmp}"
        log_error "Unexpected archive layout; expected a single 'asm-lsp' binary."
        return 1
    fi

    mkdir -p "${SERVER_DIR}"
    install -m 0755 "${tmp}/asm-lsp" "${SERVER_DIR}/asm-lsp"
    rm -rf "${tmp}"

    log_success "Installed $("${SERVER_DIR}/asm-lsp" version | head -n1) -> ${SERVER_DIR}/asm-lsp"

    case ":${PATH}:" in
        *":${SERVER_DIR}:"*) ;;
        *) log_warn "${SERVER_DIR} is not in PATH; the extension probes it directly, but add it for CLI use." ;;
    esac
}

install_client() {
    local current_src current_installed

    current_src="$(source_client_version || true)"
    current_installed="$(installed_extension_version "${CLIENT_EXT_ID}")"

    if [ -n "${current_src}" ] && [ "${current_src}" = "${current_installed}" ] && [ "${FORCE}" != "1" ]; then
        log_info "Client extension up to date: ${CLIENT_EXT_ID}@${current_installed} (source ${SRC_DIR})"
        return 0
    fi

    check_node

    if [ -d "${SRC_DIR}/.git" ]; then
        log_cmd "git -C ${SRC_DIR} fetch --depth 1 ${FORK_REPO} ${FORK_BRANCH}"
        git -C "${SRC_DIR}" fetch -q --depth 1 "${FORK_REPO}" "${FORK_BRANCH}"
        git -C "${SRC_DIR}" checkout -q --detach FETCH_HEAD
    else
        log_cmd "git clone -b ${FORK_BRANCH} --depth 1 ${FORK_REPO} ${SRC_DIR}"
        mkdir -p "$(dirname "${SRC_DIR}")"
        git clone -q -b "${FORK_BRANCH}" --depth 1 "${FORK_REPO}" "${SRC_DIR}"
    fi

    local want
    want="$(source_client_version)"
    if [ "${want}" = "${current_installed}" ] && [ "${FORCE}" != "1" ]; then
        log_info "Client extension already at ${want}; nothing to install"
        return 0
    fi

    pushd "${SRC_DIR}/editors/code" >/dev/null

    if [ ! -d node_modules ] || [ "${FORCE}" = "1" ]; then
        log_cmd "npm ci"
        npm ci --no-audit --no-fund --silent
    fi

    log_cmd "npm run package"
    npm run --silent package

    log_cmd "${CODE_BIN} --install-extension asm-lsp.vsix --force"
    "${CODE_BIN}" --install-extension asm-lsp.vsix --force >/dev/null

    popd >/dev/null

    log_success "Installed ${CLIENT_EXT_ID}@${want} from ${SRC_DIR}"
}

install_optional() {
    local id="$1" name="$2" current

    current="$(installed_extension_version "${id}")"
    if [ -n "${current}" ]; then
        log_info "${name} already installed: ${id}@${current}"
        return 0
    fi

    log_cmd "${CODE_BIN} --install-extension ${id}"
    if "${CODE_BIN}" --install-extension "${id}" >/dev/null 2>&1; then
        log_success "Installed ${name}: ${id}@$(installed_extension_version "${id}")"
    else
        log_warn "Could not install ${name} (${id}); install it from the marketplace manually."
    fi
}

report_project_files() {
    if [ -f "${PROJECT_ROOT}/.asm-lsp.toml" ]; then
        log_info "Config: .asm-lsp.toml present"
    else
        log_warn "Config: .asm-lsp.toml missing (asm-lsp falls back to its defaults)"
    fi

    if [ -f "${PROJECT_ROOT}/.vscode/settings.json" ]; then
        log_info "Config: .vscode/settings.json present"
    else
        log_warn "Config: .vscode/settings.json missing (no files.associations / armls.*)"
    fi

    if [ -f "${PROJECT_ROOT}/out/build_latest_arm64/compile_commands.json" ]; then
        log_info "Data: compile_commands.json present (macro/include layer enabled)"
    else
        log_warn "Data: out/build_latest_arm64/compile_commands.json missing; run:"
        log_warn "      make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=out/build_latest_arm64 compile_commands.json"
    fi
}

#-----------------------------------------------------------------------------
# Commands
#-----------------------------------------------------------------------------
cmd_install() {
    log_info "=== VSCode assembly setup ==="
    log_info "asm-lsp server:  ${ASM_LSP_VERSION} (${SERVER_DIR})"
    log_info "asm-lsp client:  ${FORK_REPO} #${FORK_BRANCH}"
    log_info "VSCode CLI:      $(command -v "${CODE_BIN}" 2>/dev/null || echo "${CODE_BIN}")"

    check_prerequisites || exit 1

    install_server
    install_client

    [ "${SKIP_ARMLS}" = "1" ] || install_optional "${ARMLS_EXT_ID}" "ArmLS"
    [ "${SKIP_CLANGD}" = "1" ] || install_optional "${CLANGD_EXT_ID}" "clangd"

    report_project_files

    echo
    log_success "Done. Reload Window in VSCode, then open"
    log_success "third_party/linux/arch/arm64/kernel/head.S and hover 'adrp' / '__HEAD'."
    log_info "Reference: document/guides/06-vscode-asm.md"
}

cmd_check() {
    local failures=0
    local current_server current_client current_armls

    echo "=== VSCode assembly setup status ==="

    if have "${CODE_BIN}"; then
        log_success "code CLI: $(command -v "${CODE_BIN}")"
    else
        log_error "code CLI: not found (Remote-WSL not connected yet?)"
        failures=$((failures + 1))
    fi

    if have node && have npm; then
        log_success "node: $(node -v), npm: $(npm -v)"
    else
        log_warn "node/npm: missing (only needed to build the client extension)"
    fi

    current_server="$(server_version || true)"
    if [ -n "${current_server}" ]; then
        log_success "asm-lsp server: ${SERVER_DIR}/asm-lsp (${current_server})"
    else
        log_error "asm-lsp server: not installed in ${SERVER_DIR}"
        failures=$((failures + 1))
    fi

    current_client="$(installed_extension_version "${CLIENT_EXT_ID}")"
    if [ -n "${current_client}" ]; then
        log_success "client extension: ${CLIENT_EXT_ID}@${current_client}"
    else
        log_error "client extension: ${CLIENT_EXT_ID} not installed"
        failures=$((failures + 1))
    fi

    current_armls="$(installed_extension_version "${ARMLS_EXT_ID}")"
    if [ -n "${current_armls}" ]; then
        log_success "ArmLS: ${ARMLS_EXT_ID}@${current_armls}"
    else
        log_warn "ArmLS: not installed (arm64 instruction hover falls back to asm-lsp)"
    fi

    if [ -n "$(installed_extension_version "${CLANGD_EXT_ID}")" ]; then
        log_success "clangd: ${CLANGD_EXT_ID}@$(installed_extension_version "${CLANGD_EXT_ID}")"
    else
        log_warn "clangd: not installed (C/C++ jump and completion will be missing)"
    fi

    if [ -d "${SRC_DIR}/.git" ]; then
        log_success "client source: ${SRC_DIR} ($(git -C "${SRC_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?'))"
    else
        log_warn "client source: ${SRC_DIR} not cloned"
    fi

    report_project_files

    echo
    if [ "${failures}" -eq 0 ]; then
        log_success "All required pieces are in place."
    else
        log_error "${failures} required piece(s) missing; run: ./scripts/setup-vscode-asm.sh install"
        return 1
    fi
}

cmd_help() {
    cat <<'EOF'
VSCode assembly editing setup

Usage:
  ./scripts/setup-vscode-asm.sh [command]

Commands:
  install   Install/update asm-lsp server, client extension, ArmLS, clangd (default)
  check     Report what is present/missing, change nothing
  help      Show this help message

Environment variables:
  ASM_LSP_VERSION  Server version (default: 0.10.1)
  FORK_REPO        Client fork (default: https://github.com/KB-125/asm-lsp.git)
  FORK_BRANCH      Client branch (default: kernel-asm-support)
  SRC_DIR          Where the fork is cloned (default: ~/tools/asm-lsp-src)
  SERVER_DIR       Where the server binary goes (default: ~/.local/bin)
  CODE_BIN         VSCode CLI (default: code)
  SKIP_ARMLS=1     Do not install Arm.armls
  SKIP_CLANGD=1    Do not install clangd
  FORCE=1          Re-download/reinstall even if up to date

Docs: document/guides/06-vscode-asm.md
EOF
}

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------
COMMAND="${1:-install}"

case "${COMMAND}" in
    install) cmd_install ;;
    check|--check) cmd_check ;;
    help|-h|--help) cmd_help ;;
    *)
        log_error "Unknown command: ${COMMAND}"
        echo "Usage: $0 [install|check|help]" >&2
        exit 1
        ;;
esac
