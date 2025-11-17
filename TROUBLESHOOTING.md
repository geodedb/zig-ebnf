# Troubleshooting Guide

## Requirements

**This project requires Zig 0.15.1**

### System Requirements

Zig 0.15.1 requires:
- **Linux**: Kernel 5.0 or newer
- **macOS**: macOS 11.0 (Big Sur) or newer
- **Windows**: Windows 10 or newer

### Kernel Version Issues

**Symptom:**
```
thread XXXX panic: TODO
Unable to dump stack trace: debug info stripped
Aborted
```

**Cause:**
Zig 0.15.1 requires a modern Linux kernel (5.0+). On older kernels (e.g., 4.4.0), the compiler will panic.

**Solution:**

1. **Check your kernel version:**
   ```bash
   uname -r
   ```

2. **If kernel < 5.0, upgrade your system:**
   - **Ubuntu/Debian**: Upgrade to Ubuntu 20.04+ or Debian 11+
   - **Docker**: Use a container with a modern base image (e.g., `ubuntu:22.04`)
   - **VM/Cloud**: Use a modern OS image

3. **Alternative: Use Docker**
   ```dockerfile
   FROM ubuntu:24.04
   RUN apt-get update && apt-get install -y curl xz-utils
   COPY scripts/install-zig.sh /tmp/
   RUN bash /tmp/install-zig.sh
   ENV PATH="/root/.local/bin:$PATH"
   ```

## Installation Issues

### Zig Not Found

```bash
# Ensure PATH is set:
export PATH="$HOME/.local/bin:$PATH"

# Add to ~/.bashrc or ~/.zshrc:
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Permission Denied

```bash
# Installation scripts need execute permission:
chmod +x scripts/*.sh
```

### Download Failures

If downloads fail, you can manually download from:
https://ziglang.org/download/0.15.1/

Then extract to `$HOME/.local/lib/` and create a symlink:
```bash
ln -s $HOME/.local/lib/zig-*/zig $HOME/.local/bin/zig
```

## Build Issues

### Clean Rebuild

```bash
rm -rf zig-cache zig-out ~/.cache/zig
zig build
```

### Verbose Build Output

```bash
zig build --verbose
```

### Build Cache Corruption

```bash
# Clear all Zig caches:
rm -rf zig-cache zig-out ~/.cache/zig
zig build
```

## Testing Issues

### Unit Tests Failing

```bash
# Run with verbose output:
zig build test --summary all

# Run specific test:
zig test src/lib.zig
```

### Acceptance Tests Failing

```bash
# Make script executable:
chmod +x scripts/acceptance.sh

# Run with verbose output:
bash -x scripts/acceptance.sh
```

## Code Generation Issues

### Generated Code Won't Compile

**Verify grammar:**
```bash
zig build run -- recognize --grammar examples/integer.ebnf --start integer --input "123"
```

**Check generated files:**
```bash
ls -la zig-out/gen/*/
cat zig-out/gen/*/mod.zig
```

## Platform-Specific Issues

### macOS

- Ensure Xcode Command Line Tools are installed: `xcode-select --install`
- On Apple Silicon, the script automatically downloads ARM64 binaries
- Minimum macOS version: 11.0 (Big Sur)

### WSL/Windows

- Use WSL2 with Ubuntu 20.04+ for best compatibility
- Ensure WSL kernel is updated: `wsl --update`
- Check kernel version: `uname -r` (should be 5.0+)

### Linux

- Kernel must be 5.0 or newer
- Common on Ubuntu 20.04+, Debian 11+, RHEL 8+, Fedora 30+
- Older distributions (Ubuntu 18.04, Debian 10, etc.) are not supported

## Getting Help

1. Check [Zig 0.15.1 Release Notes](https://ziglang.org/download/0.15.1/release-notes.html)
2. Review [Zig Documentation](https://ziglang.org/documentation/0.15.1/)
3. Check [Zig GitHub Issues](https://github.com/ziglang/zig/issues)
4. Project issues: [spyderorg/ebnf](https://github.com/spyderorg/ebnf/issues)
