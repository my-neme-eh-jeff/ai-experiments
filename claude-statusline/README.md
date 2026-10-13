# The Art of the Status Line

*A Claude Code status line that stays quiet until something can stop you.*

Everyone's in a terminal with a coding agent now, and the status line is the one line you read on every turn. On a busy day I have seven or eight Claude Code sessions open, so that line sits under every one of them. I've spent a few weeks on mine, mostly inside those same sessions. This is what it shows, what it refuses to show, and the bugs that decided both.

![The same session calm, heating up, and at the limit](demo/states.png)

Line 1 is the model, context used, cost, and anything that can stop you. Line 2 is where your commands will land: the kube context, and the AWS profile while its login is still valid. Below that are the repos this session has touched.

![Each part of the status line, labelled](demo/anatomy.png)

## It started by disappearing

The first version was a ccstatusline config with my kube context and session cost. Then I wanted one more thing: a list of the repos this session had touched. I built that by running `git status` across every repo in my code folder, all 43 of them, every 5 seconds.

Two bugs followed. The line would vanish at random, and every so often it listed every repo I own.

The vanishing had a simple cause. A tick took 40 seconds or more, and Claude Code cancels a status line script that is still running when the next refresh fires. So it never rendered, and at one point 12 copies were running at once across my sessions.

That gave me the rule everything else follows: **one process per render.** The whole line is one `jq` call plus bash builtins. No git, no network. The version in this folder renders in a median of 18 ms on an M4, including starting bash.

## Track what this session did, not what git says

The second bug, every repo showing up, would have survived a faster script. Git state is shared by every terminal tab. When I checked, one repo was flagged in all 8 of my open sessions, including tabs that had never opened it. Diffing git can't tell "I changed this" from "another session changed it".

Now a PostToolUse hook does the recording. Each Edit or Write records the repo of the file it changed. Each Bash command records any repo it `cd`s into or points `git -C` at. Parallel tool calls can fire two recorders at the same moment, so the log is append-only and duplicates are removed when it's read. The status line only reads a file.

## Tell a collision from a worktree

Once each session knew its own repos, I could see when two sessions were in the same one. Two agents in one checkout is how you get a stale `index.lock` and edits on top of edits. Two agents in separate worktrees of the same repo are fine, and shouldn't be flagged.

![Two sessions, each warning about the shared checkout and noting the separate worktree](demo/sessions.png)

Git tells the two cases apart. `--show-toplevel` names the checkout and `--git-common-dir` names the repository behind it. Same checkout gets `⚠×1`. Same repository but a different checkout gets `⑃` plus the other session's branch. A session only counts if its status line ticked in the last two minutes, so a tab you closed yesterday doesn't haunt you.

## Show what can stop you, not everything you have

Claude Code reports two plan windows, five hours and one week. Most of the time both are fine, and a number that is always fine is one you stop reading. Then you also stop reading it when it isn't fine.

I went through a lot here. There were chips for every window, a pie chart and a bar for about six minutes (I like numbers more), and dollars against a cap. Eventually I asked myself what the minimum was that I needed to watch. The answer became these rules:

- A window under 60% gets no space.
- At most two show at a time.
- One you've used up comes first, marked `!` with the time until it lifts. Next comes whichever runs out soonest.

![Five rows showing when a limit appears, when it forecasts, and how two are ranked](demo/limits.png)

## Forecast only when it changes the answer

"72%" doesn't tell you whether you'll make it. The forecast takes your average burn since the window opened and extrapolates. If that reaches 100% before the window resets, it says when: `→ 100% in 1h06m`. If the reset comes first, it says nothing, because there's nothing to do.

## Context goes green to red

![Context at 8, 30, 52, 74 and 93 percent](demo/context.png)

The percentage moves along a smooth gradient, yellow at 50% and red near 100%. You see compaction coming without reading the number.

## Show credentials only while they work

An expired AWS profile printed in yellow looks exactly like a live one. So the AWS part disappears the moment the SSO token expires. To check, the script reads only `expiresAt` from the SSO cache and never touches the token itself.

