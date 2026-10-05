#!/usr/bin/env bash
# The registry UI against the registry tests/fixture.sh builds: the home
# page and search; a package's tabs (readme, manifest, files, dependencies,
# diff) through its page and its view events; raw files, downloads,
# refusals and headers; the live stream; a tampered archive; a wrong key;
# no key and the CDN client. Then, when node and chromium are installed,
# the same UI in a browser (tests/browser.mjs).
#
#   tests/ui.sh <work-dir> <resid-registry-ui> <resid-pkg>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$1"; UI="$2"; PKG="$3"
pass=0; fail=0
ok() { echo "ok $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
has() { if grep -q -- "$2" "$W/got"; then ok "$1"; else bad "$1: no '$2'"; head -c 600 "$W/got"; echo; fi; }
hasnt() { if grep -q -- "$2" "$W/got"; then bad "$1: has '$2'"; else ok "$1"; fi; }
get() { curl -s -o "$W/got" -w "%{http_code}" "$URL$1"; }
view() { curl -s -G -o "$W/got" "$URL/ui/view/$1" --data-urlencode "datastar=$2"; }

"$ROOT/tests/fixture.sh" "$W" "$PKG" || { echo "FAIL fixture"; exit 1; }
REG="$W/reg"
mkdir -p "$W/new"; printf '[package]\nname = "fresh-pkg"\nversion = "1.0.0"\n' > "$W/new/resid.toml"
echo 'pub Int one() { return 1; }' > "$W/new/one.resid"
unpublish() { rm -f "$REG"/pkg/fresh-pkg-*; "$PKG" index remove "$REG" fresh-pkg 1.0.0 "$W/k.sec" > /dev/null 2>&1; }

start() { # start <port-file> <args...>
    local pf="$1"; shift
    "$UI" "$REG" --port 0 --port-file "$pf" --poll-ms 100 "$@" > "$W/ui.log" 2>&1 &
    for _ in $(seq 1 100); do [ -s "$pf" ] && break; sleep 0.05; done
    URL="http://127.0.0.1:$(tr -d '\n' < "$pf")"
}

start "$W/port" --pubkey "$(cat "$W/k.pub")"
UIPID=$!

# Home and search.
[ "$(get /)" = 200 ] && ok "home 200" || bad "home"
has "home lists json" 'href="/pkg/resid-json"'
has "home index verified" "index verified"
has "home unlisted badge" "not in index"
has "home description" "A tiny web framework"
has "home licence" '<span class="badge plain">MIT</span>'
has "home write grant marked" '<span class="badge cap warn" title="capability">filesystem</span>'
has "home client tag" 'src="/datastar@1.0.4.js"'
has "home live stream" "/ui/live/home"
curl -s -D "$W/head" -o /dev/null "$URL/"
grep -qi "^content-security-policy: default-src 'self'; script-src 'self' 'unsafe-eval';" "$W/head" && ok "home csp" || bad "home csp"
grep -qi "^x-content-type-options: nosniff" "$W/head" && ok "home nosniff" || bad "home nosniff"
get "/ui/search?datastar=%7B%22q%22%3A%22SERIAL%22%7D" > /dev/null
has "search event" "event: datastar-patch-elements"
hasnt "search filters" 'href="/pkg/resid-json"'
get "/ui/search?datastar=%7B%22q%22%3A%22framework%22%7D" > /dev/null
has "search descriptions" 'href="/pkg/web"'
get "/ui/search?datastar=%7B%22q%22%3A%22%3Cb%3E%22%7D" > /dev/null
has "search escapes the query" "“&lt;b&gt;”"

# A package page: newest version, readme tab.
[ "$(get /pkg/web)" = 200 ] && ok "package 200" || bad "package"
has "package newest" "<h1 id=\"title\">web <code>1.1.0</code></h1>"
has "package readme" '<h1 id="web-11">web 1.1</h1>'
has "package latest badge" '<span class="badge good">latest</span>'
has "package hash" "hash matches"
has "package signature" "signature verified"
has "package tabs" "Dependencies</button>"
has "package version picker" '<option value="1.0.0">1.0.0</option>'
get "/pkg/web?v=1.0.0" > /dev/null
has "older version" "<h1 id=\"title\">web <code>1.0.0</code></h1>"
has "older is not latest" "newer: 1.1.0"
has "readme markdown" "<li><code>json</code> replies</li>"
has "readme relative link" 'href="/pkg/web?v=1.0.0&amp;tab=files&amp;file=LICENSE"'
has "readme script escaped" "&lt;script&gt;alert(1)&lt;/script&gt;"
hasnt "readme script not markup" "<script>alert(1)"
get "/pkg/web?v=1.0.0&tab=files&file=LICENSE" > /dev/null
has "deep link to a file" "MIT licence text"
get "/pkg/web?v=nope&tab=nope" > /dev/null
has "unknown version and tab fall back" '<h1 id="web-11">web 1.1</h1>'

# View events, tab by tab.
view web '{"ver":"1.0.0","tab":"manifest"}'
has "view signals" 'data: signals {"ver":"1.0.0","tab":"manifest","from":"1.0.0"}'
has "view url" "replaceState({}, '', &quot;/pkg/web?v=1.0.0&amp;tab=manifest&quot;)" 
has "manifest fields" '<tr><th>repository</th><td><a href="https://example.org/web"'
has "manifest grant" 'network(readonly)</span></p><p class="muted">The most'
has "manifest snippet" "\[dependencies.web\]"
has "manifest raw" 'grant = \["network(readonly)"\]'
view web '{"ver":"1.1.0","tab":"files","file":"src/files.resid"}'
has "files list" "src/files.resid</button>"
has "files open the named one" 'pub Str root() { return "."; }'
view web '{"ver":"1.1.0","tab":"deps"}'
has "deps direct" '<a href="/pkg/util?v=0.1.0">util</a>'
has "deps no ceiling" "no capabilities"
has "deps tree" '<a href="/pkg/resid-serial?v=0.1.0&tab=deps">resid-serial</a>'
has "deps cycle" '<span class="badge bad">cycle</span>'
has "deps used by" '<td>version 1.1.0</td><td><span class="badge good">this version</span>'
view orphan '{"tab":"deps"}'
has "deps missing" "not in this registry"
view web '{"ver":"1.1.0","tab":"diff","from":"1.0.0"}'
has "diff counts" "1 added, 1 removed, 3 changed, 1 unchanged"
has "diff grant gained" '<b>Gains</b> <span class="badge cap warn" title="capability">filesystem</span>'
has "diff new dependency" "<b>New dependencies</b> <code>util version 0.1.0</code>"
has "diff added file" "<h3>Added</h3><p><code>src/files.resid</code>"
has "diff removed file" "<h3>Removed</h3><p><code>src/old.resid</code>"
has "diff lines" '<td>- pub Int port() { return 8080; }</td>'
has "diff lines added" '<td>+ pub Int port() { return 8443; }</td>'
view web '{"ver":"1.1.0","tab":"diff","from":"1.1.0"}'
has "diff same version" "Pick an earlier version"
view nope '{}'
has "view of a missing package" "This package is gone"

# Files, raw, downloads, refusals.
get /ui/file/web/1.1.0/src/web.resid > /dev/null
has "file view" "<code>src/web.resid</code>"
has "file view url" "tab=files&amp;file=src/web.resid"
[ "$(get /raw/web/1.0.0/README.md)" = 200 ] && grep -q "<script>alert(1)</script>" "$W/got" && ok "raw file" || bad "raw file"
curl -s -D "$W/head" -o /dev/null "$URL/raw/web/1.0.0/README.md"
grep -qi "^content-type: text/plain" "$W/head" && grep -qi "^content-security-policy: sandbox" "$W/head" && ok "raw is inert" || bad "raw is inert"
[ "$(get /raw/web/1.0.0/nope)" = 404 ] && ok "raw missing 404" || bad "raw missing"
[ "$(get /download/resid-json/0.1.0)" = 200 ] && cmp -s "$W/got" "$REG/pkg/resid-json-0.1.0.resid-pkg" && ok "download bytes" || bad "download bytes"
[ "$(get /pkg/nope)" = 404 ] && ok "unknown package 404" || bad "unknown package"
[ "$(get '/pkg/..%2F..%2Fetc')" = 404 ] && ok "traversal 404" || bad "traversal"
[ "$(get '/download/..%2F..%2Fx/1')" = 404 ] && ok "download traversal 404" || bad "download traversal"
[ "$(get '/raw/..%2Fx/1/a')" = 404 ] && ok "raw traversal 404" || bad "raw traversal"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/")" = 405 ] && ok "post refused" || bad "post refused"
[ "$(get /datastar@1.0.4.js)" = 200 ] && [ "$(sha256sum < "$W/got" | cut -c1-64)" = "$(sha256sum < "$ROOT/assets/datastar.js" | cut -c1-64)" ] && ok "client bytes" || bad "client bytes"

