#!/usr/bin/env bash
# Claude Code custom statusline.
# Requires: python3, git (optional)

# Quota rows come straight from the hook payload (rate_limits.five_hour and
# .seven_day), which is live, exact, and carries reset times as unix epochs.
#
# This used to be scraped from the claude.ai settings page, because the page
# also carried a per-model Fable cap the CLI never exposed. That cap no longer
# exists — the page now shows only "Current session" and "All models", the same
# two buckets the payload already provides — so the scrape was pure overhead
# for those rows and is gone.
#
# scripts/scrape_claude_usage.py is still the only source for the two billing
# rows (usage credits, Console API credits), which the payload does not carry.
# Those move slowly, so a stale reading there is far less misleading than a
# stale session quota was.
#
# Rows are configurable via STATUSLINE_ROWS — see ROW_BUILDERS below.
IFS='|' read -r session_name model_name ctx_size used_pct total_in total_out \
               cache_tokens cwd repo_owner repo_name git_worktree \
               budget_lines_b64 < <(python3 -c '
import sys, json, os, time, base64, datetime

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

def _fmt_delta(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return "under a min"
    h, m = divmod(seconds // 60, 60)
    if h and m:
        return f"{h} hr {m} min"
    if h:
        return f"{h} hr"
    return f"{m} min"

def fmt_epoch(ts):
    """Render a rate_limits resets_at (unix epoch) as a countdown when it is
    close and an absolute stamp when it is not.

    The payload giving epochs is what let the old weekday-string parser go. It
    had to guess which Friday "Fri 1:59 PM" meant, re-guessed on every render,
    and so could never show a reset as overdue."""
    try:
        ts = float(ts)
    except Exception:
        return "-"
    delta = ts - time.time()
    if delta <= 0:
        return "now"
    if delta < 86400:
        return "in " + _fmt_delta(delta)
    return datetime.datetime.fromtimestamp(ts).strftime("%a %b %-d, %-I:%M %p")

def g(*keys):
    node = d
    for k in keys:
        if not isinstance(node, dict):
            return ""
        node = node.get(k)
        if node is None:
            return ""
    return str(node)

cu = d.get("context_window", {}).get("current_usage", {})
cache_tok = (cu.get("cache_read_input_tokens") or 0) + (cu.get("cache_creation_input_tokens") or 0)

GREEN="\033[0;32m"; CYAN="\033[0;36m"; GRAY="\033[0;90m"
BLUE="\033[0;34m"; BOLD="\033[1m"; RESET="\033[0m"; RED="\033[0;31m"
YELLOW="\033[0;33m"

def bar(pct):
    try:
        pct = float(pct)
    except Exception:
        pct = 0.0
    width = 10
    # Round rather than truncate: int() made 99.9% and 90% render identically.
    filled = max(0, min(width, int(round((pct / 100) * width))))
    # Never show a full bar below the cap — a rounded 95% must stay visibly short
    # of 100%, or "nearly out" and "out" look the same.
    if filled == width and pct < 100:
        filled = width - 1
    return "▬" * filled + "○" * (width - filled)

def fmt_age(updated_at):
    diff = time.time() - updated_at
    if diff < 60:
        return "just now"
    if diff < 3600:
        return f"{int(diff / 60)}m ago"
    if diff < 86400:
        return f"{diff / 3600:.1f}h ago"
    return f"{int(diff / 86400)}d ago"

usage_cache_path = os.path.expanduser(
    os.environ.get("CLAUDE_USAGE_CACHE") or "~/.claude/claude-usage-cache.json")
try:
    with open(usage_cache_path) as f:
        usage = json.load(f)
except Exception:
    usage = {}

updated_at = usage.get("updated_at")
STALE_AFTER = 900  # 3x the 5-min scrape interval
is_stale = (updated_at is None) or (time.time() - updated_at > STALE_AFTER)

# "Session (Claude Pro)" is 20 chars and used to overflow a 14-char field,
# knocking that one row out of alignment with the four below it.
LBL = 20

def row_age(entry):
    """Per-row fetch time. cache.update() merges partial scrapes, so a row whose
    regex quietly stopped matching keeps its old value under a fresh top-level
    updated_at — only the row stamp catches that."""
    ts = (entry or {}).get("_fetched_at") or updated_at
    return (None if ts is None else time.time() - ts), ts

def row_dot(entry):
    age, _ = row_age(entry)
    if age is None or age > STALE_AFTER:
        return f"{GRAY}○{RESET}"
    return f"{GREEN}●{RESET}"

def row_mark(entry):
    """Flag a row that is materially older than the scrape as a whole."""
    age, ts = row_age(entry)
    if age is None or updated_at is None:
        return ""
    if age - (time.time() - updated_at) > STALE_AFTER:
        return f"  {YELLOW}(row from {fmt_age(ts)}){RESET}"
    return ""

def render_live(label, bucket):
    """A quota row from the payload. Always current, so no staleness marking —
    it is read fresh on every render rather than out of a cache."""
    if not bucket:
        return None  # rate_limits is absent until the first API response
    p = float(bucket.get("used_percentage") or 0)
    resets = fmt_epoch(bucket.get("resets_at"))
    return (f"  {GREEN}●{RESET} {CYAN}{label:<{LBL}}{RESET} {BOLD}{p:5.1f}%{RESET}  "
            f"{BLUE}{bar(p)}{RESET}  {GRAY}resets {resets}{RESET}")

def render_credits(label, entry):
    if not entry:
        return f"  {GRAY}○{RESET} {CYAN}{label:<{LBL}}{RESET} {GRAY}no data{RESET}"
    p = float(entry.get("used_pct", 0))
    spent = entry.get("spent")
    limit = entry.get("limit")
    # Billing reset strings ("Aug 1", "Aug 1, 2026") are already unambiguous,
    # so they print as scraped.
    resets = entry.get("resets") or "-"
    detail = f"${spent}/${limit} resets {resets}"
    bal = entry.get("balance")
    warn = ""
    if bal:
        # Labelled "credit" rather than "bal": this is a prepaid credit balance,
        # not limit-minus-spent, and reading it as remaining budget is wrong.
        detail += f"  credit {bal}"
        if bal.strip().startswith("-"):
            auto_reload = entry.get("auto_reload", "?")
            warn = f"  {RED}{BOLD}![unpaid, auto-reload {auto_reload}]{RESET}"
    return (f"  {row_dot(entry)} {CYAN}{label:<{LBL}}{RESET} {BOLD}{p:5.1f}%{RESET}  "
            f"{BLUE}{bar(p)}{RESET}  {GRAY}{detail}{RESET}{warn}{row_mark(entry)}")

plan = usage.get("plan")
rate_limits = d.get("rate_limits") or {}

# Which rows to draw, in order. Override with STATUSLINE_ROWS, e.g.
#   STATUSLINE_ROWS=session,weekly          # quota only, no billing
#   STATUSLINE_ROWS=session,weekly,plan_credits
#
# Any rate_limits bucket can be added as "rl:<key>[=Label]" without touching
# this file. That is the hook for a per-model cap coming back: Anthropic
# retired the Fable-specific quota, but if a bucket like rate_limits.opus
# appears, STATUSLINE_ROWS=session,weekly,rl:opus=Opus renders it. Only the
# payload key needs to exist — there is no scraping involved.
DEFAULT_ROWS = "session,weekly,plan_credits,api_credits"

def build_session():
    label = f"Session (Claude {plan})" if plan else "Session"
    return [render_live(label, rate_limits.get("five_hour"))]

def build_weekly():
    row = render_live("All models", rate_limits.get("seven_day"))
    if not row:
        return []  # annotation must not outlive the row it annotates
    sub = f"  {GRAY}Claude {plan} subscription (active){RESET}" if plan else None
    return [row, sub]

def build_plan_credits():
    return [render_credits("Plan credits", usage.get("credits")),
            f"  {GRAY}↑ usage-credits overflow (optional add-on){RESET}"]

def build_api_credits():
    return [render_credits("API credits", usage.get("console_credits")),
            f"  {GRAY}↑ separate account — not used by Claude Code{RESET}"]

ROW_BUILDERS = {
    "session": build_session,
    "weekly": build_weekly,
    "plan_credits": build_plan_credits,
    "api_credits": build_api_credits,
}

wanted = [r.strip() for r in os.environ.get("STATUSLINE_ROWS", DEFAULT_ROWS).split(",") if r.strip()]
uses_cache = any(r in ("plan_credits", "api_credits") for r in wanted)

lines = []
for row_id in wanted:
    if row_id.startswith("rl:"):
        spec = row_id[3:]
        key, _, label = spec.partition("=")
        lines.append(render_live(label or key.replace("_", " ").title(), rate_limits.get(key)))
    else:
        builder = ROW_BUILDERS.get(row_id)
        if builder:
            lines.extend(builder())
lines = [l for l in lines if l]  # drop absent rows and empty annotations

# Freshness gets its own line. It used to be appended to the API-credits
# footnote above, where the leading arrow tied it visually to that one row —
# so a whole-cache staleness warning read as a note about API credits, and the
# five rows above it looked live when they were two days old.
_REASONS = {
    "no-cdp": "Chrome not on debug port :9222",
    "no-data": "page scrape returned nothing (session expired?)",
    "error":   "scraper crashed",
}
last_run = usage.get("last_run") or {}
status = last_run.get("status")

if not uses_cache:
    # No cached row is displayed, so there is nothing whose freshness matters
    # and no reason to mention the scraper at all.
    pass
elif updated_at is None:
    lines.append(f"  {RED}{BOLD}⚠ no usage data yet — bash ~/.claude/scripts/fix_usage_scrape.sh{RESET}")
elif is_stale:
    why = _REASONS.get(status, "scraper not running")
    if status in ("ok", "partial", None) and last_run.get("at"):
        why = "last run " + fmt_age(last_run["at"])
    lines.append(f"  {RED}{BOLD}⚠ usage data {fmt_age(updated_at)} — {why}{RESET}"
                 f"  {RED}fix: bash ~/.claude/scripts/fix_usage_scrape.sh{RESET}")
elif status == "partial":
    missed = ", ".join(last_run.get("failed") or []) or "some rows"
    lines.append(f"  {YELLOW}◑ partial scrape {fmt_age(updated_at)} — missed {missed}{RESET}")
else:
    lines.append(f"  {GRAY}usage data updated {fmt_age(updated_at)}{RESET}")

budget_block = "\n".join(lines)
budget_lines_b64 = base64.b64encode(budget_block.encode()).decode()

fields = [
    g("session_name"),
    g("model", "display_name"),
    g("context_window", "context_window_size"),
    g("context_window", "used_percentage"),
    g("context_window", "total_input_tokens"),
    g("context_window", "total_output_tokens"),
    str(cache_tok),
    g("workspace", "current_dir") or g("cwd"),
    g("workspace", "repo", "owner"),
    g("workspace", "repo", "name"),
    g("workspace", "git_worktree"),
    budget_lines_b64,
]
print("|".join(fields))
')

# ANSI colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
RESET='\033[0m'
BOLD='\033[1m'

# 10-char progress bar matching screenshot style (filled=▬, empty=○)
progress_bar() {
  local pct="${1:-0}"
  local width=10
  local filled
  filled=$(awk -v p="$pct" -v w="$width" 'BEGIN{printf "%d", (p/100)*w}')
  local empty=$(( width - filled ))
  local bar=""
  for ((i=0; i<filled; i++)); do bar="${bar}▬"; done
  for ((i=0; i<empty;  i++)); do bar="${bar}○"; done
  printf "%s" "$bar"
}

fmt_tokens() {
  awk -v n="${1:-0}" 'BEGIN{
    if (n+0>=1000000) printf "%.1fM",n/1000000
    else if (n+0>=1000) printf "%.1fk",n/1000
    else printf "%d",n
  }'
}

fmt_ctx_label() {
  awk -v n="${1:-0}" 'BEGIN{
    if (n+0>=1000000) printf "%dM context",n/1000000
    else if (n+0>=1000) printf "%dk context",n/1000
    else printf "%d context",n
  }'
}

# Row 1: session name tag (top-right style)
if [ -n "$session_name" ]; then
  printf "${GREEN}${BOLD} %s ${RESET}\n" "$session_name"
fi

# Row 2: Context
if [ -n "$used_pct" ]; then
  bar=$(progress_bar "$used_pct")
  printf "  ${GREEN}●${RESET} ${CYAN}Context${RESET}   ${BOLD}%.1f%%${RESET}  ${BLUE}%s${RESET}  ${GRAY}↓%s  ↑%s  ~%s${RESET}\n" \
    "$used_pct" "$bar" "$(fmt_tokens "$total_in")" "$(fmt_tokens "$total_out")" "$(fmt_tokens "$cache_tokens")"
else
  printf "  ${GREEN}●${RESET} ${CYAN}Context${RESET}  ${GRAY}—${RESET}\n"
fi

# Rows 3-5: Session / All models / Fable usage, from the claude.ai scrape cache
if [ -n "$budget_lines_b64" ]; then
  printf '%s\n' "$(printf '%s' "$budget_lines_b64" | base64 -d)"
fi

# Row 5: Model | location branch
model_label=""
if [ -n "$model_name" ]; then
  model_label="${model_name} ($(fmt_ctx_label "$ctx_size"))"
fi

location=""
if [ -n "$repo_owner" ] && [ -n "$repo_name" ]; then
  location="${repo_owner}/${repo_name}"
elif [ -n "$cwd" ]; then
  location=$(basename "$cwd")
fi

branch=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null || \
           git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
fi
[ -n "$git_worktree" ] && branch="${branch:+$branch/}${git_worktree}"

bottom=""
[ -n "$model_label" ] && bottom="${BOLD}${model_label}${RESET}"
[ -n "$location" ]    && bottom="${bottom}  ${GRAY}|${RESET}  ${CYAN}...${location}${RESET}"
[ -n "$branch" ]      && bottom="${bottom}  ${GRAY}${branch}${RESET}"
[ -n "$bottom" ]      && printf "  %b\n" "$bottom"
