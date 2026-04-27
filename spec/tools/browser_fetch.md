# browser_fetch

Fetch a URL through headless Chromium with article extraction. The "heavy" tier of the three-tier web ladder (`webFetch` → `browserFetch` → `browser-use` skill — see `architecture.md` → Components → Agent).

## Description (shown to the model)

Fetch a URL through a real browser engine (headless Chromium) and return the extracted article content. Use this when:

- The page is JS-heavy and `webFetch` returns empty or shell-only HTML (single-page apps, infinite-scroll articles, dynamic content).
- `webFetch` reports the URL is bot-blocked (X/Twitter, Cloudflare-gated articles, sites with bot detection).
- You need the rendered page, not the raw HTML.

For static pages, JSON APIs, plain HTML, anything where a plain HTTP fetch would work, prefer `webFetch` — it's an order of magnitude faster (200ms vs ~1–2s) and doesn't burn ~150MB of memory. For multi-step interactions (login, form fill, navigation across pages), use the `browser-use` skill instead.

**This tool is anonymous.** Each call gets a fresh, logged-out browser context. It does **not** share sessions with the user's Chrome or with `browser-use` (which connects to the user's logged-in Chrome via CDP — different mechanism, different blast radius). If a page requires authentication or a captured session, use `browser-use`, not `browser_fetch`.

## Input

```ts
{ url: string }
```

## Output

```ts
{ url: string, title: string, content: string }
```

- `url` — the final URL after any redirects.
- `title` — the article title from Mozilla Readability, or the page's `<title>` if Readability couldn't extract.
- `content` — the cleaned article text. Extracted via Mozilla Readability over the rendered HTML, so it strips nav, footer, ads, and comment sections.

## Behavior

Pipeline: `chromium.launch({ headless: true })` → fresh `BrowserContext` (cookie isolation) → `page.goto(url, { waitUntil: 'networkidle', timeout: 30000 })` → `page.content()` → Mozilla Readability over the rendered HTML → return `{ url: page.url(), title: article.title, content: article.textContent }`.

- **Browser singleton — kept running for the daemon's lifetime.** Lazy-launched on the **first** `browser_fetch` call after `agent/protos start`; reused for **every** subsequent call across channels, sub-agents, and cron jobs; closed only when the daemon exits or restarts. Cold start (~1–2s) pays once per daemon, not per fetch. Warm calls land at ~500ms–1.5s depending on the page. Do not relaunch the browser per dispatch — that defeats the entire reason this tool exists.
- **Per-fetch isolation.** A fresh `BrowserContext` and `Page` per call (cookie/storage isolation between fetches). Both close in a `finally` block after extraction so a failed fetch doesn't leak the context. The `Browser` itself stays up.
- **Realistic user agent.** A current desktop Chrome string. Default Playwright UA gets flagged as a bot more often than the realistic one.
- **Failure modes** surface as tool errors (the SDK's tool-dispatch layer turns thrown errors into tool results the model sees):
  - Navigation timeout (>30s) → `Error("browser_fetch: navigation timeout for {url}")`.
  - Non-2xx HTTP status → `Error("browser_fetch: HTTP {status} for {url}")`.
  - Readability returning `null` (no extractable article) → fall back to `body.innerText` truncated to ~50KB. Don't error — many useful pages aren't articles, and a partial result beats a hard fail.
  - Network/DNS errors from `page.goto` → wrap and re-throw with the URL in the message.
- **No persistent state.** No cookies, no localStorage, no service workers carried across calls. The browser sees only what the URL renders to a fresh visitor — same blast radius as `webFetch`, just on a real engine.

## Dependencies

- `playwright` — the browser automation library. Pinned via `agent/package.json`.
- `@mozilla/readability` — article extraction.
- `jsdom` — DOM Readability parses against (Readability needs a real DOM, not a regex parser).
- Chromium binary at `vendor/chromium/`, installed at build time via `PLAYWRIGHT_BROWSERS_PATH=$WORKSPACE_ROOT/vendor/chromium npx playwright install chromium` (see `spec/build.md` → step 1). The wrapper script (`agent/protos`) exports the same `PLAYWRIGHT_BROWSERS_PATH` before launching the daemon so the runtime finds the binary.

## Implementation notes

- **Single-file tool.** `agent/src/tools/browser_fetch.ts` exports the tool definition (name, schema, execute) plus a module-local `getBrowser()` that lazy-launches the `Browser` once and caches it. The cache lives at module scope (top-level `let browser: Browser | null = null`) so every importer in the same process — main agent, sub-agent runner, cron scheduler — sees the same instance. **Do not** put `chromium.launch()` inside the `execute` function or inside an `Agent` factory closure; both of those construct fresh state per dispatch and would relaunch on every call.
- **Browser lifecycle.** Register a `process.on('exit')` (or `SIGTERM`/`SIGINT`) handler that calls `browser.close()` if a browser was launched. Don't fight the process exit; if close fails or hangs, the process exiting cleans up anyway.
- **Concurrent calls.** v1 ships with a single browser process and serializes fetches per agent. If concurrent calls become a bottleneck, swap to a small pool — see `plan/web-search-and-fetch.md` open question 5.
- **Memory leaks.** Chromium leaks memory on multi-hour runs. v1 keeps the process up; if memory grows, recycle the browser every N fetches or on a timer — `plan/web-search-and-fetch.md` open question 6.
- **No download interception, no file uploads.** This tool reads pages; it doesn't drive interactions. Anything stateful belongs in the `browser-use` skill.
- **Don't catch the SDK's turn-cap.** `browser_fetch` doesn't iterate or recurse — it's one round-trip per call. Turn-cap concerns belong upstream in agent-sdk, not here.

## Testing

A reference probe lives at `~/bin/playwright-probe` (installed locally during the Tavily-vs-Playwright evaluation; see `plan/web-search-and-fetch.md`). It runs the same Chromium + Readability pipeline as this tool, so testing whether `browser_fetch` will work on a given URL is `playwright-probe <url>`. The production tool's only difference is the singleton browser cache; cold-start latency on the probe is the upper bound on `browser_fetch` latency.
