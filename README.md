# resid-datastar

A [Datastar](https://data-star.dev) server SDK for Resid, and a web UI for
a resid package registry built with it.

Datastar drives a page from the server: the browser sends its signals as
JSON, the server answers with server-sent events that patch elements and
signals. This package implements the SDK specification
([`sdk/ADR.md`](https://github.com/starfederation/datastar/blob/v1.0.4/sdk/ADR.md))
over `lib/httpserv.resid`, passes Datastar's own SDK test suite, and embeds
the v1.0.4 client so a server needs no file or CDN to serve it.

```resid
import "src/datastar.resid";

HttpOut(Int) handle(HttpRequest r) {
    if (r.path == ds_client_path()) { return Whole(ds_client_reply()); }
    if (r.path == "/hello") {
        return Whole(ds_reply([
            ds_patch_elements("<p id=\"greeting\">Hello from Resid</p>"),
            ds_patch_signals("{\"seen\": true}")
        ]));
    }
    return Whole(http_reply_status(404));
}
```

`examples/counter.resid` is a whole app: signals posted back, patched
signals and elements, and a stream the server pushes once a second.

## The SDK (`src/datastar.resid`)

| Call | Event |
|---|---|
| `ds_patch_elements(html, selector =, mode =, use_view_transition =, view_transition_selector =, namespace =, event_id =, retry_ms =)` | `datastar-patch-elements` |
| `ds_remove_elements(selector, ...)` | `datastar-patch-elements`, mode `remove` |
| `ds_patch_signals(json, only_if_missing =, ...)` / `ds_patch_signals_of(value)` | `datastar-patch-signals` |
| `ds_remove_signals(["user.name", ...])` | a merge patch of nulls |
| `ds_execute_script(js, auto_remove =, attributes =, ...)` | a `<script>` appended to the body |
| `ds_redirect`, `ds_replace_url`, `ds_console_log`, `ds_console_error`, `ds_dispatch_event` | script sugar |
| `ds_send(type, data_lines, event_id =, retry_ms =)` | any event |

Options are named arguments with the protocol's defaults, and only what
differs from a default is written. Modes are `ModeOuter` (the default),
`ModeInner`, `ModeReplace`, `ModePrepend`, `ModeAppend`, `ModeBefore`,
`ModeAfter`, `ModeRemove`; namespaces `NsHtml`, `NsSvg`, `NsMathml`.

An event is its text, so a reply is a list of them:

- `ds_reply(events)` answers whole (`HttpReply`).
- `ds_stream(state, events, wait_ms, next)` keeps the connection: `events`
  now, then `next(state)` after `wait_ms`, which returns `ds_step(state2,
  events2, wait2)` to go on or `ds_end(state2, events2)` to finish. Serve it
  with `http_stream_loop` (or `tls_stream_loop`); the waits are socket
  deadlines in the event loop, so a stream costs a descriptor, not a
  thread, and needs no `clock` grant. A client that goes away ends its
  stream.

Reading signals: `ds_read_signals(r)` decodes them into any `T` with a JSON
decoding (a record through resid-derive, a `List(Int)`, ...);
`ds_read_signals_value(r)` gives a `Value` tree, and `ds_signal`,
`ds_signal_text`, `ds_signal_int`, `ds_signal_bool` look up dotted paths
in it. GET and DELETE carry the signals in the `datastar` query parameter,
other methods in the body, as the specification says; missing or invalid
JSON is an `Err`. `ds_is_request(r)` checks `Datastar-Request: true`.

The client: `ds_client_reply()` serves the embedded bundle at
`ds_client_path()` (`/datastar@1.0.4.js`, cached immutably), and
`ds_script_tag()` loads it. `ds_cdn_script_tag()` loads the same bytes
from jsDelivr instead, pinned with a subresource-integrity hash.

`ds_escape_html`, `ds_escape_attr`, `ds_attr` and `ds_json_str` are there
for building markup and scripts safely.

`ds_execute_script` and its sugar run an inline `<script>`. Under a
Content-Security-Policy without `'unsafe-inline'`, give the script a nonce
(`attributes = [ds_attr("nonce", n)]`), or use a patched element's
`data-init` instead, as the registry UI does.

## The registry UI (`ui/registry.resid`)

```sh
residc ui/registry.resid -o resid-registry-ui
./resid-registry-ui <registry-dir> [--port 8090] [--pubkey HEX] [--cdn] [--poll-ms 1000]
```

It reads the directory `resid-pkg publish` writes and serves, on
127.0.0.1 only and without ever writing:

- **Packages**: every published package with its newest version,
  description, licence and capability grant, searched as you type (names,
  descriptions and keywords), and the index's state: verified against
  `--pubkey`, signed, unsigned, absent, or a bad signature.
- **A package** (`/pkg/<name>?v=&tab=&file=&from=`): a version picker, the
  version's checks (the recorded hash against the archive's actual
  SHA-256, its signature against the key, whether it is the newest), and
  five tabs. Every view has its own URL, kept in the address bar.
  - *Readme*: the root README rendered from Markdown. Raw HTML stays
    text, and only http(s), mailto, anchor and relative links survive.
    A relative link opens that file in *Files*.
  - *Manifest*: the `[package]` fields, the capability grant (grants
    that can write or act are marked), `require_signatures`, the
    `[dependencies]` entry to depend on this version (with the registry
    key when given), and the raw `resid.toml`.
  - *Files*: every file in the archive, each viewable in place or raw.
  - *Dependencies*: direct dependencies with their requirement, ceiling,
    pinned key and whether this registry has them. Then the whole tree
    with cycles and missing packages flagged, and *used by*: every
    release that depends on this package, and whether it asks for this
    version.
  - *Diff*: this version against any other one. Files added, removed and
    changed, capabilities gained or dropped, dependencies added or
    removed, and a line diff (Myers) with context for each changed file.
- **Live**: every page holds one stream that watches the registry. When a
  publish, a removal or a re-signed index changes it, the page fetches
  what changed with its current view, without a reload. The header shows
  whether the stream is connected.

Pages send a Content-Security-Policy that allows only the server's own
scripts (or the pinned CDN copy). Datastar evaluates its expressions, so
`'unsafe-eval'` is included, but no inline script runs. Raw files are
served as `text/plain` with `nosniff` and a sandbox policy. Names,
versions and paths are checked or percent-encoded before they reach a
path or an expression, and everything shown is escaped.

Packages need their README in the archive: `resid-pkg pack` takes a
package's root README, LICENSE, CHANGELOG, NOTICE and COPYING alongside
its `.resid` and `.toml` files.

## Layout

| Path | What |
|---|---|
| `src/datastar.resid` | the SDK |
| `src/client.resid` | the client bundle embedded, generated by `tools/embed_client.py` |
| `assets/datastar.js` | Datastar v1.0.4's bundle, unmodified (`assets/DATASTAR-LICENSE.md`, MIT) |
| `ui/registry.resid` | the registry UI's pages and routes |
| `ui/store.resid` | reading a registry directory: entries, archives, releases |
| `ui/manifest.resid` | `resid.toml` through resid-toml: fields, grant, dependencies |
| `ui/markdown.resid` | Markdown to safe HTML |
| `ui/diff.resid` | Myers line diffs and hunks |
| `examples/counter.resid` | a complete small app |
| `tests/` | the suites, below |

## Tests

```sh
tests/run.sh             # RESIDC=/path/to/residc to pick the compiler
tests/run.sh --update    # rewrite the golden .out files
```

- `events`, `signals`, `stream`: golden checks of every event and option
  against the specification's text, signal reading for each method and its
  refusals, and a stream served by the real event loop.
- `markdown`, `ui_parts`: each Markdown form and the ways text could
  become markup or a script URL; manifests, capability classes, and line
  diffs (minimal edit scripts, hunks).
- `spec`: Datastar's own SDK suite (`tests/spec`, from `sdk/test` at
  v1.0.4, run with curl, awk and sh) against `tests/sdk_server.resid`;
  each case is counted.
- `ui`: the registry UI against a registry `tests/fixture.sh` builds
  with `resid-pkg` (two versions of a package that differ in README,
  grant, dependencies and files; a dependency cycle; a missing
  dependency). It covers every tab, search, verification, headers, a
  tampered archive, a wrong key, downloads, traversal refusals and the
  live stream. When node and chromium are installed, `tests/browser.mjs`
  also drives it in headless Chromium: typing, a live publish, every tab,
  switching versions, following README links.

## Requirements

Checkouts of [resid-json](https://github.com/larrydewey/resid-json),
[resid-serial](https://github.com/larrydewey/resid-serial) and resid-toml
(for the UI's manifests) beside this one
(the imports are relative), and a Resid compiler with streamed replies in
`lib/httpserv.resid` (`HttpOut`, `http_stream_loop`). The UI tests build
`tools/resid-pkg.resid` from a resid checkout beside this one
(`RESID_SRC` overrides).

To move to a newer Datastar, replace `assets/datastar.js` and
`assets/DATASTAR-LICENSE.md`, run `tools/embed_client.py`, and update the
version in the tests.

## Licence

MIT, in `LICENSE`. The vendored Datastar client (`assets/datastar.js`,
embedded in `src/client.resid`) and its SDK test cases (`tests/spec`) are
Star Federation's, also MIT, in `assets/DATASTAR-LICENSE.md`.
