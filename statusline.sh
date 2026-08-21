#!/usr/bin/env bash
# Claude Code status line.
# Renders: [model] directory (branch*) NN% ctx $C.CC
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
import os, sys, json, re, time, hashlib, tempfile, subprocess

RESET  = "\033[0m"
DIM    = "\033[2m"
GREEN  = "\033[32m"
YELLOW = "\033[33m"
RED    = "\033[31m"

CACHE_TTL = 10  # seconds before the dirty flag is refreshed in the background

# Smart zone / dumb zone (Matt Pocock, dictionary-of-ai-coding). Quality decays
# with absolute context length, NOT with how full the window is -- a 1M window
# is mostly dumb zone. Budget against these token counts, not a percentage.
SMART_MAX = 125_000   # below this: sharp, good recall
DUMB_MIN  = 150_000   # above this: sloppier, forgetful, more hallucinations
WINDOW_WARN = 70      # only mention window % once the hard limit is in play

# Source for the detached child that refreshes the dirty flag. Run via
# [sys.executable, "-c", REFRESH_SRC, root, cache] so paths travel as argv
# entries and never pass through a shell -- Windows paths contain backslashes
# that a shell command string would mangle.
REFRESH_SRC = """
import os, sys, subprocess
root, cache = sys.argv[1], sys.argv[2]
try:
    out = subprocess.run(["git", "-C", root, "status", "--porcelain"],
                         capture_output=True, timeout=60).stdout
    val = b"1" if out.strip() else b"0"
except Exception:
    val = b"0"
tmp = cache + ".%d.tmp" % os.getpid()
try:
    with open(tmp, "wb") as f:
        f.write(val)
    os.replace(tmp, cache)
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
"""


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
                return p, b
        parent = os.path.dirname(p)
        if parent == p:
            return None, None
        p = parent


def dirty_flag(root):
    """Return the cached dirty state, refreshing it in the background if stale.

    Never blocks: git status costs ~1.25s over /mnt/c, and this script runs on
    every assistant message.
    """
    cdir = os.path.join(tempfile.gettempdir(), "cc-statusline")
    try:
        os.makedirs(cdir, exist_ok=True)
    except Exception:
        return False

    cache = os.path.join(cdir, hashlib.sha1(root.encode("utf-8")).hexdigest()[:16])
    val, fresh = False, False
    try:
        st = os.stat(cache)
        val = open(cache).read().strip() == "1"
        fresh = (time.time() - st.st_mtime) < CACHE_TTL
    except Exception:
        pass

    if not fresh:
        kw = {}
        if os.name == "posix":
            kw["start_new_session"] = True
        else:
            kw["creationflags"] = 0x00000008 | 0x08000000  # DETACHED | NO_WINDOW
        try:
            subprocess.Popen([sys.executable, "-c", REFRESH_SRC, root, cache],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, **kw)
        except Exception:
            pass
    return val


def main():
    try:
        d = json.loads(os.environ.get("CC_STATUSLINE_JSON") or "{}")
    except Exception:
        d = {}

    model = (d.get("model") or {}).get("display_name") or "?"
    cwd   = (d.get("workspace") or {}).get("current_dir") or d.get("cwd") or ""
    pct   = (d.get("context_window") or {}).get("used_percentage")
    cost  = (d.get("cost") or {}).get("total_cost_usd")

    seg = ["[%s]" % model]

    parts = [x for x in re.split(r"[/\\]", cwd) if x]
    if parts:
        seg.append(DIM + parts[-1] + RESET)

    root, b = resolve_git(cwd) if cwd else (None, None)
    if root and b:
        mark = RESET + RED + "*" + RESET + DIM if dirty_flag(root) else ""
        seg.append(DIM + "(" + b + mark + ")" + RESET)

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
