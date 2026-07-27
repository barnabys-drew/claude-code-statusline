#!/usr/bin/env bash
# Restore the Claude usage scrape when the statusline goes stale.
#
# The recurring failure: Chrome gets relaunched (update, reboot, manual restart)
# without --remote-debugging-port, scrape_claude_usage.py can no longer attach,
# and the statusline quietly keeps drawing the last good numbers. Chrome only
# honours that flag on a COLD start -- relaunching while an instance already
# holds the profile just forwards to the running process and drops the flag --
# so recovering genuinely requires closing Chrome.
#
# That is why this is a command you run, not a cron job. Nothing should be
# closing your browser on a timer.
#
#   bash ~/.claude/scripts/fix_usage_scrape.sh          # asks before closing Chrome
#   bash ~/.claude/scripts/fix_usage_scrape.sh --yes    # no prompt
set -u

DEBUG_PORT=9222
CHROME_WIN='C:\Program Files\Google\Chrome\Application\chrome.exe'
SCRAPER="$HOME/.claude/scripts/scrape_claude_usage.py"
ASSUME_YES=0

# Playwright usually lives in a virtualenv rather than the system python. Rather
# than hardcode a path, take the first candidate that can actually import it:
# an explicit override, then whatever interpreter the cron entry already uses
# (so there is exactly one place to configure), then the system python.
pick_python() {
  local cron_py candidate
  cron_py=$(crontab -l 2>/dev/null | grep scrape_claude_usage \
    | grep -oE '/[^[:space:]]*python[0-9.]*' | head -1)
  for candidate in "${STATUSLINE_PYTHON:-}" "$cron_py" python3; do
    [ -n "$candidate" ] || continue
    if "$candidate" -c "import playwright" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}
case "${1:-}" in
  --yes|-y) ASSUME_YES=1 ;;
esac

say() { printf '%s\n' "$*" >&2; }

port_up() {
  curl -s --connect-timeout 2 "http://localhost:${DEBUG_PORT}/json/version" >/dev/null 2>&1
}

run_scraper() {
  local py
  if ! py=$(pick_python); then
    say "   no python with Playwright installed found."
    say "   Set STATUSLINE_PYTHON=/path/to/venv/bin/python3 and re-run."
    return 1
  fi
  say "-> running scraper ($py)..."
  "$py" "$SCRAPER"
  # Check the cache actually got NEW data. A failed scrape leaves the old file
  # perfectly readable, so "the file parses" proves nothing -- only a recent
  # updated_at does.
  local age
  age=$(python3 - "$HOME/.claude/claude-usage-cache.json" <<'PY' 2>/dev/null
import json, sys, time
try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
    u = c.get("updated_at")
    print(-1 if not u else int(time.time() - u))
except Exception:
    print(-1)
PY
)
  age=${age:--1}
  if [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -lt 120 ]; then
    say "   cache refreshed (${age}s ago)."
    return 0
  fi
  if [ "$age" -lt 0 ] 2>/dev/null; then
    say "   cache unreadable or never written."
  else
    say "   cache NOT refreshed -- still ${age}s old."
  fi
  return 1
}

if port_up; then
  say "Chrome is already on :${DEBUG_PORT} -- no restart needed."
  run_scraper && say "Done." || say "Scraper still failed; see ~/.claude/scripts/scrape_claude_usage.log"
  exit 0
fi

command -v powershell.exe >/dev/null 2>&1 || { say "powershell.exe unavailable; cannot manage Chrome."; exit 1; }

count=$(powershell.exe -NoProfile -Command \
  "(Get-Process chrome -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -d '\r\n ')
count=${count:-0}

if [ "$count" != "0" ]; then
  say "Chrome is running (${count} processes) WITHOUT --remote-debugging-port=${DEBUG_PORT}."
  say "Opening the port needs a cold start, so Chrome has to close first."
  say "Tabs are restored on relaunch; anything unsaved in a form is not, and"
  say "incognito windows do not come back."
  if [ "$ASSUME_YES" != "1" ]; then
    printf 'Close Chrome and relaunch with the debug port? [y/N] ' >&2
    read -r reply </dev/tty || reply=n
    case "$reply" in
      [yY]*) ;;
      *) say "Left Chrome alone. Statusline will keep showing stale usage data."; exit 0 ;;
    esac
  fi

  # CloseMainWindow, not Stop-Process: it is the graceful path, so Chrome
  # writes its session state and restores tabs next launch.
  say "-> closing Chrome gracefully..."
  powershell.exe -NoProfile -Command "
    Get-Process chrome -ErrorAction SilentlyContinue |
      Where-Object { \$_.MainWindowHandle -ne 0 } |
      ForEach-Object { [void]\$_.CloseMainWindow() }
  " >/dev/null 2>&1

  for _ in $(seq 1 15); do
    left=$(powershell.exe -NoProfile -Command \
      "(Get-Process chrome -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -d '\r\n ')
    [ "${left:-0}" = "0" ] && break
    sleep 1
  done

  if [ "${left:-0}" != "0" ]; then
    say "   ${left} process(es) still up after 15s -- a dialog may be blocking the close."
    say "   Close Chrome by hand, then re-run this script."
    exit 1
  fi
  say "   closed."
fi

_LOCALAPPDATA=$(powershell.exe -NoProfile -Command '$env:LOCALAPPDATA' 2>/dev/null | tr -d '\r')
[ -z "$_LOCALAPPDATA" ] && { say "Could not resolve LOCALAPPDATA."; exit 1; }
USER_DATA="${_LOCALAPPDATA}\\Google\\Chrome\\User Data"

say "-> relaunching Chrome with --remote-debugging-port=${DEBUG_PORT}..."
nohup powershell.exe -NoProfile -Command \
  "Start-Process -FilePath '${CHROME_WIN}' -ArgumentList '--remote-debugging-port=${DEBUG_PORT}','--user-data-dir=${USER_DATA}','--profile-directory=Default'" \
  >/dev/null 2>&1 &

for i in $(seq 1 20); do
  port_up && { say "   port ${DEBUG_PORT} up after ~$((i * 2))s."; break; }
  sleep 2
done

if ! port_up; then
  say "Chrome did not expose :${DEBUG_PORT}. Launch it by hand with that flag."
  exit 1
fi

if run_scraper; then
  say "Done. Statusline should read 'usage data updated just now'."
else
  say "Port is up but the scrape failed -- you may need to re-login to claude.ai"
  say "or platform.claude.com in the new window. See scrape_claude_usage.log"
  exit 1
fi
