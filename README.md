# claude-code-statusline

A [Claude Code](https://claude.com/claude-code) `statusLine` that answers one
question first — **which pool is paying for this session?** — and then fills in
the detail: context window usage, session and weekly rate limits, session cost
and burn rate, git state and open PR, plus (via an optional Chrome-based
scraper) the two credit balances Anthropic exposes only on its web dashboards.

Every row is drawn on one alignment grid, and each carries an honest freshness
signal rather than presenting cached numbers as live.

![claude-code-statusline screenshot](assets/screenshot.png)

*The same session before and after its 5-hour limit runs out — the `▸` moves
from the quota row to the credits row. Illustrative numbers, not real billing
data.*

## Which pool is paying

Working with Claude Code bills to one of three pools, and the leading marker on
each row says which one is live right now:

| Marker | Meaning |
|---|---|
| <code>▸</code> green | **Plan quota** — the rolling 5-hour and 7-day subscription limits. Free at the point of use. |
| <code>▸</code> yellow | **Plan credits** — the usage-credit overflow add-on, which takes over the moment either rolling limit hits 100% so the session keeps running. Real money. |
| <code>▸</code> red | **API credits** — a Console (`platform.claude.com`) account billed per token, used when Claude Code is authenticated with an API key rather than a subscription. |
| <code>○</code> | A billing pool that exists but is not paying for this session. |
| <code>·</code> | Not a billing pool at all — context window, session cost estimate. |

Quota and plan credits are a sequence: spend flows from the first into the
second at 100%. API credits are an **alternative** to both — an API-key session
never touches the subscription, and a subscription session never touches the
Console balance. That is why only ever one `▸` is lit.

The paying pool is worked out from the payload rather than configured:
`ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` in the environment is decisive,
otherwise the presence of `rate_limits` marks a subscription session and its
percentages pick quota vs. credits. Before the first API response there is
nothing to go on, so no row is marked rather than guessing.

> Earlier versions used this column for cache freshness — green for a fresh
> scrape, gray for stale. Three rows carrying identical green dots for an
> unrelated reason read as a three-tier billing ladder, which is the exact
> thing they were not. Freshness now lives inline (`(row from 13d ago)`) and in
> the warning line beneath the block.

## Why this exists

The quota rows come straight from the `statusLine` hook payload, which reports
`rate_limits.five_hour` and `rate_limits.seven_day` with reset times as unix
epochs. That is live and exact, and needs no browser.

What the payload does **not** carry is money: neither the plan's usage-credit
overflow nor the separate Console/API credit balance appears anywhere in it.
Those exist only on `claude.ai` and `platform.claude.com`. So the repo has two
independent layers:

1. **Core statusline** (`statusline-command.sh`) — context window, session and
   weekly quota, model, git branch/repo. No extra setup, no browser.
2. **Billing scraper** (`scripts/scrape_claude_usage.py`, optional) — reads the
   two credit figures through a real, non-headless Chrome window over the
   DevTools protocol, on a cron. Headless is not an option: Cloudflare's bot
   challenge blocks it even with valid session cookies.

Layer 2 is inherently more fragile — it scrapes a UI that can change and depends
on a browser you keep open — so it is opt-in and fails visibly rather than
quietly. Credit figures also move on a monthly cadence, so a stale reading there
is far less misleading than a stale session quota would be.

> **Historical note.** This tool originally scraped the quota rows too, because
> the usage page carried a per-model cap (Fable's) that the CLI never exposed.
> That cap has since been retired — the page now shows only "Current session"
> and "All models", the same two buckets the payload already provides — so the
> scrape was removed. If a per-model bucket ever returns to the payload, add it
> with `STATUSLINE_ROWS` (below); no scraping required.

## Install: core statusline

1. Copy `statusline-command.sh` somewhere permanent, e.g. `~/.claude/statusline-command.sh`.
2. Add to `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash /home/YOU/.claude/statusline-command.sh"
     }
   }
   ```
3. Restart Claude Code (or run `/config` and toggle something to force a reload).

Context, Session, All models, This session, and the whole footer work
immediately. The two credit rows read "no data" until you set up the scraper, or
you can switch them off entirely — see below.

The `cost` row is deliberately kept visually apart from the credit rows: it is
Claude Code's own client-side estimate and resets on `/clear`, whereas the
credit rows are billed figures read off Anthropic's dashboards. Same grid,
no progress bar, and an annotation saying which it is.

`rate_limits` is only present for Claude.ai subscribers (Pro/Max) and only after
the first API response in a session, so the quota rows are briefly absent at
startup. They are omitted rather than shown as zero.

## Choosing rows

Set `STATUSLINE_ROWS` to a comma-separated, ordered list. Default:

```
context,session,weekly,cost,plan_credits,api_credits
```

| Row id | Shows | Source |
|---|---|---|
| `context` | Context window used, with token breakdown | payload |
| `session` | 5-hour rolling limit | payload |
| `weekly` | 7-day limit ("All models") | payload |
| `cost` | Session cost, burn rate, lines changed, duration | payload |
| `plan_credits` | Plan usage-credit overflow | scraper |
| `api_credits` | Console/API credit balance | scraper |
| `rl:<key>[=Label]` | Any other `rate_limits` bucket | payload |

The footer line is always drawn: model, how it is configured (`effort`,
`thinking`, `fast`), repo, branch with a `●` when the tree is dirty and `↑`/`↓`
against upstream, and the open PR coloured by review state. Each part is
omitted when the payload does not carry it.

Drop both credit rows and the scraper becomes unnecessary — no cron, no Chrome
debug port, no staleness warnings:

```json
{ "statusLine": { "type": "command",
  "command": "STATUSLINE_ROWS=session,weekly bash /home/YOU/.claude/statusline-command.sh" } }
```

The `rl:` form renders any bucket the payload happens to expose, which is the
escape hatch if per-model caps come back:

```
STATUSLINE_ROWS=session,weekly,rl:opus=Opus
```

`CLAUDE_USAGE_CACHE` overrides the cache path, which is handy for testing
against a fixture.

## Install: billing scraper (optional)

Requires Playwright (`pip install playwright && playwright install chromium` —
the package is needed even though this never launches its own browser, only
attaches to yours over CDP) and a Chrome window you keep logged in.

**Built and tested on WSL2 + Windows Chrome.** The debug-port launch commands
are WSL-specific; on native Linux/macOS substitute your own way of starting
Chrome with `--remote-debugging-port=9222` on a logged-in profile. Everything
downstream of "Chrome is up on :9222" is plain Playwright and portable.

1. **Launch Chrome with the debug port and log in.**
   ```bash
   # WSL example — adjust exe/profile paths for your machine
   powershell.exe -NoProfile -Command \
     "Start-Process -FilePath 'C:\Program Files\Google\Chrome\Application\chrome.exe' \
      -ArgumentList '--remote-debugging-port=9222','--profile-directory=Default'"
   ```
   Log into **both** `claude.ai` and `platform.claude.com` — separate logins even
   on the same account.

   Chrome only honours that flag on a **cold** start. Launching it while an
   instance already holds the profile silently forwards to the running process
   and drops the flag, so Chrome must be fully closed first.

2. **Test the scraper once:**
   ```bash
   python3 scripts/scrape_claude_usage.py
   cat ~/.claude/claude-usage-cache.json
   tail ~/.claude/scripts/scrape_claude_usage.log
   ```
   Expect `plan`, `credits`, `console_credits`, per-row `_fetched_at` stamps, and
   a `last_run` block. The log records one line per run (`OK 2 rows`, `FAIL
   no-cdp …`) — the scraper never writes to stdout, so the log is how you find
   out it stopped working.

3. **Cron it** (point at whichever python has Playwright):
   ```
   */5 * * * * /path/to/python3 /path/to/scripts/scrape_claude_usage.py >> ~/.claude/scrape_claude_usage.log 2>&1
   ```
   Hourly is plenty — these are monthly figures.

4. **Optional: `SessionStart` hook.** `scripts/ensure_chrome_debug.sh` launches
   Chrome with the debug flag if Chrome is not running at all. If Chrome **is**
   running without the flag — the common case when it is your daily browser — it
   deliberately does not kill it and prints a one-line reminder instead.
   ```json
   {
     "hooks": {
       "SessionStart": [
         { "hooks": [{ "type": "command", "command": "bash /path/to/scripts/ensure_chrome_debug.sh", "timeout": 8 }] }
       ]
     }
   }
   ```

5. **When it breaks:** `scripts/fix_usage_scrape.sh` does the whole recovery —
   closes Chrome gracefully so tabs restore, relaunches it with the debug port,
   waits for the port, re-scrapes, and verifies the cache actually took new data.
   It prompts before closing anything (`--yes` to skip), and finds a
   Playwright-capable interpreter automatically (override with
   `STATUSLINE_PYTHON`).

   This is a command you run, not a cron job, precisely because recovery means
   closing your browser. Nothing here does that on a timer.

## How staleness is handled

Cached rows carry their own `_fetched_at`. A partial scrape merges over the
previous cache, so without per-row stamps a regex that quietly stops matching
would keep serving its last value forever under a fresh top-level timestamp —
which is exactly how a retired row went unnoticed for weeks. Rows older than the
scrape as a whole are marked individually, and the freshness line names the
failure and the fix:

```
⚠ usage data 2d ago — Chrome not on debug port :9222  fix: bash ~/.claude/scripts/fix_usage_scrape.sh
```

That line only appears when a cached row is actually on screen.

### Caveats

- Anthropic's markup can change and the regexes may need updating. The scraper
  fails closed — it leaves the last good cache alone rather than writing garbage
  — but it now says so in the log and on the statusline.
- Headless scraping does not work. Verified directly: Cloudflare's challenge
  blocks it even with a valid cookie-restored session.
- The scraper never launches or force-quits Chrome. Only `fix_usage_scrape.sh`
  closes it, only when you confirm, and only via a graceful close.
- `used_percentage` and the dollar figures are scraped independently, so they can
  disagree slightly. The "credit" figure is a prepaid balance, **not**
  limit-minus-spent. A negative one is flagged `unpaid` only past $1 — below
  that it is settlement lag rather than arrears, and the balance is printed
  regardless. The flag is red on the pool that is currently paying, where it
  stops the session, and plain yellow anywhere else.
- The paying-pool marker is inferred, not reported: the payload has no "you are
  billing to X" field. An API key supplied outside the environment (e.g. stored
  credentials) is detected only once the session has non-zero cost and still no
  `rate_limits`.

## License

MIT — see [LICENSE](LICENSE).
