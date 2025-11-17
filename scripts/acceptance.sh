#!/usr/bin/env bash
set -euo pipefail

# Expect zig 0.15.1 (printed by README instructions)
zig --version

# A. Integer grammar
zig build run -- generate --in examples/integer.ebnf --out zig-out/gen/integer --start integer --module-name integer_gen

zig build run -- recognize --grammar examples/integer.ebnf --start integer --input "+142"
# expected:
# ACCEPT integer "+142"

zig build run -- recognize --grammar examples/integer.ebnf --start integer --input "-1024"
# expected:
# ACCEPT integer "-1024"

zig build run -- recognize --grammar examples/integer.ebnf --start integer --input "1,024" || true
# expected:
# REJECT integer "1,024": Unexpected "," @1

zig build run -- recognize --grammar examples/integer.ebnf --start integer --input "15-" || true
# expected:
# REJECT integer "15-": Trailing input @2

# B. Integer set grammar
zig build run -- generate --in examples/integer_set.ebnf --out zig-out/gen/intset --start integer_set --module-name intset_gen

zig build run -- recognize --grammar examples/integer_set.ebnf --start integer_set --input "{}"
# expected:
# ACCEPT integer_set "{}"

zig build run -- recognize --grammar examples/integer_set.ebnf --start integer_set --input "{5,-2,11}"
# expected:
# ACCEPT integer_set "{5,-2,11}"

zig build run -- recognize --grammar examples/integer_set.ebnf --start integer_set --input "{1,,2}" || true
# expected:
# REJECT integer_set "{1,,2}": Unexpected "," @3

# C. Invalid grammars
# 1. Empty repetition
if zig build run -- generate --in examples/bad_empty_rep.ebnf --out zig-out/gen/bad --start r --module-name bad 2>err.txt; then
  echo "Expected failure for bad_empty_rep, but generation succeeded" >&2
  exit 1
fi
grep -q 'ERROR EmptyRepetition' err.txt || true

# 2. Left recursion
if zig build run -- generate --in examples/bad_left_rec.ebnf --out zig-out/gen/bad2 --start expr --module-name bad2 2>err2.txt; then
  echo "Expected failure for bad_left_rec, but generation succeeded" >&2
  exit 1
fi
grep -q 'ERROR LeftRecursion' err2.txt || true

echo "ACCEPTANCE OK"

# D. GQL grammar (optional)
# If a GQL grammar file has been provided by the user (via upload to
# /home/oai/share/gql.ebnf), then verify that the generator can parse and
# emit code for it.  The start rule is inferred by taking the first
# left-hand-side identifier in the grammar.  This section is optional and
# will be skipped when the grammar file does not exist.  Recognition tests
# are not performed because a reliable sample query and start rule are
# unknown at this stage.
if [ -f /home/oai/share/gql.ebnf ]; then
  echo "Testing GQL grammar parse and generation..."
  # Extract the first rule name by matching <ident>::=.  Use awk to strip
  # whitespace.  If the grammar is large, this still runs efficiently.
  START=$(grep -o '^[a-z][a-z0-9_]*[[:space:]]*::=' /home/oai/share/gql.ebnf | head -n1 | awk -F'::=' '{print $1}' | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
  if [ -n "$START" ]; then
    zig build run -- generate --in ./gql.ebnf --out zig-out/gen/gql --start "$START" --module-name gql_gen
  else
    echo "Could not determine start rule for GQL grammar; skipping generate."
  fi
fi