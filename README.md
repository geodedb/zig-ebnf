# zig-ebnfgen (Zig 0.15.1)

A tiny EBNF-to-Zig code generator plus an AST interpreter/CLI. It parses an **EBNF** grammar and either:

* **recognizes** input strings with an in-process interpreter, or
* **generates** a self-contained Zig module with a **longest-match lexer** and **recursive-descent parser** (ordered choice, greedy repetition, backtracking with lookahead).

The dialect follows the four control forms (sequence, choice, option, repetition) and the `::=` assignment per the reference chapter’s **Table 1.1** and examples (`digit`, `integer`, `integer set`). [Source: Chapter “EBNF: A Notation to Describe Syntax”.]

---

## Install & Build

```bash
zig version              # must print 0.15.1
zig build test           # run unit tests
./scripts/acceptance.sh  # run black-box CLI acceptance tests
```

---

## CLI

```
zig-ebnf generate  --in <grammar.ebnf> --out <dir> --start <rule> [--module-name <name>]
zig-ebnf recognize --grammar <grammar.ebnf> --start <rule> --input <str>
zig-ebnf version
```

* `generate`: validates grammar, emits Zig module files under `--out/<module-name>/`.
* `recognize`: runs an interpreter over the AST; on success prints

  ```
  ACCEPT <rule> "<input>"
  ```

  on failure prints

  ```
  REJECT <rule> "<input>": <reason> @<index>
  ```

**Errors** (fail closed): `SyntaxError, UndefinedSymbol, DuplicateRule, LeftRecursion, EmptyRepetition, UnreachableRule, AmbiguousChoice, IoError`.

---

## Library API

```zig
pub const Error = error{
    SyntaxError, UndefinedSymbol, DuplicateRule, LeftRecursion,
    EmptyRepetition, UnreachableRule, AmbiguousChoice, IoError,
};

pub const GenBackend = enum { RecursiveDescent };
pub const GenOptions = struct {
    backend: GenBackend = .RecursiveDescent,
    module_name: []const u8 = "generated",
    start_rule: []const u8, // required
    emit_cli_demo: bool = false,
};

pub const Generated = struct {
    files: []const GeneratedFile,
};
pub const GeneratedFile = struct {
    path: []const u8,
    contents: []const u8,
};

pub fn parseEbnf(alloc: std.mem.Allocator, src: []const u8) !AST;
pub fn generateZig(alloc: std.mem.Allocator, ast: *const AST, opts: GenOptions) !Generated;
```

---

## EBNF Dialect

* **Assignment**: `::=` (also accepts `⇐`)
* **Alternation**: `|`
* **Option**: `[ ... ]`
* **Repetition**: `{ ... }` (greedy; **reject** if body can match empty)
* **Sequence**: whitespace-separated
* **LHS names**: `[a-z][a-z0-9_]*`
* **Terminals**: `'...'` or `"..."`; escapes: `\\`, `\"`, `\'`, `\n`, `\r`, `\t`, `\xHH`
* **Empty**: `""` means the empty symbol
* **Comments**: `//` to EOL and `/* ... */` (nested ok)
* **Whitespace** ignored between tokens **unless** some terminal includes whitespace (then it’s tokenized)

**Semantics**

* **Choice**: ordered (left-first)
* **Option**: try once; on failure succeed without consuming
* **Repetition**: greedy; must make progress; fails grammar validation if body can match empty
* **Left recursion**: detected (direct/indirect) and rejected at generation time
* **Lexer**: tokens derived from terminals; **longest-match**; breaks ties by first-seen terminal order; whitespace skipped unless explicitly tokenized

---

## Examples

See `examples/integer.ebnf` and `examples/integer_set.ebnf`. Try:

```bash
zig build run -- generate --in examples/integer.ebnf --out zig-out/gen/integer --start integer --module-name integer_gen

zig build run -- recognize --grammar examples/integer.ebnf --start integer --input "+142"
# ACCEPT integer "+142"
```

---

## Security & Limits

* No external deps; no path traversal: outputs restricted to `--out/<module-name>/`.
* Memory budget ~512 MiB. ~200-rule grammars parse <2s on typical x86\_64.
* Deterministic codegen and stable token order.

---

## License

MIT