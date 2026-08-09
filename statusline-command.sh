#!/usr/bin/env bash
# Claude Code custom statusline.
# Requires: python3, git (optional)
#
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
# Every row is rendered by the embedded Python so they share one alignment
# grid; bash only adds the session title and the git/model footer. Rows are
# selected with STATUSLINE_ROWS — see ROW_BUILDERS below.
#
# The leading marker on each row answers "what is paying for this session?".
# ▸ marks the one billing pool the next request draws from, ○ a billing pool
# that is not currently paying, · a row that is not a billing pool at all.
# Staleness is flagged inline per row and in the warning lines instead — it
# used to own this column, which made three unrelated rows look like a ladder.
#
# Fields are passed back on a single line separated by US (0x1f) rather than
# "|", which a session name or branch could contain.
IFS=$'\x1f' read -r session_name model_label cwd repo_owner repo_name \
                    git_worktree pr_segment budget_lines_b64 < <(python3 -c '
import sys, json, os, time, base64, datetime

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

GREEN="\033[0;32m"; CYAN="\033[0;36m"; GRAY="\033[0;90m"
BLUE="\033[0;34m"; BOLD="\033[1m"; RESET="\033[0m"; RED="\033[0;31m"
YELLOW="\033[0;33m"

# Label column. "Session (Claude Pro)" is 20 chars and used to overflow a
# 14-char field, knocking that one row out of alignment with the rest.
LBL = 20
# Width of the percent + bar columns, for rows that have neither and need to
# line their detail up with rows that do.
PAD = " " * 21


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

def fmt_tokens(n):
    n = n or 0
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1000:
        return f"{n / 1000:.1f}k"
    return str(int(n))

def fmt_ctx_size(n):
    n = n or 0
    if n >= 1_000_000:
        return f"{n // 1_000_000}M context"
    if n >= 1000:
        return f"{n // 1000}k context"
    return f"{n} context"

def fmt_dur(seconds):
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m}m"
    if m:
        return f"{m}m"
    return f"{s}s"

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


def row_age(entry):
    """Per-row fetch time. cache.update() merges partial scrapes, so a row whose
    regex quietly stopped matching keeps its old value under a fresh top-level
    updated_at — only the row stamp catches that."""
    ts = (entry or {}).get("_fetched_at") or updated_at
    return (None if ts is None else time.time() - ts), ts

# Billing markers. Colour escalates with how the money is spent: green is
# included in the subscription, yellow is overflow spend on top of it, red is
# metered API spend. ○ is a billing pool that exists but is not paying now;
# · is a row that is not a billing pool (context, session-cost estimate).
MARK_INFO = f"{GRAY}·{RESET}"
MARK_IDLE = f"{GRAY}○{RESET}"
MARK_PAY = {"quota":   f"{GREEN}{BOLD}▸{RESET}",
            "credits": f"{YELLOW}{BOLD}▸{RESET}",
            "api":     f"{RED}{BOLD}▸{RESET}"}
PAY_NOTE = {"quota":   f"  {GREEN}{BOLD}◂ billing here{RESET}",
            "credits": f"  {YELLOW}{BOLD}◂ billing here — quota spent{RESET}",
            "api":     f"  {RED}{BOLD}◂ billing here — metered API{RESET}"}

def row_mark(entry):
    """Flag a row that is materially older than the scrape as a whole."""
    age, ts = row_age(entry)
    if age is None or updated_at is None:
        return ""
    if age - (time.time() - updated_at) > STALE_AFTER:
        return f"  {YELLOW}(row from {fmt_age(ts)}){RESET}"
    return ""


def bar_row(dot, label, pct, detail, suffix=""):
    return (f"  {dot} {CYAN}{label:<{LBL}}{RESET} {BOLD}{pct:5.1f}%{RESET}  "
            f"{BLUE}{bar(pct)}{RESET}  {GRAY}{detail}{RESET}{suffix}")

def plain_row(dot, label, detail):
    """A row with no percentage — detail is padded onto the same column as the
    bar rows so the block still reads as one grid."""
    return f"  {dot} {CYAN}{label:<{LBL}}{RESET}{PAD}{GRAY}{detail}{RESET}"

def render_live(label, bucket, suffix=""):
    """A quota row from the payload. Always current, so no staleness marking —
    it is read fresh on every render rather than out of a cache."""
    if not bucket:
        return None  # rate_limits is absent until the first API response
    pct = float(bucket.get("used_percentage") or 0)
    marker = MARK_PAY["quota"] if paying == "quota" else MARK_IDLE
    return bar_row(marker, label, pct,
                   "resets " + fmt_epoch(bucket.get("resets_at")), suffix)

# Below this, a negative balance is settlement lag or rounding rather than an
# account in arrears — a one-cent debt does not need a warning, and the balance
# itself is already printed either way.
UNPAID_MIN = 1.00

def owed(bal):
    """Dollars this account is behind, or 0. A balance renders with a leading
    minus, e.g. -$12.40, when the account owes money."""
    s = (bal or "").strip()
    if not s.startswith("-"):
        return 0.0
    try:
        return float("".join(c for c in s if c.isdigit() or c == "."))
    except ValueError:
        return 0.0

