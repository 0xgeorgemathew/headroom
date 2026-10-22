<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="media/hero-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="media/hero-light.png">
    <img src="media/hero-dark.png" alt="Headroom: Will this week's allowance last? The Headroom popover open under its menu bar meters.">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/0xgeorgemathew/headroom/releases"><img alt="Latest beta" src="https://img.shields.io/github/v/release/0xgeorgemathew/headroom?include_prereleases&label=latest%20beta&color=4A8EFF"></a>
  <img alt="For macOS 15 and later" src="https://img.shields.io/badge/macOS-15%2B-1C1C1E">
  <img alt="Free and open" src="https://img.shields.io/badge/license-public%20domain-30D158">
</p>

<p align="center">
  Headroom sits in your menu bar and answers one question for your Claude and Codex plans:<br>
  <b>do you have room to spare this week, are you on pace, or should you slow down?</b>
</p>

<br>

## Install

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/0xgeorgemathew/headroom/main/install.sh | bash
```

Headroom appears in your menu bar a few seconds later and opens a short welcome to set it up.

You'll need a Mac with Apple silicon on macOS 15 or later, and Claude Code or Codex signed in to your subscription.

<br>

## Set up your way

<img src="media/welcome.png" alt="The welcome window: what the colors mean, picking Claude Code and Codex, shaping the menu bar with a live preview, and tuning the 5-hour warning">

A five-step welcome lets you choose which tools to watch, what the menu bar shows, when the 5-hour session should warn you, and which notifications you want. Every choice previews live and applies at once, and it's all in Settings later.

## Your week, at a glance

<img src="media/menubar.png" alt="Headroom's menu bar meters on dark, light and busy wallpapers">

Each provider gets five cells in your menu bar. **Blue** means you have room to spare, **white** means you're on pace, **amber** and **rose** mean slow down. An hourglass shows when unused allowance is about to renew, and a countdown appears when your 5-hour session is nearly used up.

## Make it yours

<img src="media/customize.png" alt="Menu bar variations: default, with percentages, the meter tracking the 5-hour session, whichever is tighter, and most urgent only">

Add the percentage beside each meter, keep the 5-hour timer always visible, show only the most urgent provider, or let the cells track the 5-hour session instead of the week (marked with a small **5H**). **Whichever is tighter** switches over only while the session is the closer limit. Light, dark or system appearance, your call.

## Settings, with a live preview

<img src="media/settings.png" alt="Settings: the Pace Card section with meter and graph toggles beside a live card, and the 5-hour session section with the warning level and a sample alert">

Settings looks and works like the welcome window. Each section shows a live preview of what it changes, so you see the card, menu bar or alert before you leave. Turn the meter and the graph on or off for the week and for the 5-hour session, set prices for your plan, and install the `headroom` command.

## Pace, not just a percentage

<img src="media/pace.png" alt="The four pacing states: Plenty available, On pace, Getting tight, Very tight">

82% left sounds great until you notice it renews tomorrow. Headroom compares what's left with the time left, draws your week so far, and tells you in one sentence whether to use more, keep going, or ease off, and roughly when you'd run out.

## First-class 5-hour limits

<img src="media/session.png" alt="The 5-hour panel: not started, on track with a forecast, a heads-up that it runs out before the reset, amber and rose warnings, and paused until reset">

The 5-hour session is usually the limit you hit first, so it gets its own panel on every card, built like the week: five cells for what's left with even pace marked, a graph of the five hours so far and where they're heading, and a forecast from your recent pace: *about 25% left when it resets*, or *runs out around 11:52 AM, 20m before the reset*. Once it crosses your warning level (75% by default, or 50, 60 or 90%) it moves to the top of the card and turns amber, then rose. At the limit it tells you exactly when you're back, and how much of the week is still waiting.

<img src="media/sessions.png" alt="Recent 5-hour sessions in the Activity tab, showing each session's peak and which ones hit the limit">

The Activity tab keeps your recent sessions, so a run of near-misses stands out. Optional notifications tell you when a session is nearly used, when you hit the limit, and the moment it's back. Prefer the old single row? Choose **A single row** in Settings.

## Caps, early resets and expiring credits

<img src="media/callouts.png" alt="Callouts for a model cap reached, a model cap running low, an early reset, and reset credits about to expire">

If a single model like Fable has its own weekly cap, Headroom tells you when that cap is the one to watch. It also notices when your week resets early, and highlights reset credits that are about to expire so you don't lose them.

## A plain answer when something's off

<img src="media/faults.png" alt="Messages for offline, signed out, format changed, service outage, enterprise plan, and CLI not found">

Offline, signed out, a service outage: Headroom says what happened and how to fix it, keeps showing your last reading with its age, and tries again on its own.

## What your usage is worth

<img src="media/activity.png" alt="The Activity tab with hourly token bars and cost, and Past weeks">

The Activity tab shows your tokens hour by hour for the last day, week or month, and what they would have cost at API prices. Drag across the bars to price any stretch of time, and break it down by model or project. **Past weeks** shows how much of each week you used, which weeks ran out early, and how much renewed unused.

## Share your burn

<img src="media/share.png" alt="Share card, two-provider snapshot, and a text version">

Right-click any card to copy a share image or a text version. Shares never include project names or your history.

## Also in your terminal

<img src="media/terminal.png" alt="The headroom command showing the weekly summary, a one-line status, and waiting for the session to reset">

Type `headroom` for the same summary, including where your 5-hour session is heading, add a one-line status to your prompt or editor, or have a long job wait until your session frees up. `man headroom` has the details.

<br>

## Private by design

- Headroom only **reads**. It never sends a prompt, never uses one of your reset credits, and never changes your sign-in.
- Your token counts come from files already on your Mac. Nothing you type is stored, and nothing is uploaded.
- The only places it connects to are Anthropic's usage page and, if you leave it on, the Claude and OpenAI status pages. No analytics, ever. Notifications are local.
- It's light: about 17 MB of memory and no CPU while it waits.

## Update or remove

Run the install command again to update. To remove Headroom:

```sh
curl -fsSL https://raw.githubusercontent.com/0xgeorgemathew/headroom/main/install.sh | bash -s -- --uninstall
```

## License

Public domain under [The Unlicense](LICENSE). Use it, change it, sell it; no permission needed.

<br>

<p align="center"><sub>Claude is a trademark of Anthropic. OpenAI and Codex are trademarks of OpenAI. Headroom is an independent project and isn't affiliated with either.</sub></p>
