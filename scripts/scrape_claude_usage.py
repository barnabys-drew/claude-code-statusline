#!/usr/bin/env python3
"""
Scrapes two separate Anthropic billing surfaces for the statusline:

  - claude.ai/code#settings/usage: Pro/Max plan limits (Current session,
    weekly "All models" + Fable-specific cap) and the plan's optional
    usage-credits overflow. The Claude Code statusLine hook only ever
    reports the blended "All models" figure, never Fable's own cap.
  - platform.claude.com/settings/billing: separate Console/API credit
    balance and monthly spend limit — a different account/product from
    the claude.ai plan, used when something (Claude Code included) draws
    on the API credit pool instead of the plan quota.

Requires a real (non-headless) Chrome window already running with
--remote-debugging-port=9222, logged into BOTH sites — headless browsers
get stopped by Cloudflare's bot challenge even with valid session cookies.
Never launches or kills Chrome itself; if the debug port isn't up, or a
session has expired, it just leaves the existing cache file (and its
staleness) alone.
"""
import json
import os
import re
import time

CACHE_FILE = os.path.expanduser("~/.claude/claude-usage-cache.json")
CDP_URL = "http://localhost:9222"


def parse_usage(text):
    result = {}
    plan_m = re.search(r"Plan usage limits\s*\n\s*(\w+)\n", text)
    if plan_m:
        result["plan"] = plan_m.group(1)
    for key, label in [
        ("current_session", "Current session"),
        ("all_models", "All models"),
        ("fable", "Fable"),
    ]:
        m = re.search(re.escape(label) + r"\s*\n\s*Resets (.+?)\n\s*(\d+)% used", text)
        if m:
            result[key] = {"resets": m.group(1).strip(), "used_pct": int(m.group(2))}

    m = re.search(r"\$([\d,.]+) spent\s*\n\s*Resets (.+?)\n\s*(\d+)% used", text)
    limit_m = re.search(r"\$([\d,.]+)\s*\n\s*Monthly spend limit", text)
    balance_m = re.search(r"(-?\$[\d,.]+)\s*\n\s*Current balance", text)
    if m and limit_m:
        result["credits"] = {
            "spent": m.group(1),
            "limit": limit_m.group(1),
            "used_pct": int(m.group(3)),
            "resets": m.group(2).strip(),
            "balance": balance_m.group(1) if balance_m else None,
        }
    return result


def parse_console_billing(text):
    result = {}
    m = re.search(r"(-?\$[\d,.]+)\s*\n\s*\w+ balance\s*[·\-]\s*Auto reload (on|off)", text, re.IGNORECASE)
    if m:
        result["balance"] = m.group(1)
        result["auto_reload"] = m.group(2).lower()
    m2 = re.search(r"\$([\d,.]+) spent\s*\n\s*Resets (.+?)\n\s*(\d+)% used", text)
    if m2:
        result["spent"] = m2.group(1)
        result["resets"] = m2.group(2).strip()
        result["used_pct"] = int(m2.group(3))
    m3 = re.search(r"Monthly spend limit\s*\n\s*Adjust limit\s*\n\s*\$([\d,.]+)", text)
    if m3:
        result["limit"] = m3.group(1)
    return result if "used_pct" in result else None


def find_or_open_tab(ctx, domain):
    for p in ctx.pages:
        if domain in p.url:
            return p, False
    return ctx.new_page(), True


def scrape_claude_ai(ctx):
    page, opened_new_tab = find_or_open_tab(ctx, "claude.ai")
    try:
        page.goto("https://claude.ai/code", timeout=15_000)
        page.wait_for_load_state("domcontentloaded", timeout=10_000)
        time.sleep(2)

        if "sign in" in page.title().lower():
            return None  # session expired — needs a manual re-login

        # Ctrl+Shift+, opens Settings directly — avoids clicking the account
        # menu by display name, which obviously isn't portable across accounts.
        page.keyboard.press("Control+Shift+,")
        time.sleep(1)
        page.get_by_text("Usage", exact=True).first.click(timeout=3000)
        page.get_by_text("Plan usage limits", exact=True).first.wait_for(timeout=10_000)

        body_text = ""
        for _ in range(20):
            body_text = page.inner_text("body")
            idx = body_text.find("Plan usage limits")
            if idx != -1 and "Loading" not in body_text[idx:idx + 600]:
                break
            time.sleep(0.25)

        usage = parse_usage(body_text)

        page.keyboard.press("Escape")  # close the settings modal
        time.sleep(0.3)
        return usage or None
    finally:
        if opened_new_tab:
            page.close()
        else:
            page.goto("https://claude.ai/code", timeout=15_000)


def scrape_console_billing(ctx):
    page, opened_new_tab = find_or_open_tab(ctx, "platform.claude.com")
    try:
        page.goto("https://platform.claude.com/settings/billing", timeout=15_000)
        page.wait_for_load_state("domcontentloaded", timeout=10_000)

        if "sign in" in page.title().lower():
            return None  # session expired — needs a manual re-login

        page.get_by_text("Credit balance", exact=True).first.wait_for(timeout=10_000)

        # The balance figure itself loads async behind a "Loading" placeholder
        # even after the "Credit balance" heading is present — poll until it resolves.
        body_text = ""
        for _ in range(20):
            body_text = page.inner_text("body")
            idx = body_text.find("Credit balance")
            if idx != -1 and "Loading" not in body_text[idx:idx + 300]:
                break
            time.sleep(0.25)

        return parse_console_billing(body_text)
    finally:
        if opened_new_tab:
            page.close()


def main():
    from playwright.sync_api import sync_playwright

    with sync_playwright() as pw:
        try:
            browser = pw.chromium.connect_over_cdp(CDP_URL, timeout=3000)
        except Exception:
            return  # Chrome not up on the debug port — leave cache as-is

        ctx = browser.contexts[0] if browser.contexts else browser.new_context()

        try:
            with open(CACHE_FILE) as f:
                cache = json.load(f)
        except Exception:
            cache = {}

        got_anything = False

        try:
            usage = scrape_claude_ai(ctx)
            if usage:
                cache.update(usage)
                got_anything = True
        except Exception:
            pass

        try:
            console = scrape_console_billing(ctx)
            if console:
                cache["console_credits"] = console
                got_anything = True
        except Exception:
            pass

        if not got_anything:
            return

        cache["updated_at"] = time.time()
        tmp = CACHE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cache, f)
        os.replace(tmp, CACHE_FILE)


if __name__ == "__main__":
    main()
