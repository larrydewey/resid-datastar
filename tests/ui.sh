#!/usr/bin/env bash
# The registry UI against a registry built here: pages, search, the
# version detail with its checks, files, downloads, refusals, and what a
# tampered archive and a wrong key look like. Then, when node and
# chromium are installed, the same UI in a browser (tests/browser.mjs).
#
#   tests/ui.sh <work-dir> <resid-registry-ui> <resid-pkg>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$1"; UI="$2"; PKG="$3"
pass=0; fail=0
ok() { echo "ok $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
has() { if grep -q -- "$2" "$W/got"; then ok "$1"; else bad "$1: no '$2'"; head -c 400 "$W/got"; echo; fi; }
get() { curl -s -o "$W/got" -w "%{http_code}" "$URL$1"; }

REG="$W/reg"; mkdir -p "$REG"
"$PKG" keygen "$W/k.sec" "$W/k.pub" > /dev/null
for p in "$ROOT/../resid-json" "$ROOT/../resid-serial"; do "$PKG" publish "$p" "$REG" "$W/k.sec" > /dev/null; done
"$PKG" publish "$ROOT" "$REG" > /dev/null    # unsigned, not in the index
mkdir -p "$W/new"; printf '[package]\nname = "fresh-pkg"\nversion = "1.0.0"\n' > "$W/new/resid.toml"
echo 'pub Int one() { return 1; }' > "$W/new/one.resid"

start() { # start <port-file> <args...>
    local pf="$1"; shift
    "$UI" "$REG" --port 0 --port-file "$pf" --poll-ms 100 "$@" > "$W/ui.log" 2>&1 &
    for _ in $(seq 1 100); do [ -s "$pf" ] && break; sleep 0.05; done
    URL="http://127.0.0.1:$(tr -d '\n' < "$pf")"
}

start "$W/port" --pubkey "$(cat "$W/k.pub")"
UIPID=$!
[ "$(get /)" = 200 ] && ok "home 200" || bad "home"
has "home lists json" 'href="/pkg/resid-json"'
has "home index verified" "index verified"
has "home unlisted badge" "not in index"
has "home client tag" 'src="/datastar@1.0.4.js"'
has "home live stream" "@get('/ui/live/home')"
get "/ui/search?datastar=%7B%22q%22%3A%22SERIAL%22%7D" > /dev/null
has "search event" "event: datastar-patch-elements"
if grep -q "resid-json" "$W/got"; then bad "search filters"; else ok "search filters"; fi
get "/ui/search?datastar=%7B%22q%22%3A%22%3Cb%3E%22%7D" > /dev/null
has "search escapes the query" "“&lt;b&gt;”"
[ "$(get /pkg/resid-serial)" = 200 ] && ok "package 200" || bad "package"
has "package loads its newest" "@get('/ui/version/resid-serial/0.1.0')"
get /ui/version/resid-json/0.1.0 > /dev/null
has "version hash" "hash matches"
has "version signature" "signature verified"
has "version manifest" 'name = &quot;resid-json&quot;\|name = "resid-json"'
get /ui/version/resid-datastar/0.1.0 > /dev/null
has "unsigned version" "unsigned"
get /ui/file/resid-json/0.1.0/src/lex.resid > /dev/null
has "file view" "<code>src/lex.resid</code>"
[ "$(get /download/resid-json/0.1.0)" = 200 ] && cmp -s "$W/got" "$REG/pkg/resid-json-0.1.0.resid-pkg" && ok "download bytes" || bad "download bytes"
[ "$(get /pkg/nope)" = 404 ] && ok "unknown package 404" || bad "unknown package"
[ "$(get '/pkg/..%2F..%2Fetc')" = 404 ] && ok "traversal 404" || bad "traversal"
[ "$(get '/download/..%2F..%2Fx/1')" = 404 ] && ok "download traversal 404" || bad "download traversal"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/")" = 405 ] && ok "post refused" || bad "post refused"
[ "$(get /datastar@1.0.4.js)" = 200 ] && [ "$(sha256sum < "$W/got" | cut -c1-64)" = "$(sha256sum < "$ROOT/assets/datastar.js" | cut -c1-64)" ] && ok "client bytes" || bad "client bytes"

# The live stream: a publish moves the fingerprint and a pulse goes out.
curl -sN "$URL/ui/live/home" > "$W/live" &
CURLPID=$!
sleep 0.4; "$PKG" publish "$W/new" "$REG" "$W/k.sec" > /dev/null; sleep 0.6
kill $CURLPID 2>/dev/null; wait $CURLPID 2>/dev/null
grep -q "data-init=\"@get('/ui/search')\"" "$W/live" && ok "live pulse" || { bad "live pulse"; cat "$W/live"; }
rm -f "$REG"/pkg/fresh-pkg-* ; "$PKG" index remove "$REG" fresh-pkg 1.0.0 "$W/k.sec" > /dev/null 2>&1

# The browser: search, a live publish, the detail and its files.
if command -v node > /dev/null && command -v "${CHROMIUM:-chromium}" > /dev/null; then
    if node "$ROOT/tests/browser.mjs" "$URL" "'$PKG' publish '$W/new' '$REG' '$W/k.sec'" > "$W/browser.out" 2>&1; then
        ok "browser ($(grep -c '^ok' "$W/browser.out") checks)"
    else
        bad "browser"; cat "$W/browser.out"
    fi
else
    echo "skip browser (needs node and chromium)"
fi
rm -f "$REG"/pkg/fresh-pkg-* ; "$PKG" index remove "$REG" fresh-pkg 1.0.0 "$W/k.sec" > /dev/null 2>&1

# A tampered archive: hash and signature both fail.
cp "$REG/pkg/resid-serial-0.1.0.resid-pkg" "$W/orig"
printf 'X' | dd of="$REG/pkg/resid-serial-0.1.0.resid-pkg" bs=1 seek=40 conv=notrunc 2> /dev/null
get /ui/version/resid-serial/0.1.0 > /dev/null
has "tamper hash" "hash differs"
has "tamper signature" "signature invalid"
cp "$W/orig" "$REG/pkg/resid-serial-0.1.0.resid-pkg"
kill $UIPID 2>/dev/null; wait $UIPID 2>/dev/null

# The wrong key: the index does not verify.
"$PKG" keygen "$W/o.sec" "$W/o.pub" > /dev/null
start "$W/port2" --pubkey "$(cat "$W/o.pub")"
UIPID=$!
get / > /dev/null
has "wrong key index" "index bad signature"
get /ui/version/resid-json/0.1.0 > /dev/null
has "wrong key archive" "signature invalid"
kill $UIPID 2>/dev/null; wait $UIPID 2>/dev/null

# No key, and the CDN client.
start "$W/port3" --cdn
UIPID=$!
get / > /dev/null
has "no key index" "index signed"
has "cdn tag" 'integrity="sha384-'

kill $UIPID 2>/dev/null; wait $UIPID 2>/dev/null
echo "ui: $pass passed, $fail failed"
[ "$fail" = 0 ]
