#!/usr/bin/env bash
# Build the UI tests' registry: the real resid-json and resid-serial
# (signed), this package (unsigned), and made-up packages that give the
# pages something to show -- two versions of `web` whose README, grant,
# dependencies and files differ; `util`, which closes a cycle with web
# 1.1.0; and `orphan`, whose dependency is not published.
#
#   tests/fixture.sh <work-dir> <resid-pkg>   (writes <work-dir>/reg, k.sec, k.pub)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$1"; PKG="$2"; REG="$W/reg"; S="$W/src"
mkdir -p "$REG" "$S"
"$PKG" keygen "$W/k.sec" "$W/k.pub" > /dev/null
for p in "$ROOT/../resid-json" "$ROOT/../resid-serial"; do "$PKG" publish "$p" "$REG" "$W/k.sec" > /dev/null; done
"$PKG" publish "$ROOT" "$REG" > /dev/null

mk() { # mk <dir> <toml> <file>=<text>...
    local d="$S/$1"; shift; rm -rf "$d"; mkdir -p "$d/src"; printf '%b' "$1" > "$d/resid.toml"; shift
    for kv in "$@"; do mkdir -p "$(dirname "$d/${kv%%=*}")"; printf '%b' "${kv#*=}" > "$d/${kv%%=*}"; done
    "$PKG" publish "$d" "$REG" "$W/k.sec" > /dev/null
}
mk web1 '[package]\nname = "web"\nversion = "1.0.0"\ndescription = "A tiny web framework"\nlicense = "MIT"\nrepository = "https://example.org/web"\nkeywords = ["http", "server"]\n\n[capabilities]\ngrant = ["network(readonly)"]\n\n[dependencies.resid-json]\nversion = "0.1.0"\ncapabilities = []\n' \
    'README.md=# web\n\nA *tiny* framework. See [the licence](LICENSE).\n\n- routes\n- `json` replies\n\n```resid\nInt main() { return 0; }\n```\n<script>alert(1)</script>\n' \
    'LICENSE=MIT licence text\n' \
    'src/web.resid=// web\npub Int port() { return 8080; }\npub Str name() { return "web"; }\n' \
    'src/old.resid=pub Int old() { return 1; }\n'
mk util '[package]\nname = "util"\nversion = "0.1.0"\ndescription = "Helpers for web"\n\n[dependencies.web]\nversion = "1.1.0"\n' \
    'src/util.resid=pub Int two() { return 2; }\n'
mk web2 '[package]\nname = "web"\nversion = "1.1.0"\ndescription = "A tiny web framework"\nlicense = "MIT"\n\n[capabilities]\ngrant = ["network(readonly)", "filesystem"]\n\n[dependencies.resid-json]\nversion = "0.1.0"\ncapabilities = []\n\n[dependencies.util]\nversion = "0.1.0"\n' \
    'README.md=# web 1.1\n\nNow serves files.\n' \
    'LICENSE=MIT licence text\n' \
    'src/web.resid=// web\npub Int port() { return 8443; }\npub Str name() { return "web"; }\npub Bool files() { return true; }\n' \
    'src/files.resid=pub Str root() { return "."; }\n'
mk orphan '[package]\nname = "orphan"\nversion = "0.0.1"\n\n[dependencies.missing-pkg]\nversion = "9.9.9"\n' \
    'src/o.resid=pub Int o() { return 0; }\n'
