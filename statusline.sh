#!/usr/bin/env bash
# Claude Code status line.
# Renders: [model] directory (branch) NN% ctx $C.CC
# Portable between WSL (python3) and Windows Git Bash (python).
# The JSON that Claude Code pipes in on stdin is handed to Python via the
# environment, leaving stdin free for the heredoc below.

input=$(cat)

# Pick an interpreter. On Windows, `python3` often resolves to a Microsoft Store
# alias stub that prints an install advert instead of running anything, so skip
# anything under WindowsApps.
PY=""
for cand in python3 python; do
  p=$(command -v "$cand" 2>/dev/null) || continue
  case "$p" in
    *WindowsApps*) continue ;;
  esac
  PY="$p"
  break
done

if [ -z "$PY" ]; then
  # No interpreter: degrade to something rather than nothing.
  printf '%s\n' "[claude]"
  exit 0
fi

CC_STATUSLINE_JSON="$input" exec "$PY" - <<'PYEOF'
import os, sys, json, re

RESET  = "\033[0m"
DIM    = "\033[2m"
GREEN  = "\033[32m"
YELLOW = "\033[33m"
RED    = "\033[31m"


# Smart zone / dumb zone (Matt Pocock, dictionary-of-ai-coding). Quality decays
# with absolute context length, NOT with how full the window is -- a 1M window
# is mostly dumb zone. Budget against these token counts, not a percentage.
SMART_MAX = 125_000   # below this: sharp, good recall
DUMB_MIN  = 150_000   # above this: sloppier, forgetful, more hallucinations
WINDOW_WARN = 70      # only mention window % once the hard limit is in play

def git_dir(root):
    g = os.path.join(root, ".git")
    if os.path.isdir(g):
        return g
    try:  # worktree or submodule: .git is a file pointing elsewhere
        line = open(g).read().strip()
    except Exception:
        return None
    if line.startswith("gitdir:"):
        gd = line.split(":", 1)[1].strip()
        return gd if os.path.isabs(gd) else os.path.join(root, gd)
    return None


def branch_name(root):
    gd = git_dir(root)
    if not gd:
        return None
    try:
        head = open(os.path.join(gd, "HEAD")).read().strip()
    except Exception:
        return None
    if head.startswith("ref: refs/heads/"):
        return head[len("ref: refs/heads/"):]
    if head.startswith("ref: "):
        return head[5:].rsplit("/", 1)[-1]
    return head[:7] if head else None


def short_model(disp, mid):
    """"Opus 5 (1M context)" -> "Opus 5 (1M)". The word "context" is the only
    part that varies with nothing, and it costs eight always-on characters."""
    if not disp:
        return mid or "?"
    return re.sub(r"\s+context\)", ")", disp)


def fmt_tokens(n):
    n = int(n)
    return "%dk" % round(n / 1000.0) if n >= 1000 else str(n)


def resolve_git(start):
    """Walk up for a repo, skipping invalid .git stubs the way git itself does."""
    p = os.path.abspath(start)
    while True:
        if os.path.exists(os.path.join(p, ".git")):
            b = branch_name(p)
            if b:
                return b
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent


def main():
    try:
        d = json.loads(os.environ.get("CC_STATUSLINE_JSON") or "{}")
    except Exception:
        d = {}

    mdl   = d.get("model") or {}
    cwd   = (d.get("workspace") or {}).get("current_dir") or d.get("cwd") or ""
    pct   = (d.get("context_window") or {}).get("used_percentage")
    cost  = (d.get("cost") or {}).get("total_cost_usd")

    seg = ["[%s]" % short_model(mdl.get("display_name"), mdl.get("id"))]

    parts = [x for x in re.split(r"[/\\]", cwd) if x]
    if parts:
        seg.append(DIM + parts[-1] + RESET)

    b = resolve_git(cwd) if cwd else None
    if b:
        seg.append(DIM + "(" + b + ")" + RESET)

    cw = d.get("context_window") or {}
    tokens = cw.get("total_input_tokens")
    size = cw.get("context_window_size")
    if not isinstance(tokens, (int, float)) or tokens <= 0:
        # Older payloads: reconstruct absolute tokens from the percentage.
        tokens = (pct / 100.0 * size
                  if isinstance(pct, (int, float)) and isinstance(size, (int, float))
                  else None)

    if isinstance(tokens, (int, float)) and tokens > 0:
        if tokens < SMART_MAX:
            label, color = "smart", GREEN
        elif tokens < DUMB_MIN:
            label, color = "edge", YELLOW
        else:
            label, color = "dumb", RED
        seg.append("%s%s %s%s" % (color, fmt_tokens(tokens), label, RESET))

    # The window limit is a separate failure mode: surface it only when near.
    if isinstance(pct, (int, float)) and pct >= WINDOW_WARN:
        seg.append("%s%d%% win%s" % (YELLOW if pct < 90 else RED, round(pct), RESET))

    if isinstance(cost, (int, float)):
        seg.append("$%.2f" % cost)

    sys.stdout.write(" ".join(seg) + "\n")


main()
PYEOF
