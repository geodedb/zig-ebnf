# Zig Version Compatibility

## Target Version

**This project targets Zig 0.15.1 exclusively.**

## Why Zig 0.15.1?

This codebase uses Zig 0.15.1 APIs including:

- `std.ArrayList(T).init(allocator)` initialization
- Modern method signatures without allocator parameters (`.append()`, `.toOwnedSlice()`, `.deinit()`)
- Updated file I/O APIs (simplified `.openFile()`)
- Current `std.process.argsAlloc()` API

## Breaking Changes from Earlier Versions

### Zig 0.13.0 → 0.15.1

**ArrayList API changes:**
```zig
// Zig 0.13.0 (old)
var list: std.ArrayList(T) = .{};
try list.append(allocator, item);
const slice = try list.toOwnedSlice(allocator);
list.deinit(allocator);

// Zig 0.15.1 (new)
var list = std.ArrayList(T).init(allocator);
try list.append(item);
const slice = try list.toOwnedSlice();
list.deinit();
```

**Process API changes:**
```zig
// Zig 0.13.0 (old)
const args = std.os.argv;

// Zig 0.15.1 (new)
const args = try std.process.argsAlloc(allocator);
defer std.process.argsFree(allocator, args);
```

**File I/O changes:**
```zig
// Zig 0.13.0 (old)
var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });

// Zig 0.15.1 (new)
var file = try std.fs.cwd().openFile(path, .{});
```

## System Requirements

Zig 0.15.1 requires:
- **Linux**: Kernel 5.0 or newer
- **macOS**: 11.0+ (Big Sur)
- **Windows**: Windows 10+

Older systems (Ubuntu 18.04, Debian 10, Linux kernel 4.x) cannot run Zig 0.15.1.

## Migration Notes

If you have code written for older Zig versions:

1. Update ArrayList initialization and method calls
2. Replace `std.os.argv` with `std.process.argsAlloc()`
3. Simplify file opening options
4. Ensure your system meets the kernel/OS requirements

## Testing Environment Limitations

**Known limitation**: This codebase cannot be tested on systems with Linux kernel < 5.0, as the Zig 0.15.1 compiler itself will not run. The code is correct for Zig 0.15.1, but testing must be performed on systems meeting the requirements above.

## References

- [Zig 0.15.1 Release Notes](https://ziglang.org/download/0.15.1/release-notes.html)
- [Zig Documentation 0.15.1](https://ziglang.org/documentation/0.15.1/)
- [Zig Standard Library API](https://ziglang.org/documentation/0.15.1/std/)
