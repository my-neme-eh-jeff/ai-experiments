"""Regenerates the README images from demo/render.sh output.

    python3 demo/screenshots.py

Every image is the statusline's real output for a made-up session (see render.sh), turned into
HTML and screenshotted with headless Chrome. Standard library only. Set CHROME if Chrome is not
at the macOS default path.
"""
import html
import os
import re
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
WIDTH = 1600
LINE = 35.1  # px per terminal row: 23.4px font x 1.5 line-height

ANSI_BASE = {"37": "#c9ccd1", "90": "#6b7280", "36": "#56b6c2", "33": "#e5c07b"}


def ansi_to_html(text):
    out, color, bold = [], None, False
    for part in re.split(r"(\x1b\[[0-9;]*m)", text):
        m = re.fullmatch(r"\x1b\[([0-9;]*)m", part)
        if m:
            codes = m.group(1).split(";")
            if codes[:2] == ["38", "2"]:
                color = "rgb(%s,%s,%s)" % tuple(codes[2:5])
            elif codes == ["0"]:
                color, bold = None, False
            else:
                bold = codes[0] == "1"
                color = ANSI_BASE.get(codes[-1], color)
            continue
        if not part:
            continue
        style = ([f"color:{color}"] if color else []) + (["font-weight:700;color:#f4f4f5"] if bold else [])
        esc = html.escape(part)
        out.append(f'<span style="{";".join(style)}">{esc}</span>' if style else esc)
    return "".join(out)


def render(scenario, columns=100):
    env = dict(os.environ, COLUMNS=str(columns))
    raw = subprocess.run(["bash", os.path.join(HERE, "render.sh"), scenario], env=env,
                         capture_output=True, text=True, check=True).stdout
    return [ansi_to_html(l) for l in raw.rstrip("\n").split("\n")]


def comment(text):
    return f'<span class="c"># {html.escape(text)}</span>'


CSS = """
:root { color-scheme: dark; }
* { box-sizing: border-box; margin: 0; }
body { background: #0b0d10; width: %(w)dpx; height: %(h)dpx; display: flex; flex-direction: column;
       justify-content: center; padding: 0 70px; font-family: -apple-system, "Helvetica Neue", sans-serif; }
.term { background: #15181d; border: 1px solid #262a31; border-radius: 14px; overflow: hidden;
        box-shadow: 0 30px 80px rgba(0,0,0,.45); }
.bar { height: 38px; display: flex; align-items: center; gap: 9px; padding: 0 16px;
       background: #1b1f25; border-bottom: 1px solid #262a31; }
.bar i { width: 12px; height: 12px; border-radius: 50%%; background: #3a3f47; display: block; }
.rows { padding: 22px 26px; }
pre { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: %(fs)spx; line-height: 1.5;
      color: #c9ccd1; white-space: pre; }
.c { color: #5b6370; font-style: italic; }
.gap { display: block; height: 12px; }
.label { font: 600 15px/1 -apple-system, sans-serif; letter-spacing: .14em; text-transform: uppercase;
         color: #6b7280; margin: 0 0 10px 4px; }
.state + .state { margin-top: 26px; }
.side { display: flex; gap: 28px; }
.side > div { flex: 1; }
.legend { margin-top: 34px; display: grid; grid-template-columns: auto 1fr; gap: 16px 34px; align-items: baseline; }
.legend pre { font-size: 21px; }
.legend p { color: #aab0b9; font-size: 21px; line-height: 1.45; }
"""


def term(lines):
    body = "\n".join(lines)
    return f'<div class="term"><div class="bar"><i></i><i></i><i></i></div><div class="rows"><pre>{body}</pre></div></div>'


def shoot(name, inner, height, font=23.4):
    doc = f"<!doctype html><meta charset=utf-8><style>{CSS % {'w': WIDTH, 'h': height, 'fs': font}}</style><body>{inner}</body>"
    with tempfile.TemporaryDirectory() as tmp:
        page = os.path.join(tmp, f"{name}.html")
        with open(page, "w") as f:
            f.write(doc)
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
                        f"--user-data-dir={tmp}/profile", "--force-device-scale-factor=2",
                        f"--window-size={WIDTH},{height}", f"--screenshot={HERE}/{name}.png", f"file://{page}"],
                       check=True, capture_output=True)
    print(f"demo/{name}.png")


def frame_height(n_lines, gaps=0, line=LINE):
    return 38 + 44 + 2 + n_lines * line + gaps * 12


def captioned(pairs):
    """One terminal: a dim comment line above each scenario's output, a small gap between groups."""
    groups, n = [], 0
    for text, scenario in pairs:
        out = render(scenario)
        groups.append("\n".join([comment(text)] + out))
        n += 1 + len(out)
    return term(['<span class="gap"></span>'.join(groups)]), n, len(groups) - 1


def main():
    # Hero: one session calm, heating up, at the limit. 16:9 so it also works as a post image.
    states = [("calm", "Calm"), ("heating", "Heating up"), ("wall", "At the limit")]
    shoot("states", "".join(f'<div class="state"><div class="label">{lab}</div>{term(render(s))}</div>'
                            for s, lab in states), 900)

    heat = render("heating")
    legend = [
        ("🧠 64%", "Context used. Green to red, so you see compaction coming."),
        ("🔋 5h 72% → 100% in 1h06m", "Only what can stop you. Nothing under 60% is shown. The forecast appears only if you'd hit the limit before it resets."),
        ("☁ demo (…)", "Shown only while the AWS SSO token is still valid."),
        ("⎇ infra(main) ⚠×1", "Another live session is editing this same checkout."),
        ("⎇ api(…)·wt ⑃ main", "Same repo, separate worktree. No conflict."),
    ]
    rows = "".join(f"<pre>{html.escape(a)}</pre><p>{html.escape(b)}</p>" for a, b in legend)
    shoot("anatomy", term(heat) + f'<div class="legend">{rows}</div>', 900)

    body, n, gaps = captioned([
        ("5h window at 45%: under 60%, so it isn't shown", "limit-under"),
        ("68% with 30m left: shown, no forecast because the reset comes first", "limit-quiet"),
        ("72% with 2h10m left: at this pace it runs out before the reset", "limit-forecast"),
        ("spent: marked ! with the time until it lifts", "limit-wall"),
        ("two limits: the one blocking you goes first", "limit-ranked"),
    ])
    shoot("limits", body, int(frame_height(n, gaps) + 140))

    ctx = [render(f"ctx-{p}")[0] for p in (8, 30, 52, 74, 93)]
    shoot("context", term([comment("context used: green at 0%, yellow at 50%, red at 100%")] + ctx),
          int(frame_height(1 + len(ctx)) + 140))

    a, b = render("session-a", 60), render("session-b", 60)
    side = "".join(f'<div><div class="label">{lab}</div>{term(out)}</div>'
                   for lab, out in (("Session A", a), ("Session B", b)))
    shoot("sessions", f'<div class="side">{side}</div>', int(frame_height(max(len(a), len(b)), line=19 * 1.5) + 25 + 140), font=19)

    body, n, gaps = captioned([
        ("SSO token valid", "sso-valid"),
        ("ten minutes after it expired", "sso-expired"),
    ])
    shoot("credentials", body, int(frame_height(n, gaps) + 140))


if __name__ == "__main__":
    main()
