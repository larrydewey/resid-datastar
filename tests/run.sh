#!/usr/bin/env bash
# Run the tests: compile every golden program and compare its output and
# exit status with NAME.out, then serve tests/sdk_server.resid and drive it
# with Datastar's own SDK suite (tests/spec: curl, awk, sh), every case
# counted; last the registry UI (tests/ui.sh, and tests/browser.mjs when
# node and chromium are installed).
#
#   tests/run.sh            run everything
#   tests/run.sh --update   rewrite the .out files from the current output
#
# RESIDC picks the compiler (default: residc on PATH, else ~/.resid/bin/residc).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESIDC="${RESIDC:-$(command -v residc || echo "$HOME/.resid/bin/residc")}"
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; kill $(jobs -p) 2>/dev/null' EXIT
export RESID_MEM_LIMIT="${RESID_MEM_LIMIT:-6000}"

pass=0
fail=0

compile() { # compile <src> <out-bin>
    "$RESIDC" "$1" -o "$2" --profile debug > "$WORK/compile.log" 2>&1 || {
        grep -v '^OK \|^note:\|^typecheck OK\|^wrote ' "$WORK/compile.log" | head -20
        return 1
    }
}

# The embedded client must be the vendored bundle.
if python3 "$ROOT/tools/embed_client.py" > /dev/null && git -C "$ROOT" diff --quiet -- src/client.resid 2>/dev/null; then
    echo "PASS client embedding"; pass=$((pass + 1))
else
    echo "FAIL src/client.resid is stale: run tools/embed_client.py"; fail=$((fail + 1))
fi

for src in events signals stream; do
    want="$ROOT/tests/$src.out"
    bin="$WORK/$src"
    if ! compile "$ROOT/tests/$src.resid" "$bin"; then
        echo "FAIL $src (compile)"; fail=$((fail + 1)); continue
    fi
    timeout 60 "$bin" > "$WORK/got.txt" 2>&1
    echo "exit $?" >> "$WORK/got.txt"
    if [ "$UPDATE" = 1 ]; then
        cp "$WORK/got.txt" "$want"; echo "UPDATED $src"
    elif diff -u "$want" "$WORK/got.txt" > "$WORK/diff.txt"; then
        echo "PASS $src ($(grep -c '^ok' "$WORK/got.txt") checks)"; pass=$((pass + 1))
    else
        echo "FAIL $src"; head -40 "$WORK/diff.txt"; fail=$((fail + 1))
    fi
done

# The examples build.
for ex in "$ROOT"/examples/*.resid; do
    if compile "$ex" "$WORK/example"; then echo "PASS example $(basename "$ex")"; pass=$((pass + 1))
    else echo "FAIL example $(basename "$ex") (compile)"; fail=$((fail + 1)); fi
done

# Datastar's SDK suite against the test server.
if command -v curl > /dev/null && compile "$ROOT/tests/sdk_server.resid" "$WORK/sdk_server"; then
    "$WORK/sdk_server" --port-file "$WORK/port" > "$WORK/server.log" 2>&1 &
    for _ in $(seq 1 100); do [ -s "$WORK/port" ] && break; sleep 0.05; done
    URL="http://127.0.0.1:$(tr -d '\n' < "$WORK/port")"
    cp -r "$ROOT/tests/spec" "$WORK/spec"
    spass=0; sfail=0
    for kind in get post; do
        for case in "$WORK/spec/$kind-cases"/*/; do
            name="$kind/$(basename "$case")"
            if (cd "$WORK/spec" && sh "./test-$kind.sh" "$case" "$URL") > "$WORK/case.txt" 2>&1 && [ ! -s "$WORK/case.txt" ]; then
                spass=$((spass + 1))
            else
                echo "FAIL spec $name"; head -20 "$WORK/case.txt"; sfail=$((sfail + 1))
            fi
        done
    done
    if [ "$sfail" = 0 ]; then echo "PASS spec ($spass cases)"; pass=$((pass + 1)); else fail=$((fail + 1)); fi
else
    echo "FAIL spec (no curl, or sdk_server did not compile)"; fail=$((fail + 1))
fi

# The registry UI, against a registry resid-pkg (from the resid checkout
# beside this one, or RESID_SRC) builds.
RESID_SRC="${RESID_SRC:-$ROOT/../resid}"
if [ -f "$RESID_SRC/tools/resid-pkg.resid" ] && command -v curl > /dev/null \
    && compile "$ROOT/ui/registry.resid" "$WORK/registry-ui" && compile "$RESID_SRC/tools/resid-pkg.resid" "$WORK/resid-pkg"; then
    mkdir -p "$WORK/ui"
    if "$ROOT/tests/ui.sh" "$WORK/ui" "$WORK/registry-ui" "$WORK/resid-pkg" > "$WORK/ui.out" 2>&1; then
        echo "PASS ui ($(grep -c '^ok' "$WORK/ui.out") checks)"; pass=$((pass + 1))
    else
        echo "FAIL ui"; grep -v '^ok' "$WORK/ui.out" | head -40; fail=$((fail + 1))
    fi
else
    echo "FAIL ui (no curl, no $RESID_SRC/tools/resid-pkg.resid, or a compile failed)"; fail=$((fail + 1))
fi

[ "$UPDATE" = 1 ] && exit 0
echo "---"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
