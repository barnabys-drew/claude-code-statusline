# claude-code-statusline

A [Claude Code](https://claude.com/claude-code) `statusLine` that shows context
usage, session/weekly rate limits, and — via an optional Chrome-based scraper —
per-model usage (including limited-availability models like Fable that the
CLI's own hook never reports) and both of Anthropic's separate credit pools
(the Pro/Max plan's usage-credit overflow, and the pay-as-you-go Console/API
balance).

```
 my-project 
  ● Context      12.0%  ▬○○○○○○○○○  ↓41.0k  ↑261  ~40.6k
  ● Session (Pro) 34.0%  ▬▬▬○○○○○○○  resets in 3 hr 12 min
  ● All models    41.0%  ▬▬▬▬○○○○○○  resets Fri 2:00 PM
  ● Fable         62.0%  ▬▬▬▬▬▬○○○○  resets Fri 2:00 PM
  ● Plan credits  55.0%  ▬▬▬▬▬○○○○○  $82.50/$150.00 resets Aug 1  bal $67.50
  ↑ this terminal draws from
  ● API credits   20.0%  ▬▬○○○○○○○○  $10.00/$50 resets Aug 1
  ↑ separate account — not used by Claude Code
  updated 2m ago
  Sonnet 5 (1M context)  |  my-org/my-project  main
```

(Numbers above are illustrative, not real billing data.)

## Why this exists

Claude Code's `statusLine` hook payload only ever exposes the *currently
active* model's rate limits, and even then only the blended "all models"
bucket — never a limited-availability model's own dedicated cap (e.g. Fable),
and never anything about Anthropic's separate Console/API credit balance.
Both of those numbers only exist on Anthropic's own web dashboards. This repo
has two independent, layered pieces:

1. **Core statusline** (`statusline-command.sh`) — context window usage, the
   hook's own session/weekly rate limits, git branch/repo, model name. Works
   everywhere, no extra setup, no browser required.
2. **Usage scraper** (`scripts/scrape_claude_usage.py`, optional/advanced) —
   reads the real per-model and credit numbers off `claude.ai` and
   `platform.claude.com` through a real (non-headless) Chrome window via the
   DevTools protocol, on a cron. Headless browsers get stopped cold by
   Cloudflare's bot challenge even with valid session cookies, so this only
   works through an actual visible browser window you keep logged in.

Part 2 is inherently more fragile (it scrapes a UI that can change, and
depends on a browser you keep open) — it's opt-in and degrades gracefully:
if the cache goes stale, the statusline just dims those rows and shows how
old the data is instead of guessing.

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

That's it — Context/Session/model/branch rows work immediately. The
`Fable` / `All models` / `Plan credits` / `API credits` rows will show
"no data" until you set up the scraper below (or you can delete those
`render_row`/`render_credits` calls near the bottom of the embedded Python
block if you don't want them at all).

## Install: usage scraper (optional, advanced)

Requires: a Playwright install (`pip install playwright && playwright install chromium`
gets the package even though this script never launches its own browser —
it only ever attaches to yours over CDP), and a real Chrome window you're
willing to dedicate to this.

**This was built and tested on WSL2 + Windows Chrome.** The debug-port launch
commands below are WSL-specific; on native Linux/macOS, replace the
PowerShell bits with your OS's own way of launching Chrome with
`--remote-debugging-port=9222` on a profile you're logged into. Everything
downstream of "Chrome is up on :9222" (the Playwright scraping logic) is
plain Playwright and portable as-is.

1. **One-time: launch Chrome with the debug port and log in.**
   ```bash
   # WSL example — adjust the exe/profile paths for your machine
   powershell.exe -NoProfile -Command \
     "Start-Process -FilePath 'C:\Program Files\Google\Chrome\Application\chrome.exe' \
      -ArgumentList '--remote-debugging-port=9222','--profile-directory=Default'"
   ```
   In that window, log into **both** `claude.ai` and `platform.claude.com`
   (they're separate logins, even with the same account).

2. **Test the scraper once:**
   ```bash
   python3 scripts/scrape_claude_usage.py
   cat ~/.claude/claude-usage-cache.json
   ```
   You should see `current_session`, `all_models`, `fable`, `credits`,
   `console_credits`, and `plan` populated. If a section is missing, that
   login/session probably needs refreshing — the script no-ops quietly on
   auth failures rather than erroring loudly, by design (a scrape hook
   should never break your prompt).

3. **Cron it** (adjust the python path to wherever Playwright is installed):
   ```
   */5 * * * * /path/to/python3 /path/to/scripts/scrape_claude_usage.py >> ~/.claude/scrape_claude_usage.log 2>&1
   ```

4. **Optional: auto-relaunch Chrome on session start.** `scripts/ensure_chrome_debug.sh`
   is a `SessionStart` hook that checks whether the debug port is already up;
   if Chrome isn't running *at all*, it launches it fresh with the debug
   flag. If Chrome **is** running without the flag (the common case if it's
   already your daily browser), it deliberately does **not** kill it — it
   just prints a one-line reminder. Wire it up in `~/.claude/settings.json`:
   ```json
   {
     "hooks": {
       "SessionStart": [
         { "hooks": [{ "type": "command", "command": "bash /path/to/scripts/ensure_chrome_debug.sh", "timeout": 8 }] }
       ]
     }
   }
   ```

### Caveats

- Anthropic's site markup can change; the scraper's regexes may need
  updating if a row's text format shifts. It fails closed (leaves the last
  good cache alone) rather than showing garbage.
- Headless scraping does not work — tested directly, Cloudflare's challenge
  page blocks it even with a valid, cookie-restored session. This has to run
  through a real, visible (or at least non-headless) browser window.
- If you don't have Fable access, that row will just always read "no data" —
  harmless, delete it if it bothers you.
- The scraper never launches or force-quits Chrome itself; only the optional
  `SessionStart` hook does, and only when Chrome isn't running at all.

## License

MIT — see [LICENSE](LICENSE).