![The AWS part shown while the token is valid, gone ten minutes after it expires](demo/credentials.png)

## Write nothing on most ticks

This script runs in every open session, so its cost multiplies. Slowing the refresh from 5 to 15 seconds took my terminal app from 34% CPU to 22%, just from repainting less often.

Files got the same treatment. Every file the script writes is an event that Spotlight, endpoint security and every file watcher on the machine pick up. So the debug sample is written once per session instead of every tick, and the liveness marker is rewritten at most once a minute. The tab title is only written when it changes, which also stops a raw write on every tick from garbling the UI.

## Three bugs worth stealing the fix for

**Separate fields with `\x1f`, not tab.** Bash `read` treats tab as whitespace and merges a run of them. One empty field shifts every value after it, and my line once said `57598%`. The ASCII unit separator isn't whitespace, so empty fields stay put.

**`//` in jq treats `false` as missing.** "Cache cold" means `prompt_cache.warm` is `false`. A fallback written with `//` swaps that `false` for the default, so a cold cache read as warm and the warning never fired. Compare with `== false` explicitly.

**Bash counts characters, the terminal counts columns.** Each emoji is one character and two columns. To right-align the session title, the script measures a plain twin of the line where every emoji is written as `oo`.

All of it runs on bash 3.2, because that's what `/bin/bash` still is on macOS.

## Try it without installing

From this folder:

```sh
bash demo/render.sh            # calm, heating, wall
bash demo/render.sh limit-ranked session-a sso-expired
```

The demo runs the real script against made-up sessions in a throwaway HOME, and every image on this page comes from it. A screenshot of my own terminal would show a real cluster, account ID and repo names. `python3 demo/screenshots.py` regenerates the images.

## Install

Needs `bash`, `jq` and `git`.

```sh
git clone --depth 1 https://github.com/my-neme-eh-jeff/ai-experiments.git
mkdir -p ~/.claude/statusline
cp ai-experiments/claude-statusline/{statusline.sh,touched-lib.sh,touch-record.sh} ~/.claude/statusline/
```

Add to `~/.claude/settings.json`:

```json
{
  "env": { "CLAUDE_STATUSLINE_CODE_DIR": "/Users/you/code" },
  "statusLine": { "type": "command", "command": "~/.claude/statusline/statusline.sh", "padding": 0, "refreshInterval": 15 },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit|NotebookEdit|Bash",
        "hooks": [{ "type": "command", "command": "bash ~/.claude/statusline/touch-record.sh", "timeout": 10, "async": true }]
      }
    ]
  }
}
```

`CLAUDE_STATUSLINE_CODE_DIR` is the folder your repos live in, one level deep (`~/code/<repo>`). It defaults to `~/code`, and repos outside it aren't tracked. If the status line doesn't pick it up from `env`, export it in your shell profile instead.

## What it reads and writes

- **Reads:**
  - the JSON Claude Code pipes in;
  - `current-context` from your kubeconfig;
  - the active `AWS_PROFILE` block in `~/.aws/config`;
  - `expiresAt` from that profile's SSO cache;
  - `effortLevel` from `~/.claude/settings.json`.
- **Writes:** only under `~/.cache/claude-statusline/`. The hook deletes files older than 14 days, at most once a day.
- **Never:** makes a network call or prints a token.

Limits come from the `rate_limits` field Claude Code sends, which appears on Pro and Max plans after the first response. Without it, the limit block doesn't show.

## See also

This started as a [ccstatusline](https://github.com/sirmalloc/ccstatusline) config. If you want something configurable rather than opinionated, these are good:

- [ccstatusline](https://github.com/sirmalloc/ccstatusline)
- [claude-hud](https://github.com/jarrodwatts/claude-hud)
- [ccusage statusline](https://ccusage.com/guide/statusline)
- [claude-powerline](https://github.com/Owloops/claude-powerline)
- [claude-pace](https://github.com/Astro-Han/claude-pace)
