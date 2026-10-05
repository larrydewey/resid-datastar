// Drive the registry UI in headless Chromium over the DevTools protocol:
// the live stream connects, typing searches, a publish appears without a
// reload, and a version's detail and files load on the package page.
//
//   node tests/browser.mjs <ui-url> <publish-command>
//
// <publish-command> is run (sh -c) while the home page is open; it must
// publish a package named "fresh-pkg". Prints "ok NAME" per check.
import { spawn, execSync } from "node:child_process";
import { mkdtempSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [url, publish] = process.argv.slice(2);
const browser = process.env.CHROMIUM || "chromium";
const profile = mkdtempSync(join(tmpdir(), "ds-chrome-"));
const chrome = spawn(browser, ["--headless=new", "--disable-gpu", "--no-sandbox", "--no-first-run",
    `--user-data-dir=${profile}`, "--remote-debugging-port=0", "about:blank"], { stdio: "ignore" });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = 0;
function report(name, ok, extra = "") {
    console.log((ok ? "ok " : "FAIL ") + name + (ok || !extra ? "" : ": " + extra));
    if (!ok) failed++;
}

async function devtoolsPort() {
    const file = join(profile, "DevToolsActivePort");
    for (let i = 0; i < 200; i++) {
        if (existsSync(file)) {
            const port = readFileSync(file, "utf8").split("\n")[0];
            if (port) return port;
        }
        await sleep(50);
    }
    throw new Error("chromium did not start");
}

async function main() {
    const port = await devtoolsPort();
    const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" })).json();
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
    let seq = 0;
    const waiting = new Map();
    ws.onmessage = (m) => {
        const msg = JSON.parse(m.data);
        if (msg.id && waiting.has(msg.id)) { waiting.get(msg.id)(msg); waiting.delete(msg.id); }
    };
    const send = (method, params = {}) => new Promise((r) => {
        const id = ++seq;
        waiting.set(id, r);
        ws.send(JSON.stringify({ id, method, params }));
    });
    const evaluate = async (expr) => {
        const res = await send("Runtime.evaluate", { expression: expr, returnByValue: true });
        return res.result?.result?.value;
    };
    // Poll `expr` until it is truthy, up to `ms`.
    const until = async (expr, ms = 5000) => {
        for (let t = 0; t < ms; t += 50) {
            if (await evaluate(expr)) return true;
            await sleep(50);
        }
        return false;
    };
    const open = async (path) => {
        await send("Page.navigate", { url: url + path });
        return until("document.readyState === 'complete'");
    };
    await send("Page.enable");
    await send("Runtime.enable");

    const live = "getComputedStyle(document.querySelector('.live .on')).display !== 'none'";
    const names = "[...document.querySelectorAll('#packages li strong')].map(e => e.textContent).join(' ')";

    await open("/");
    report("live stream connects", await until(live));
    report("home lists packages", await until(`${names}.includes('resid-json') && ${names}.includes('resid-serial')`));

    await evaluate("(() => { const i = document.querySelector('input[type=search]'); i.value = 'seri'; i.dispatchEvent(new Event('input', { bubbles: true })); })()");
    report("search narrows", await until(`${names} === 'resid-serial'`), await evaluate(names));
    await evaluate("(() => { const i = document.querySelector('input[type=search]'); i.value = 'zzz'; i.dispatchEvent(new Event('input', { bubbles: true })); })()");
    report("search finds nothing", await until("document.querySelector('#packages').textContent.includes('No package matches')"));
    await evaluate("(() => { const i = document.querySelector('input[type=search]'); i.value = ''; i.dispatchEvent(new Event('input', { bubbles: true })); })()");
    report("search cleared", await until(`${names}.includes('resid-json')`));

    execSync(publish, { stdio: "ignore", shell: "/bin/sh" });
    report("publish appears live", await until(`${names}.includes('fresh-pkg')`, 8000), await evaluate(names));
    report("page was not reloaded", await evaluate("performance.getEntriesByType('navigation').length === 1 && document.querySelector('input[type=search]') !== null"));

    // A package: its readme, then each tab, a file, another version.
    const panel = "document.querySelector('#panel').textContent";
    const tab = (label) => evaluate(`[...document.querySelectorAll('nav.tabs button')].find(b => b.textContent === '${label}').click()`);
    await open("/pkg/web");
    report("package readme", await until(`${panel}.includes('Now serves files.')`));
    report("live on package page", await until(live));
    await tab("Files");
    report("files tab", await until("document.querySelector('#viewer') !== null"));
    report("tab marked active", await until("document.querySelector('nav.tabs button.active')?.textContent === 'Files'"));
    report("url follows the tab", await until("location.search.includes('tab=files')"));
    await evaluate("[...document.querySelectorAll('#panel button')].find(b => b.textContent === 'src/web.resid').click()");
    report("file opens", await until("document.querySelector('#viewer h3 code')?.textContent === 'src/web.resid'"));
    report("file escaped", await evaluate("document.querySelector('#viewer pre').children.length === 0"));
    report("url names the file", await until("location.search.includes('file=src/web.resid')"));
    await tab("Manifest");
    report("manifest tab", await until(`${panel}.includes('The most this package')`));
    await tab("Dependencies");
    report("dependencies tab", await until(`${panel}.includes('Used by')`));
    report("cycle shown", await evaluate("document.querySelector('#panel .badge.bad')?.textContent === 'cycle'"));
    await tab("Diff");
    report("diff tab", await until(`${panel}.includes('Gains')`));
    report("diff lines", await until("document.querySelectorAll('#panel tr.add').length > 0 && document.querySelectorAll('#panel tr.del').length > 0"));
    await evaluate("(() => { const s = document.querySelector('#bar select'); s.value = '1.0.0'; s.dispatchEvent(new Event('change', { bubbles: true })); })()");
    report("version switch", await until("document.querySelector('#title code')?.textContent === '1.0.0'"));
    report("older version marked", await until("document.querySelector('#summary').textContent.includes('newer: 1.1.0')"));
    await tab("Readme");
    report("older readme", await until(`${panel}.includes('framework. See the licence')`));
    report("readme script stays text", await evaluate("[...document.querySelectorAll('#panel script')].length === 0 && document.querySelector('#panel').textContent.includes('<script>alert(1)</script>')"));
    await evaluate("[...document.querySelectorAll('#panel a')].find(a => a.textContent === 'the licence').click()");
    report("readme link opens the file", await until("document.querySelector('#viewer pre')?.textContent.includes('MIT licence text')"));

    await open("/pkg/resid-json");
    report("signature verified", await until("document.querySelector('#summary').textContent.includes('signature verified')"));

    ws.close();
}

main().catch((e) => { report("browser run", false, String(e)); }).finally(() => {
    chrome.kill();
    try { rmSync(profile, { recursive: true, force: true }); } catch {}
    process.exit(failed ? 1 : 0);
});
