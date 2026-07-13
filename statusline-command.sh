#!/usr/bin/env bash
# Claude Code custom statusline.
# Requires: python3, git (optional)

# The rate_limits object in the hook payload only ever reports the blended
# "All models" bucket, even when Fable is the active model — Fable's own
# dedicated quota isn't exposed to the CLI at all. ~/.claude/scripts/
# scrape_claude_usage.py (run on a cron) pulls the real per-model numbers
# from the claude.ai usage settings page instead; this just reads that cache.
IFS='|' read -r session_name model_name ctx_size used_pct total_in total_out \
               cache_tokens cwd repo_owner repo_name git_worktree \
               budget_lines_b64 < <(python3 -c '
import sys, json, os, time, base64

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

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

def bar(pct):
    try:
        pct = float(pct)
    except Exception:
        pct = 0.0
    width = 10
    filled = max(0, min(width, int((pct / 100) * width)))
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

usage_cache_path = os.path.expanduser("~/.claude/claude-usage-cache.json")
try:
    with open(usage_cache_path) as f:
        usage = json.load(f)
except Exception:
    usage = {}

updated_at = usage.get("updated_at")
STALE_AFTER = 900  # 3x the 5-min scrape interval
is_stale = (updated_at is None) or (time.time() - updated_at > STALE_AFTER)

def render_row(label, entry):
    if not entry:
        return f"  {GRAY}○{RESET} {CYAN}{label:<14}{RESET} {GRAY}no data{RESET}"
    p = float(entry.get("used_pct", 0))
    resets = entry.get("resets", "-")
    dot = f"{GRAY}○{RESET}" if is_stale else f"{GREEN}●{RESET}"
    return f"  {dot} {CYAN}{label:<14}{RESET} {BOLD}{p:5.1f}%{RESET}  {BLUE}{bar(p)}{RESET}  {GRAY}resets {resets}{RESET}"

def render_credits(label, entry):
    if not entry:
        return f"  {GRAY}○{RESET} {CYAN}{label:<14}{RESET} {GRAY}no data{RESET}"
    p = float(entry.get("used_pct", 0))
    dot = f"{GRAY}○{RESET}" if is_stale else f"{GREEN}●{RESET}"
    spent = entry.get("spent")
    limit = entry.get("limit")
    resets = entry.get("resets", "-")
    detail = f"${spent}/${limit} resets {resets}"
    bal = entry.get("balance")
    warn = ""
    if bal:
        detail += f"  bal {bal}"
        if bal.strip().startswith("-"):
            auto_reload = entry.get("auto_reload", "?")
            warn = f"  {RED}{BOLD}![unpaid, auto-reload {auto_reload}]{RESET}"
    return f"  {dot} {CYAN}{label:<14}{RESET} {BOLD}{p:5.1f}%{RESET}  {BLUE}{bar(p)}{RESET}  {GRAY}{detail}{RESET}{warn}"

plan = usage.get("plan")
session_label = f"Session (Claude {plan})" if plan else "Session"

# This terminal authenticates via claudeAiOauth (~/.claude/.credentials.json),
# never an API key — it draws Session/All models/Fable first, then overflows
# into Plan credits if that toggle is on. API credits (platform.claude.com)
# is a separate account this terminal never touches.
lines = [
    render_row(session_label, usage.get("current_session")),
    render_row("All models", usage.get("all_models")),
    render_row("Fable", usage.get("fable")),
    f"  {GRAY}Claude {plan} subscription (active){RESET}" if plan else "",
    render_credits("Plan credits", usage.get("credits")),
    f"  {GRAY}↑ usage-credits overflow (optional add-on){RESET}",
    render_credits("API credits", usage.get("console_credits")),
]
lines = [l for l in lines if l]  # filter out empty strings

# Add the API credits annotation with timestamp on same line
if updated_at:
    age_str = fmt_age(updated_at)
    stale_note = " (stale)" if is_stale else ""
    api_line = f"  {GRAY}↑ separate account — not used by Claude Code  updated {age_str}{stale_note}{RESET}"
else:
    api_line = f"  {GRAY}↑ separate account — not used by Claude Code  (no scrape yet){RESET}"
lines.append(api_line)

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
