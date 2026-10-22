#!/usr/bin/env python3
"""Builds the README images in media/ from the app's own fixture renders.

1. `HeadroomApp --render all` draws every UI state offscreen (no live data).
2. Each README image is laid out as a small HTML page around those renders.
3. Headless Chrome captures each page at 2x; pngquant shrinks the result when available.

Run with `make screenshots` (needs Google Chrome; pngquant is optional).
"""
import html
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MEDIA = ROOT / "media"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

INK = "#F4F4F6"
MUTED = "#8A8D96"
STATE = {"plenty": "#6AA8FF", "onpace": "#ECEDF1", "tight": "#FFC248", "verytight": "#FF6982"}

BASE_CSS = f"""
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
html, body {{ background: transparent; }}
body {{ font-family: -apple-system, "SF Pro Text", system-ui, sans-serif; -webkit-font-smoothing: antialiased; color: {INK}; }}
.panel {{ border-radius: 28px; padding: 34px 34px 38px;
  background: radial-gradient(120% 60% at 50% 0%, rgba(255,255,255,.06), rgba(255,255,255,0) 60%), linear-gradient(180deg, #17181D, #0F1014);
  box-shadow: inset 0 0 0 1px rgba(255,255,255,.07), inset 0 1px 0 rgba(255,255,255,.08); }}
.eyebrow {{ display: flex; align-items: center; gap: 8px; height: 18px; margin: 0 4px 12px;
  font: 600 10.5px/1 ui-monospace, "SF Mono", Menlo, monospace; letter-spacing: .14em; text-transform: uppercase; color: {MUTED}; }}
.eyebrow i {{ width: 7px; height: 7px; border-radius: 50%; flex: none; }}
.shot {{ border-radius: 22px; overflow: hidden; position: relative; }}
.shot img {{ display: block; width: 100%; }}
.fade {{ -webkit-mask-image: linear-gradient(180deg, #000 78%, transparent); }}
.grid {{ display: grid; gap: 30px 26px; }}
"""


def run(cmd, **kw):
    subprocess.run(cmd, check=True, **kw)


def eyebrow(label, color=None):
    dot = f'<i style="background:{color};box-shadow:0 0 10px {color}"></i>' if color else ""
    return f'<div class="eyebrow">{dot}{html.escape(label)}</div>'


def shot(src, height=None, fade=0.78, position="top"):
    """A screenshot, optionally cropped to `height` px with a soft fade from `fade` (0–1) down."""
    if not height:
        return f'<div class="shot"><img src="{src}"></div>'
    mask = f"-webkit-mask-image:linear-gradient(180deg,#000 {int(fade * 100)}%,transparent)" if fade else ""
    if position == "bottom":
        mask = f"-webkit-mask-image:linear-gradient(0deg,#000 {int(fade * 100)}%,transparent)" if fade else ""
    return (f'<div class="shot" style="height:{height}px;{mask}">'
            f'<img src="{src}" style="object-fit:cover;object-position:{position};height:100%"></div>')


def png_size(path):
    """Pixel width and height from a PNG header."""
    with open(path, "rb") as f:
        head = f.read(24)
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def grid_height(rows, shot_h, gap=30):
    """Panel height for a grid of eyebrow + shot cells (padding 34 + 38, eyebrow 30)."""
    return 72 + rows * (30 + shot_h) + (rows - 1) * gap


def capture(name, body, width, height, raw, work, extra_css=""):
    page = work / f"{name}.html"
    page.write_text(f"<!doctype html><meta charset=utf-8><style>{BASE_CSS}{extra_css}</style>"
                    f"<body style='width:{width}px;height:{height}px'>{body}</body>")
    out = MEDIA / f"{name}.png"
    run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2",
         "--default-background-color=00000000", f"--window-size={width},{height}",
         f"--screenshot={out}", "--allow-file-access-from-files", page.as_uri()],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if shutil.which("pngquant"):
        subprocess.run(["pngquant", "--force", "--skip-if-larger", "--quality", "82-96", "--output", out, out],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"  {out.relative_to(ROOT)}")


