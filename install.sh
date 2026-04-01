#!/usr/bin/env sh
# Build and install RTK from the current repository checkout.
# Usage: ./install.sh [install-dir]

set -eu

BINARY_NAME="rtk"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTALL_DIR="${RTK_INSTALL_DIR:-${1:-$HOME/.local/bin}}"
BINARY_PATH="${SCRIPT_DIR}/target/release/${BINARY_NAME}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
    exit 1
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "Missing required command: $1"
    fi
}

verify_checkout() {
    if [ ! -f "${SCRIPT_DIR}/Cargo.toml" ] || [ ! -d "${SCRIPT_DIR}/src" ]; then
        error "Run this script from the RTK repository checkout."
    fi
}

build() {
    require_cmd cargo
    info "Building ${BINARY_NAME} from local source with cargo..."
    (
        cd "$SCRIPT_DIR"
        cargo build --release
    )
    if [ ! -x "$BINARY_PATH" ]; then
        error "Build finished but ${BINARY_PATH} was not created"
    fi
}

install_binary() {
    mkdir -p "$INSTALL_DIR"
    install -m 755 "$BINARY_PATH" "${INSTALL_DIR}/${BINARY_NAME}"
    info "Installed ${BINARY_NAME} to ${INSTALL_DIR}/${BINARY_NAME}"
}

# Verify installation
verify() {
    info "Verification: $("${INSTALL_DIR}/${BINARY_NAME}" --version)"
    case ":$PATH:" in
        *":$INSTALL_DIR:"*) ;;
        *)
            warn "Binary installed but ${INSTALL_DIR} is not in PATH. Add to your shell profile:"
            warn "  export PATH=\"${INSTALL_DIR}:\$PATH\""
            ;;
    esac
}

main() {
    info "Installing ${BINARY_NAME} from the current RTK source checkout..."
    info "No prebuilt binaries are downloaded by this installer."

    verify_checkout
    build
    install_binary
    verify

    echo ""
    info "Installation complete! Run '$BINARY_NAME --help' to get started."
}

main
