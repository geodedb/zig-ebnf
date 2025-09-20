# zig-ebnfgen (Zig 0.15.1)

A tiny EBNF-to-Zig code generator plus an AST interpreter/CLI. It parses an **EBNF** grammar and either:

- **recognizes** input strings with an in-process interpreter, or
- **generates** a self-contained Zig module with a **longest-match lexer** and **recursive-descent parser** (ordered choice, greedy repetition, backtracking with lookahead).

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

```bash
zig-ebnf generate  --in \<grammar.ebnf\> --out \<dir\> --start \<rule\> [--module-name \<name\>] [--permissive]
zig-ebnf recognize --grammar \<grammar.ebnf\> --start \<rule\> --input \<str\>
zig-ebnf version
```

- `generate`: validates grammar, emits Zig module files under `--out/<module-name>/`.
- `recognize`: runs an interpreter over the AST; on success prints

```text
ACCEPT <rule> "<input>"
```

on failure prints

```text
REJECT <rule> "<input>": <reason> @<index>
```

**Errors** (fail closed): `SyntaxError, UndefinedSymbol, DuplicateRule, LeftRecursion, EmptyRepetition, UnreachableRule, AmbiguousChoice, IoError`.

### Permissive Mode

Pass `--permissive` (or use `parseEbnfOpts(..., .{ .permissive = true })`) to relax the lexer for ingesting large / mixed‑dialect grammars:

- Falls back to treating otherwise unknown single characters as 1‑byte literal terminals.
- Accepts all‑uppercase identifiers (`FOO`), mirroring some external specs.
- Still performs duplicate / undefined symbol validation; i.e. structural correctness is enforced even when tokenization is lenient.

Use this only for bootstrapping foreign grammars; prefer strict mode for deterministic builds.

### Undefined Symbol Diagnostics with Spans

Early validation records up to 8 undefined nonterminal references together with their source spans (line/column). The CLI re‑parses after an `UndefinedSymbol` error to report a concise multi‑line diagnostic:

```text
Undefined symbols (first 8):
    missing_rule @ line X col Y
    other_missing @ line A col B
```

The span collection is O(refs) during parsing (no deep AST walk) by recording identifier occurrences inline.

### Memory Model & Allocation

- Expression graph (`Expr` nodes) lives in a single arena (`std.heap.ArenaAllocator`) owned by the AST.
- Rule array, literal value slices, and diagnostic arrays use the caller allocator directly.
- All literal terminal strings are owned by the AST and freed in `AST.deinit()`.
- Identifier occurrence table (for diagnostics) is arena‑allocated and thus bulk‑freed with the arena.

### Literal Interning / Deduplication

The lexer now interns literal value slices (non‑empty) to avoid allocating duplicate copies for repeated punctuation or short tokens. During tokenization only the first occurrence of a distinct literal is retained in the AST’s `literals` list; subsequent identical lexemes reuse the canonical slice. Benefits:

- Fewer heap allocations & frees for large grammars with many repeated operators.
- Smaller working set (unique literal storage only).
- No observable semantic change—slices remain immutable.

Interning deliberately skips the empty literal (`""`) which denotes the empty symbol.

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

- **Assignment**: `::=` (also accepts `⇐`)
- **Alternation**: `|`
- **Option**: `[ ... ]`
- **Repetition**: `{ ... }` (greedy; **reject** if body can match empty)
- **Sequence**: whitespace-separated
- **LHS names**: `[a-z][a-z0-9_]*`
- **Terminals**: `'...'` or `"..."`; escapes: `\\`, `\"`, `\'`, `\n`, `\r`, `\t`, `\xHH`
- **Empty**: `""` means the empty symbol
- **Comments**: `//` to EOL and `/* ... */` (nested ok)
- **Whitespace** ignored between tokens **unless** some terminal includes whitespace (then it’s tokenized)

### Semantics

- **Choice**: ordered (left-first)
- **Option**: try once; on failure succeed without consuming
- **Repetition**: greedy; must make progress; fails grammar validation if body can match empty
- **Left recursion**: detected (direct/indirect) and rejected at generation time
- **Lexer**: tokens derived from terminals; **longest-match**; breaks ties by first-seen terminal order; whitespace skipped unless explicitly tokenized

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

- No external deps; no path traversal: outputs restricted to `--out/<module-name>/`.
- Memory budget ~512 MiB. ~200-rule grammars parse <2s on typical x86_64.
- Deterministic codegen and stable token order.

---

## License

MIT
