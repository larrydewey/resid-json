#!/usr/bin/env bash
# Run the tests: build resid-derive from ../resid-serial, regenerate the
# derive model, then compile every test program and compare its output and
# exit status with the golden NAME.out beside it.
#
#   tests/run.sh            run everything
#   tests/run.sh --update   rewrite the .out files from the current output
#
# RESIDC picks the compiler (default: residc on PATH, else ~/.resid/bin/residc).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESIDC="${RESIDC:-$(command -v residc || echo "$HOME/.resid/bin/residc")}"
# resid-manifest writes the dependency map that `import "pkg/m.resid"` reads.
MANIFEST="${MANIFEST:-$(command -v resid-manifest || echo "$HOME/.resid/bin/resid-manifest")}"
SERIAL="${SERIAL:-$ROOT/../resid-serial}"
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$MANIFEST" depmap "$ROOT/resid.toml" "$WORK/depmap" > "$WORK/depmap.log" 2>&1 || {
    cat "$WORK/depmap.log"; echo "FAIL resid-manifest depmap"; exit 1;
}
export RESID_MEM_LIMIT="${RESID_MEM_LIMIT:-6000}"

pass=0
fail=0

compile() { # compile <src> <out-bin>
    "$RESIDC" "$1" -o "$2" --profile debug -depmap "$WORK/depmap" > "$WORK/compile.log" 2>&1 || {
        grep -v '^OK \|^note:\|^typecheck OK\|^wrote ' "$WORK/compile.log" | head -20
        return 1
    }
}

# The derive tool and the instances the derive test needs.
compile "$SERIAL/tools/resid-derive.resid" "$WORK/resid-derive" || { echo "FAIL build resid-derive"; exit 1; }
( cd "$ROOT/tests" && "$WORK/resid-derive" --lib resid-serial model.resid > /dev/null ) || {
    echo "FAIL resid-derive on tests/model.resid"; exit 1;
}

for src in vectors roundtrip text errors value derive; do
    want="$ROOT/tests/$src.out"
    bin="$WORK/$src"
    if ! compile "$ROOT/tests/$src.resid" "$bin"; then
        echo "FAIL $src (compile)"
        fail=$((fail + 1))
        continue
    fi
    # The exit status is part of the output, so a crash cannot pass.
    "$bin" > "$WORK/got.txt" 2>&1
    echo "exit $?" >> "$WORK/got.txt"
    if [ "$UPDATE" = 1 ]; then
        cp "$WORK/got.txt" "$want"
        echo "UPDATED $src"
    elif diff -u "$want" "$WORK/got.txt" > "$WORK/diff.txt"; then
        n=$(grep -c '^ok' "$WORK/got.txt")
        echo "PASS $src ($n checks)"
        pass=$((pass + 1))
    else
        echo "FAIL $src"
        head -40 "$WORK/diff.txt"
        fail=$((fail + 1))
    fi
done

[ "$UPDATE" = 1 ] && exit 0
echo "---"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]