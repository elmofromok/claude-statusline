# claude-statusline

A status line for [Claude Code](https://claude.com/claude-code) that tells you when the
model is about to get dumber.

```
[Opus 5] my-project (main*) 84k smart $1.37
```

Segments, left to right:

| Segment      | Meaning |
|--------------|---------|
| `[Opus 5]`   | Active model's display name |
| `my-project` | Current directory (basename only) |
| `(main*)`    | Git branch; a red `*` means the working tree is dirty |
| `84k smart`  | Absolute context tokens used, plus the quality zone |
| `70% win`    | Context-window fill — only shown at 70%+, when the hard limit is actually in play |
| `$1.37`      | Session cost so far |

## The smart / dumb zone

The token segment is the point of this status line. It's built on
[Matt Pocock's smart-zone / dumb-zone framing](https://www.aihero.dev/dictionary-of-ai-coding):
model quality decays with **absolute** context length, not with how full the window is.
A 1M-token window is mostly dumb zone, so a percentage tells you almost nothing about
whether the model is still sharp.

| Zone    | Tokens      | Color  | What it means |
|---------|-------------|--------|---------------|
| `smart` | < 125k      | green  | Sharp, good recall |
| `edge`  | 125k – 150k | yellow | Start thinking about wrapping up or compacting |
| `dumb`  | > 150k      | red    | Sloppier, forgetful, more hallucinations |

Budget against those token counts. Window fill is a separate failure mode, so it gets its
own segment and stays hidden until it matters.

## Install

```bash
curl -o ~/.claude/statusline.sh \
  https://raw.githubusercontent.com/elmofromok/claude-statusline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then point Claude Code at it. **`~/.claude/settings.json` probably already has keys in it**
(`permissions`, `enabledPlugins`, `tui`, and so on) — you need to *merge* the `statusLine`
key in, not paste over the file. If you have `jq`, this does it safely:

```bash
jq '.statusLine = {"type": "command", "command": "~/.claude/statusline.sh"}' \
  ~/.claude/settings.json > ~/.claude/settings.json.tmp \
  && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
```

Editing by hand instead? Add just this one key alongside whatever is already there:

```json
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
```

So a config that started as `{"tui": "fullscreen"}` ends up as:

```json
{
  "tui": "fullscreen",
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

Starting from no config at all, the whole file is just the `{ "statusLine": ... }` object.

Requires `bash` and a Python 3 interpreter. No packages, no network calls.

## Design notes

**It never blocks.** This script runs on every assistant message, and `git status` costs
~1.25s on a Windows drive mounted under WSL (`/mnt/c`). So the dirty flag is read from a
10-second cache in the temp dir, and a refresh is kicked off as a fully detached child
process. Worst case the `*` is ten seconds stale; it is never worth a stall.

**It's portable between WSL and Windows Git Bash.** Two things bite you there:

- `python3` on Windows often resolves to a Microsoft Store alias stub that prints an
  install advert instead of running anything, so any candidate under `WindowsApps` is
  skipped when picking an interpreter.
- Windows paths contain backslashes that a shell command string would mangle, so the
  background refresh is spawned as `[sys.executable, "-c", SRC, root, cache]` — paths
  travel as argv entries and never touch a shell.

**Claude Code's JSON arrives on stdin**, which the heredoc that carries the Python source
also needs, so the payload is handed over through an environment variable instead.

**It degrades instead of failing.** No interpreter found prints `[claude]` and exits 0.
Older payloads without `total_input_tokens` get the token count reconstructed from the
percentage and window size. Git detection walks up the tree and handles worktrees and
submodules, where `.git` is a file pointing elsewhere rather than a directory.

## License

MIT