def hero(theme, raw, work):
    dark = theme == "dark"
    ink = INK if dark else "#16171B"
    muted = "rgba(244,244,246,.66)" if dark else "rgba(22,23,27,.62)"
    wallpaper = ("radial-gradient(60% 70% at 88% 18%, rgba(74,142,255,.42), transparent 70%),"
                 "radial-gradient(55% 65% at 4% 96%, rgba(217,119,87,.34), transparent 70%),"
                 "radial-gradient(50% 60% at 62% 110%, rgba(16,163,127,.30), transparent 70%),"
                 "linear-gradient(160deg, #141833, #0C0E18 60%, #0A1A24)") if dark else (
                 "radial-gradient(60% 70% at 88% 14%, rgba(100,168,255,.45), transparent 70%),"
                 "radial-gradient(55% 65% at 2% 98%, rgba(240,160,132,.45), transparent 70%),"
                 "radial-gradient(50% 60% at 62% 112%, rgba(63,208,163,.35), transparent 70%),"
                 "linear-gradient(160deg, #E8EEF8, #F3EEF2 60%, #E6F1EE)")
    bar = "rgba(8,9,16,.42)" if dark else "rgba(255,255,255,.55)"
    chip_bg = "rgba(255,255,255,.07)" if dark else "rgba(255,255,255,.65)"
    chip_ring = "rgba(255,255,255,.08)" if dark else "rgba(22,23,27,.06)"
    states = [("Plenty", STATE["plenty"]), ("On pace", "#ECEDF1" if dark else "#3A3D44"),
              ("Getting tight", STATE["tight"]), ("Very tight", STATE["verytight"])]
    chips = "".join(f'<span class="chip"><i style="background:{c};box-shadow:0 0 9px {c}"></i>{t}</span>' for t, c in states)
    body = f"""
<div class="hero">
  <div class="bar">
    <img class="item" src="{raw}/statusitem-{theme}.png">
    <span class="clock">Tue 10:02</span>
  </div>
  <div class="copy">
    <div class="brand"><img src="{ROOT}/assets/icon.svg"><span>Headroom</span></div>
    <h1>Will this week's<br>allowance last?</h1>
    <p>See how much of your Claude and Codex allowance is left, against the time left until it renews. Right in your menu bar.</p>
    <div class="chips">{chips}</div>
  </div>
  <img class="popover" src="{raw}/pace-mockup-{theme}.png">
</div>"""
    css = f"""
.hero {{ position: relative; width: 960px; height: 600px; border-radius: 30px; overflow: hidden; background: {wallpaper};
  box-shadow: inset 0 0 0 1px {'rgba(255,255,255,.08)' if dark else 'rgba(0,0,0,.06)'}; }}
.bar {{ position: absolute; inset: 0 0 auto 0; height: 30px; background: {bar}; display: flex; align-items: center;
  justify-content: flex-end; gap: 18px; padding: 0 20px; }}
.item {{ height: 22px; }}
.clock {{ font: 500 13px -apple-system, system-ui; color: {ink}; opacity: .92; font-variant-numeric: tabular-nums; }}
.copy {{ position: absolute; left: 58px; top: 118px; width: 430px; }}
.brand {{ display: flex; align-items: center; gap: 12px; font: 650 21px -apple-system, system-ui; letter-spacing: -.01em; color: {ink}; }}
.brand img {{ width: 46px; height: 46px; filter: drop-shadow(0 6px 14px rgba(0,0,0,.28)); }}
h1 {{ margin-top: 30px; font: 800 50px/1.02 -apple-system, "SF Pro Display", system-ui; letter-spacing: -.035em; color: {ink}; }}
p {{ margin-top: 18px; font: 400 17px/1.5 -apple-system, system-ui; color: {muted}; max-width: 390px; }}
.chips {{ display: flex; flex-wrap: wrap; gap: 8px; margin-top: 28px; }}
.chip {{ display: inline-flex; align-items: center; gap: 7px; padding: 6px 11px 6px 9px; border-radius: 999px;
  font: 600 12.5px -apple-system, system-ui; color: {ink}; background: {chip_bg}; box-shadow: inset 0 0 0 1px {chip_ring}; }}
.chip i {{ width: 7px; height: 7px; border-radius: 50%; }}
.popover {{ position: absolute; right: 44px; top: 40px; width: 360px;
  filter: drop-shadow(0 24px 50px rgba(0,0,0,{'.55' if dark else '.22'})); }}
"""
    capture(f"hero-{theme}", body, 960, 600, raw, work, css)


def panel(name, content, width, height, raw, work, css=""):
    capture(name, f'<div class="panel" style="width:{width}px;height:{height}px">{content}</div>', width, height, raw, work, css)