def render_credits(label, entry, marker, note="", is_paying=False):
    if not entry:
        return f"  {marker} {CYAN}{label:<{LBL}}{RESET} {GRAY}no data{RESET}"
    pct = float(entry.get("used_pct", 0))
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
        due = owed(bal)
        if due >= UNPAID_MIN:
            # Loud only when it can actually bite: an unpaid balance on the pool
            # currently paying stops the session, on any other pool it is a
            # note. auto-reload is only claimed when the scrape knows it.
            ar = entry.get("auto_reload")
            tail = f", auto-reload {ar}" if ar in ("on", "off") else ""
            # The amount is not repeated — the balance it refers to is printed
            # immediately to the left.
            style = f"{RED}{BOLD}" if is_paying else YELLOW
            warn = f"  {style}unpaid{tail}{RESET}"
    return bar_row(marker, label, pct, detail, warn + note + row_mark(entry))


plan = usage.get("plan")
rate_limits = d.get("rate_limits") or {}
ctx = d.get("context_window") or {}
cost = d.get("cost") or {}

# Which of the three pools is paying for this session. This is the question the
# statusline exists to answer, so it is worked out once here and drives the
# markers on every billing row.
#
#   quota   — the rolling 5-hour / 7-day subscription limits. Free at point of
#             use; pays until either limit reaches 100%.
#   credits — the usage-credit overflow add-on on that same plan. Takes over
#             from quota at 100% so the session keeps running, and costs money.
#   api     — a Console (platform.claude.com) account, billed per token. This is
#             an *alternative* to the subscription, not a step after it: a
#             session authenticated with an API key never touches quota or plan
#             credits, and a subscription session never touches this.
#
# Detection: an API key in the environment is decisive. Otherwise rate_limits
# is the fingerprint of a subscription — the payload only carries it for
# Claude.ai plans. It is absent until the first API response, so a session that
# has already been billed (non-zero cost) while carrying no buckets is an
# API-key session whose key came from somewhere other than this environment.
api_key_auth = bool(os.environ.get("ANTHROPIC_API_KEY")
                    or os.environ.get("ANTHROPIC_AUTH_TOKEN"))
_pcts = [float((rate_limits.get(k) or {}).get("used_percentage") or 0)
         for k in ("five_hour", "seven_day") if rate_limits.get(k)]
_billed = float(cost.get("total_cost_usd") or 0) > 0

if api_key_auth or (_billed and not _pcts):
    paying = "api"
elif _pcts:
    paying = "credits" if max(_pcts) >= 100 else "quota"
else:
    paying = None  # nothing billed yet — say nothing rather than guess

# Which rows to draw, in order. Override with STATUSLINE_ROWS, e.g.
#   STATUSLINE_ROWS=context,session,weekly       # no billing, no scraper
#   STATUSLINE_ROWS=context,cost
#
# Any rate_limits bucket can be added as "rl:<key>[=Label]" without touching
# this file. That is the hook for a per-model cap coming back: Anthropic
# retired the Fable-specific quota, but if a bucket like rate_limits.opus
# appears, STATUSLINE_ROWS=session,weekly,rl:opus=Opus renders it. Only the
# payload key needs to exist — there is no scraping involved.
DEFAULT_ROWS = "context,session,weekly,cost,plan_credits,api_credits"

def build_context():
    pct = ctx.get("used_percentage")
    if pct is None:
        return []
    cu = ctx.get("current_usage") or {}
    cache = (cu.get("cache_read_input_tokens") or 0) + (cu.get("cache_creation_input_tokens") or 0)
    tin = fmt_tokens(ctx.get("total_input_tokens"))
    tout = fmt_tokens(ctx.get("total_output_tokens"))
    detail = f"↓{tin}  ↑{tout}  ~{fmt_tokens(cache)}"
    return [bar_row(MARK_INFO, "Context", float(pct), detail)]

def build_session():
    label = f"Session (Claude {plan})" if plan else "Session"
    suffix = PAY_NOTE["quota"] if paying == "quota" else ""
    return [render_live(label, rate_limits.get("five_hour"), suffix)]

def build_weekly():
    row = render_live("All models", rate_limits.get("seven_day"))
    if not row:
        return []  # annotation must not outlive the row it annotates
    sub = f"  {GRAY}Claude {plan} subscription (active){RESET}" if plan else None
    return [row, sub]

def build_cost():
    """Cost, burn rate and diff churn for this session.

    Deliberately kept apart from the credit rows: those are billed figures read
    off Anthropic dashboards, this one is a client-side estimate that resets on
    /clear. Same grid, no bar, and an annotation saying which it is."""
    usd = cost.get("total_cost_usd")
    if usd is None:
        return []
    secs = (cost.get("total_duration_ms") or 0) / 1000.0
    parts = [f"${usd:,.2f}"]
    if secs >= 60:  # a rate over a few seconds is noise
        parts.append(f"${usd / (secs / 3600):,.2f}/hr")
    added = cost.get("total_lines_added") or 0
    removed = cost.get("total_lines_removed") or 0
    if added or removed:
        parts.append(f"+{added}/-{removed}")
    if secs:
        parts.append(fmt_dur(secs))
    return [plain_row(MARK_INFO, "This session", "  ·  ".join(parts)),
            f"  {GRAY}↑ client-side estimate, resets on /clear{RESET}"]

