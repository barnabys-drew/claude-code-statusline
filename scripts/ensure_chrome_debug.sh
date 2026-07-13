#!/usr/bin/env bash
# SessionStart hook: makes sure Chrome's remote-debugging port is available
# for scrape_claude_usage.py (cron, every 5 min) to read Fable/Sonnet usage.
# Never kills an already-running Chrome — only launches fresh when nothing
# is running at all. Otherwise just leaves a note; the statusline cache
# degrades gracefully to "stale" rather than blocking on this.
set -u

DEBUG_PORT=9222
CHROME_WIN='C:\Program Files\Google\Chrome\Application\chrome.exe'

if curl -s --connect-timeout 2 "http://localhost:${DEBUG_PORT}/json/version" >/dev/null 2>&1; then
  exit 0
fi

command -v powershell.exe >/dev/null 2>&1 || exit 0

count=$(powershell.exe -NoProfile -Command \
  "(Get-Process chrome -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -d '\r\n ')

if [ "${count:-1}" != "0" ]; then
  echo "[usage scraper] Chrome is running without --remote-debugging-port=${DEBUG_PORT} — Fable/Sonnet usage stats will stay stale until you relaunch it with that flag." >&2
  exit 0
fi

_LOCALAPPDATA=$(powershell.exe -NoProfile -Command '$env:LOCALAPPDATA' 2>/dev/null | tr -d '\r')
[ -z "$_LOCALAPPDATA" ] && exit 0
USER_DATA="${_LOCALAPPDATA}\\Google\\Chrome\\User Data"

nohup powershell.exe -NoProfile -Command \
  "Start-Process -FilePath '${CHROME_WIN}' -ArgumentList '--remote-debugging-port=${DEBUG_PORT}','--user-data-dir=${USER_DATA}','--profile-directory=Default'" \
  >/dev/null 2>&1 &

exit 0
