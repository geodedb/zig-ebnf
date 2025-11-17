#!/usr/bin/env bash
# Install Zig 0.15.1 from official releases
set -euo pipefail

# Target Zig 0.15.1 - this project requires Zig 0.15+
ZIG_VERSION="${ZIG_VERSION:-0.15.1}"
INSTALL_DIR="${ZIG_INSTALL_DIR:-$HOME/.local}"

echo "Installing Zig ${ZIG_VERSION}..."

# Detect architecture
ARCH=$(uname -m)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

# Determine tarball name (Zig 0.14.0+ format: zig-<arch>-<os>-<version>)
case "$OS" in
    linux)
        case "$ARCH" in
            x86_64)
                ZIG_TARBALL="zig-${ARCH}-${OS}-${ZIG_VERSION}.tar.xz"
                ;;
            aarch64|arm64)
                ZIG_TARBALL="zig-aarch64-${OS}-${ZIG_VERSION}.tar.xz"
                ;;
            *)
                echo "Unsupported architecture: $ARCH"
                exit 1
                ;;
        esac
        ;;
    darwin)
        case "$ARCH" in
            x86_64)
                ZIG_TARBALL="zig-${ARCH}-macos-${ZIG_VERSION}.tar.xz"
                ;;
            arm64)
                ZIG_TARBALL="zig-aarch64-macos-${ZIG_VERSION}.tar.xz"
                ;;
            *)
                echo "Unsupported architecture: $ARCH"
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Unsupported OS: $OS"
        exit 1
        ;;
esac

ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"
TEMP_DIR=$(mktemp -d)

trap "rm -rf ${TEMP_DIR}" EXIT

echo "Downloading from ${ZIG_URL}..."
if command -v curl &> /dev/null; then
    curl -L -o "${TEMP_DIR}/${ZIG_TARBALL}" "${ZIG_URL}"
elif command -v wget &> /dev/null; then
    wget -O "${TEMP_DIR}/${ZIG_TARBALL}" "${ZIG_URL}"
else
    echo "Error: neither curl nor wget found. Please install one of them."
    exit 1
fi

echo "Extracting to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/lib"

# Extract the tarball
tar -xJf "${TEMP_DIR}/${ZIG_TARBALL}" -C "${TEMP_DIR}"

# Find the extracted directory
EXTRACTED_DIR=$(find "${TEMP_DIR}" -maxdepth 1 -type d -name "zig-*" | head -1)
if [ -z "${EXTRACTED_DIR}" ]; then
    echo "Error: Could not find extracted Zig directory"
    exit 1
fi

# Remove old Zig 0.15.x installations
rm -rf "${INSTALL_DIR}/lib/zig-"*-0.15.*

# Move extracted directory to lib
ZIG_BASENAME=$(basename "${EXTRACTED_DIR}")
mv "${EXTRACTED_DIR}" "${INSTALL_DIR}/lib/"
ZIG_DIR="${INSTALL_DIR}/lib/${ZIG_BASENAME}"

# Create symlink
mkdir -p "${INSTALL_DIR}/bin"
ln -sf "${ZIG_DIR}/zig" "${INSTALL_DIR}/bin/zig"

echo ""
echo "✓ Zig ${ZIG_VERSION} installed successfully!"
echo ""
echo "Add to your PATH:"
echo "  export PATH=\"${INSTALL_DIR}/bin:\$PATH\""
echo ""
echo "Or add to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
echo "  echo 'export PATH=\"${INSTALL_DIR}/bin:\$PATH\"' >> ~/.bashrc"
echo ""

# Verify installation
if "${INSTALL_DIR}/bin/zig" version &> /dev/null; then
    echo "Installed version:"
    "${INSTALL_DIR}/bin/zig" version
else
    echo "Warning: Installation may have issues. Please verify manually."
    exit 1
fi