def build_plan_credits():
    on = paying == "credits"
    return [render_credits("Plan credits", usage.get("credits"),
                           MARK_PAY["credits"] if on else MARK_IDLE,
                           PAY_NOTE["credits"] if on else "", on),
            f"  {GRAY}↑ overflow add-on — takes over when session/weekly hits 100%{RESET}"]

def build_api_credits():
    on = paying == "api"
    return [render_credits("API credits", usage.get("console_credits"),
                           MARK_PAY["api"] if on else MARK_IDLE,
                           PAY_NOTE["api"] if on else "", on),
            f"  {GRAY}↑ Console account — pays instead of the plan when authed by API key{RESET}"]

ROW_BUILDERS = {
    "context": build_context,
    "session": build_session,
    "weekly": build_weekly,
    "cost": build_cost,
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
# footnote, where the leading arrow tied it visually to that one row — so a
# whole-cache staleness warning read as a note about API credits, and the rows
# above it looked live when they were two days old.
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

budget_lines_b64 = base64.b64encode("\n".join(lines).encode()).decode()

# Model plus how it is configured. effort/thinking/fast materially affect both
# speed and spend, so they belong next to the name rather than hidden.
model = d.get("model") or {}
bits = []
if ctx.get("context_window_size"):
    bits.append(fmt_ctx_size(ctx.get("context_window_size")))
effort = (d.get("effort") or {}).get("level")
if effort:
    bits.append("effort " + str(effort))
if (d.get("thinking") or {}).get("enabled"):
    bits.append("thinking")
if d.get("fast_mode"):
    bits.append("fast")
name = model.get("display_name") or ""
model_label = name + (" (" + " · ".join(bits) + ")" if (name and bits) else "")

# Open PR for this branch, coloured by review state.
pr = d.get("pr") or {}
pr_segment = ""
if pr.get("number"):
    state = pr.get("review_state") or ""
    colour = {"approved": GREEN, "changes_requested": RED,
              "pending": YELLOW, "draft": GRAY}.get(state, GRAY)
    suffix = (" " + state.replace("_", " ")) if state else ""
    number = pr.get("number")
    pr_segment = f"{colour}PR #{number}{suffix}{RESET}"

def g(*keys):
    node = d
    for k in keys:
        if not isinstance(node, dict):
            return ""
        node = node.get(k)
        if node is None:
            return ""
    return str(node)

print("\x1f".join([
    g("session_name"),
    model_label,
    g("workspace", "current_dir") or g("cwd"),
    g("workspace", "repo", "owner"),
    g("workspace", "repo", "name"),
    g("workspace", "git_worktree"),
    pr_segment,
    budget_lines_b64,
]))
')

GRAY='\033[0;90m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'
BOLD='\033[1m'

# Session title
if [ -n "$session_name" ]; then
  printf "${GREEN}${BOLD} %s ${RESET}\n" "$session_name"
fi

# All usage rows, rendered above on one shared alignment grid
if [ -n "$budget_lines_b64" ]; then
  printf '%s\n' "$(printf '%s' "$budget_lines_b64" | base64 -d)"
fi

# Footer: model | location branch [dirty] [ahead/behind] [PR]
location=""
if [ -n "$repo_owner" ] && [ -n "$repo_name" ]; then
  location="${repo_owner}/${repo_name}"
elif [ -n "$cwd" ]; then
  location=$(basename "$cwd")
fi

branch=""
git_state=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null || \
           git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    # head -1 short-circuits the walk; we only need to know whether anything
    # is dirty, not what.
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | head -1)" ]; then
      git_state=" ${YELLOW}●${RESET}"
    fi
    # "behind<TAB>ahead" against the upstream; empty when there is no upstream.
    counts=$(git -C "$cwd" --no-optional-locks rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)
    if [ -n "$counts" ]; then
      behind=${counts%%[[:space:]]*}
      ahead=${counts##*[[:space:]]}
      [ "${ahead:-0}" -gt 0 ] 2>/dev/null && git_state="${git_state} ${CYAN}↑${ahead}${RESET}"
      [ "${behind:-0}" -gt 0 ] 2>/dev/null && git_state="${git_state} ${CYAN}↓${behind}${RESET}"
    fi
  fi
fi
[ -n "$git_worktree" ] && branch="${branch:+$branch/}${git_worktree}"

bottom=""
[ -n "$model_label" ] && bottom="${BOLD}${model_label}${RESET}"
[ -n "$location" ]    && bottom="${bottom}  ${GRAY}|${RESET}  ${CYAN}...${location}${RESET}"
[ -n "$branch" ]      && bottom="${bottom}  ${GRAY}${branch}${RESET}${git_state}"
[ -n "$pr_segment" ]  && bottom="${bottom}  ${pr_segment}"
[ -n "$bottom" ]      && printf "  %b\n" "$bottom"