def main():
    if not Path(CHROME).exists():
        sys.exit("Google Chrome is needed to capture the README images.")
    MEDIA.mkdir(exist_ok=True)
    for old in MEDIA.glob("*"):
        old.unlink()
    run(["swift", "build", "--product", "HeadroomApp"], cwd=ROOT, stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "raw"
        work = Path(tmp) / "pages"
        work.mkdir()
        run([str(ROOT / ".build/debug/HeadroomApp"), "--render", "all", "--out", str(raw)], stdout=subprocess.DEVNULL)
        print("Writing media/")

        hero("dark", raw, work)
        hero("light", raw, work)

        # Menu bar on three wallpapers.
        walls = [("Dark wallpaper", "dark", "linear-gradient(115deg,#1A2150,#3B2A5C 55%,#0F2F45)", "rgba(8,8,16,.32)", INK),
                 ("Light wallpaper", "light", "linear-gradient(115deg,#D6E4F7,#F4E2EC 55%,#D8EEE7)", "rgba(255,255,255,.5)", "#16171B"),
                 ("Busy wallpaper", "dark", "linear-gradient(100deg,#C2571F,#2C7A4B 35%,#B9C83A 62%,#3A3FB0)", "rgba(8,8,16,.3)", INK)]
        strips = "".join(f"""{eyebrow(label)}<div class="wall" style="background:{bg}"><div class="mb" style="background:{bar}">
            <img src="{raw}/statusitem-{theme}.png"><span style="color:{ink}">Tue 10:02</span></div></div>"""
                         for label, theme, bg, bar, ink in walls)
        panel("menubar", strips, 960, 382, raw, work, """
.wall { height: 64px; border-radius: 14px; overflow: hidden; margin-bottom: 22px; }
.wall:last-child { margin-bottom: 0; }
.mb { height: 30px; display: flex; align-items: center; justify-content: flex-end; gap: 18px; padding: 0 18px; }
.mb img { height: 22px; }
.mb span { font: 500 13px -apple-system, system-ui; font-variant-numeric: tabular-nums; }""")

        # Four pacing states, 2 x 2.
        cells = [("Plenty available", "plenty", STATE["plenty"]), ("On pace", "onpace", STATE["onpace"]),
                 ("Getting tight", "tight-projection", STATE["tight"]), ("Very tight", "verytight", STATE["verytight"])]
        grid = "".join(f"<div>{eyebrow(t, c)}{shot(f'{raw}/pace-{s}-dark.png', 640, fade=0.82)}</div>" for t, s, c in cells)
        panel("pace", f'<div class="grid" style="grid-template-columns:1fr 1fr">{grid}</div>', 960, grid_height(2, 640), raw, work)

        # Welcome window: four of its five steps, 2 x 2.
        steps = [("1 · Welcome", "onboarding-1-dark"), ("2 · Pick your tools", "onboarding-2-light"),
                 ("3 · Shape the menu bar", "onboarding-3-light"), ("4 · Tune the 5-hour warning", "onboarding-4-dark")]
        cell_w = (960 - 68 - 26) / 2
        sw, sh = png_size(raw / "onboarding-1-dark.png")
        step_h = round(cell_w * sh / sw)
        grid = "".join(f"<div>{eyebrow(t)}<div class='shot win'><img src='{raw}/{s}.png'></div></div>" for t, s in steps)
        panel("welcome", f'<div class="grid" style="grid-template-columns:1fr 1fr">{grid}</div>', 960, grid_height(2, step_h), raw, work,
              ".win { border-radius: 12px; box-shadow: 0 14px 34px rgba(0,0,0,.45); }")

        # 5-hour session: the detailed panel through its states, 2 x 3.
        levels = [("Not started", "idle", None), ("On track · forecast", "comfortable", STATE["onpace"]),
                  ("Heads-up · runs out before the reset", "runsout", STATE["tight"]), ("75% · amber warning", "amber", STATE["tight"]),
                  ("90% · rose warning", "rose", STATE["verytight"]), ("100% · paused until reset", "blocked", STATE["verytight"])]
        heights = []
        for _, s_, _ in levels:
            w_, h_ = png_size(raw / f"session-{s_}-dark.png")
            heights.append(cell_w * h_ / w_)
        row_h = [max(heights[i], heights[i + 1]) for i in (0, 2, 4)]
        grid = "".join(f"<div>{eyebrow(t, c)}<div class='shot'><img src='{raw}/session-{s_}-dark.png'></div></div>" for t, s_, c in levels)
        panel("session", f'<div class="grid" style="grid-template-columns:1fr 1fr;align-items:start">{grid}</div>', 960,
              round(72 + sum(30 + h for h in row_h) + 2 * 30), raw, work)

        # Recent 5-hour sessions (Activity tab), dark and light.
        sw, sh = png_size(raw / "sessions-dark.png")
        hist_h = round(cell_w * sh / sw)
        body = "".join(f"<div>{eyebrow(t)}<div class='shot'><img src='{raw}/sessions-{th}.png'></div></div>"
                       for t, th in (("Activity · 5-hour sessions", "dark"), ("Light appearance", "light")))
        panel("sessions", f'<div class="grid" style="grid-template-columns:1fr 1fr">{body}</div>', 960, grid_height(1, hist_h), raw, work)

        # Menu bar options.
        options = [("Default", "default"), ("Show the percentage", "percent"), ("Meter tracks the 5-hour session", "session"),
                   ("Whichever is tighter, with percentage", "tighter"), ("Most urgent only, timer always on", "urgent")]
        rows = "".join(f"""<div class="opt"><span>{html.escape(t)}</span><div class="wall"><div class="mb">
            <img src="{raw}/statusitem-{o}-dark.png"><em>Tue 10:02</em></div></div></div>""" for t, o in options)
        panel("customize", rows, 960, 72 + len(options) * 64 - 14, raw, work, """
.opt { display: grid; grid-template-columns: 300px 1fr; align-items: center; gap: 20px; margin-bottom: 14px; }
.opt span { font: 600 15px -apple-system, system-ui; color: #F4F4F6; padding-left: 4px; }
.wall { height: 50px; border-radius: 12px; overflow: hidden; background: linear-gradient(115deg,#1A2150,#3B2A5C 55%,#0F2F45);
  display: flex; align-items: center; }
.mb { height: 30px; width: 100%; display: flex; align-items: center; justify-content: flex-end; gap: 18px; padding: 0 16px; background: rgba(8,8,16,.32); }
.mb img { height: 22px; }
.mb em { font: normal 500 13px -apple-system, system-ui; color: #F4F4F6; font-variant-numeric: tabular-nums; }""")

        # Settings: the Pace Card and 5-hour sections, dark and light.
        sw, sh = png_size(raw / "settings-3-dark.png")
        set_h = round(cell_w * sh / sw)
        body = "".join(f"<div>{eyebrow(t)}<div class='shot win'><img src='{raw}/settings-{n}.png'></div></div>"
                       for t, n in (("Pace Card · meters and graphs", "3-dark"), ("5-hour session warning", "4-light")))
        panel("settings", f'<div class="grid" style="grid-template-columns:1fr 1fr">{body}</div>', 960, grid_height(1, set_h), raw, work,
              ".win { border-radius: 12px; box-shadow: 0 14px 34px rgba(0,0,0,.45); }")

        # Callouts: model caps, early reset, reset credits.
        calls = [("Model cap reached", "cap-empty-dark"), ("Model cap tighter than the week", "cap-tight-light"),
                 ("Early reset", "early-reset-dark"), ("Reset credits expiring", "credits-light")]
        grid = "".join(f"<div>{eyebrow(t)}{shot(f'{raw}/pace-{s}.png', 560, fade=0.8, position='bottom')}</div>" for t, s in calls)
        panel("callouts", f'<div class="grid" style="grid-template-columns:1fr 1fr">{grid}</div>', 960, grid_height(2, 560), raw, work)

        # Faults, 3 x 2, cropped to the banner.
        faults = [("Offline", "fault-offline-dark"), ("Signed out", "fault-signedout-light"), ("Format changed", "fault-schema-dark"),
                  ("Service outage", "fault-outage-light"), ("Enterprise plan", "fault-enterprise-dark"), ("CLI not found", "fault-cli-light")]
        grid = "".join(f"<div>{eyebrow(t)}{shot(f'{raw}/pace-{s}.png', 190, fade=0.86)}</div>" for t, s in faults)
        panel("faults", f'<div class="grid" style="grid-template-columns:1fr 1fr 1fr">{grid}</div>', 960, grid_height(2, 190), raw, work)

        # Activity and past weeks.
        body = f"""<div class="grid" style="grid-template-columns:1fr 1fr">
          <div>{eyebrow("Tokens and cost · 24 hours")}{shot(f'{raw}/activity-all-24h-light.png', 900, fade=0.9)}</div>
          <div>{eyebrow("Past weeks")}{shot(f'{raw}/activity-all-7d-dark.png', 900, fade=0.9, position='bottom')}</div></div>"""
        panel("activity", body, 960, grid_height(1, 900), raw, work)

        # Share card and text.
        text = html.escape((raw / "share-text.txt").read_text().split("\n\n")[0])
        body = f"""{eyebrow("Copy Card")}<div class="shot card"><img src="{raw}/share-card-claude.png"></div>
          <div class="row"><div>{eyebrow("Copy Snapshot")}<div class="shot card"><img src="{raw}/share-snapshot.png"></div></div>
          <div>{eyebrow("Copy as Text")}<pre>{text}</pre></div></div>"""
        inner = 960 - 68
        card_h = round(inner * 675 / 1200)
        snap_h = round((inner - 26) * 1.15 / 2.15 * 675 / 1200)
        share_h = 72 + 30 + card_h + 30 + 30 + snap_h
        panel("share", body, 960, share_h, raw, work, f"""
.card {{ border-radius: 18px; box-shadow: 0 0 0 1px rgba(255,255,255,.08), 0 20px 40px rgba(0,0,0,.4); }}
.row {{ display: grid; grid-template-columns: 1.15fr 1fr; gap: 26px; margin-top: 30px; }}
pre {{ height: {snap_h}px; overflow: hidden; border-radius: 18px; padding: 22px 22px; background: #0A0B0E;
  box-shadow: inset 0 0 0 1px rgba(255,255,255,.08); font: 13px/1.75 ui-monospace, "SF Mono", Menlo, monospace; color: #D7D9E0; white-space: pre-wrap; }}""")

        # Terminal.
        def c(t, hexc): return f'<span style="color:{hexc}">{t}</span>'
        term = (f"{c('$', '#6E7487')} <b>headroom</b>\n"
                f"<b>Claude</b>  🟦🟦🟦🟦⬛   82% · renews in 20h ⏳\n"
                f"  ↳ {c('plenty', '#6AA8FF')} · 80% renews unused at this pace\n"
                f"  ↳ {c('⚠ 5-hour session 16% left · resets 10:48 AM · runs out ~10:41 AM, 7m early', '#FFC248')}\n"
                f"<b>Codex</b>   🟨🟨🟨⬛⬛   59% · renews in 4d\n"
                f"  ↳ {c('tight', '#FFC248')} · runs out Fri 4 PM, 21h early\n"
                f"  ↳ {c('5-hour session 90% left · resets 2:12 PM · ~38% spare at this pace', '#6E7487')}\n"
                f"  ↳ {c('⏳ 1 reset credit lapses in 3d', '#8CC2FF')}\n\n"
                f"{c('$', '#6E7487')} <b>headroom statusline</b>\n"
                f"Claude 🟦🟦🟦🟦⬛ 82% {c('⏱48m', '#FFC248')}  Codex 🟨🟨🟨⬛⬛ 59%\n\n"
                f"{c('$', '#6E7487')} <b>headroom wait</b> && claude -p \"continue the refactor\"\n"
                f"{c('⏸ waiting on the 5-hour session · 10:48 AM (48m)', '#6E7487')}")
        body = f"""<div class="term"><div class="tt"><i style="background:#FF5F57"></i><i style="background:#FEBC2E"></i>
          <i style="background:#28C840"></i><span>Terminal</span></div><pre>{term}</pre></div>"""
        panel("terminal", body, 960, 496, raw, work, """
.term { border-radius: 16px; overflow: hidden; background: #0B0C0F; box-shadow: inset 0 0 0 1px rgba(255,255,255,.09), 0 18px 40px rgba(0,0,0,.35); }
.tt { height: 34px; display: flex; align-items: center; gap: 8px; padding: 0 14px; background: linear-gradient(180deg,#1E1F25,#18191E);
  box-shadow: inset 0 -1px 0 rgba(255,255,255,.05); }
.tt i { width: 12px; height: 12px; border-radius: 50%; }
.tt span { margin: 0 auto; transform: translateX(-30px); font: 600 12px -apple-system, system-ui; color: rgba(255,255,255,.45); }
pre { padding: 18px 22px 22px; font: 14px/1.75 ui-monospace, "SF Mono", Menlo, monospace; color: #D7D9E0; }
pre b { color: #fff; }""")


if __name__ == "__main__":
    main()