# The live stream: a publish moves the fingerprint and a pulse goes out.
curl -sN "$URL/ui/live/pkg/web" > "$W/live" &
CURLPID=$!
sleep 0.4; "$PKG" publish "$W/new" "$REG" "$W/k.sec" > /dev/null; sleep 0.6
kill $CURLPID 2>/dev/null; wait $CURLPID 2>/dev/null
grep -q "data-init=\"@get(&#39;/ui/view/web&#39;)\"\|data-init=\"@get('/ui/view/web')\"" "$W/live" && ok "live pulse" || { bad "live pulse"; cat "$W/live"; }
unpublish

# The browser: search, a live publish, tabs, versions, files.
if command -v node > /dev/null && command -v "${CHROMIUM:-chromium}" > /dev/null; then
    if node "$ROOT/tests/browser.mjs" "$URL" "'$PKG' publish '$W/new' '$REG' '$W/k.sec'" > "$W/browser.out" 2>&1; then
        ok "browser ($(grep -c '^ok' "$W/browser.out") checks)"
    else
        bad "browser"; cat "$W/browser.out"
    fi
else
    echo "skip browser (needs node and chromium)"
fi
unpublish

# A tampered archive: hash and signature both fail.
cp "$REG/pkg/resid-serial-0.1.0.resid-pkg" "$W/orig"
printf 'X' | dd of="$REG/pkg/resid-serial-0.1.0.resid-pkg" bs=1 seek=40 conv=notrunc 2> /dev/null
get /pkg/resid-serial > /dev/null
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
get /pkg/resid-json > /dev/null
has "wrong key archive" "signature invalid"
kill $UIPID 2>/dev/null; wait $UIPID 2>/dev/null

# No key, and the CDN client.
start "$W/port3" --cdn
UIPID=$!
get / > /dev/null
has "no key index" "index signed"
has "cdn tag" 'integrity="sha384-'
curl -s -D "$W/head" -o /dev/null "$URL/"
grep -qi "^content-security-policy:.*https://cdn.jsdelivr.net" "$W/head" && ok "cdn csp" || bad "cdn csp"
kill $UIPID 2>/dev/null; wait $UIPID 2>/dev/null
echo "ui: $pass passed, $fail failed"
[ "$fail" = 0 ]
