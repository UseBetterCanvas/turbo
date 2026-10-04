# Turbo

<img src="Resources/AppIcon.png" width="128" align="right" alt="Turbo: a pup in a graduation cap">

A Mac Dynamic Island for developers running lots of AI sessions at once. Fire off
work in **Claude Code** (local or cloud), **Codex** or **Cowork**, go do something
else, and Turbo taps you in the notch the moment a session finishes or needs you.
One click shows every session's status, and one more opens the thread.

Built by BetterCampus, on the BetterCampus design system.

## Install

The repo is private, so installs go through the [GitHub CLI](https://cli.github.com)
(`brew install gh`, then `gh auth login` once). Paste into Terminal (macOS 13+, Apple
Silicon and Intel):

```sh
gh api repos/UseBetterCanvas/turbo/contents/scripts/install.sh -H "Accept: application/vnd.github.raw" | bash
```

It installs Turbo into Applications and opens it. Run it again any time to update.
Look for the paw in your menu bar.

Prefer the browser? While signed into GitHub, download **Turbo.zip** from the
[latest build](https://github.com/UseBetterCanvas/turbo/releases/tag/latest-build), unzip it
and drag Turbo.app to Applications. Turbo isn't notarized by Apple yet, so macOS will say it
"could not verify" it: click **Done**, then go to System Settings → Privacy & Security,
scroll down and click **Open Anyway**. The Terminal install skips this.

## Three shapes, nothing else

Turbo is always exactly one of:

1. **A tiny island.** While sessions cook: a flame for the agent, a timer, and a count.
   The count turns gold when any session needs you.
2. **A bigger island.** When a session finishes ("waffle-web is done · cooked for 3m 12s")
   or hits a permission prompt. If several land at once they take turns ("+2 more"),
   and "needs you" always cuts the line. Hover the notch for the full list.
3. **The pop-up.** Click the paw in the menu bar (or the island) and a panel grows out of
   the notch: every session grouped into **Needs You**, **Cooking** and **Done**, each
   with an **Open** button that takes you straight to the thread. Setup and settings
   live here too.

There's also an optional **Visualizer** mode: an iTunes-style light show that plays full
screen while agents work. Every tool call is a beat and every finished session sets off a
finale.

If another notch app is running (HeyClicky, NotchNook, boring.notch, Alcove…), Turbo floats
just below the notch instead of fighting it, and moves back in when that app quits.

## How it hears your sessions

| Agent | How | Setup |
|---|---|---|
| **Claude Code (cloud)** on claude.ai/code | A hook in each cloud session posts thin pings to a private [ntfy.sh](https://ntfy.sh) channel. Turbo subscribes to it. | Agents → Claude Code (cloud) → **Copy Setup Script**, then paste it at the end of your cloud environment's Setup script. |
| **Claude Code** in your terminal or the desktop app | [Hooks](https://code.claude.com/docs/en/hooks) in `~/.claude/settings.json` post to Turbo on `127.0.0.1:47823`. | One click: Agents → **Connect**. |
| **Codex** | Turbo reads Codex's session logs in `~/.codex/sessions/`. | None. |
| **Cowork** | Cowork doesn't fire hooks, so Turbo reads each session's `audit.jsonl` in Claude Desktop's data folder. | None. |

**What cloud pings contain:** the event name (prompt sent, tool used, needs permission,
finished), the session id, the tool name, the repo folder name, permission-prompt text and
the cloud session id (so **Open** can take you to `claude.ai/code/session_…`). Never your
prompts, code, tool inputs or Claude's replies. The channel is a random 24-character name
only your Mac and your environments know, and **New Channel** rotates it. If your cloud
environment restricts network access, add `ntfy.sh` to its allowed domains.

Local config edits are backed up first (`settings.json.turbo-backup`), tagged
`turbo-hook`, and fully removable.

## Design

Turbo uses the BetterCampus design system (`bettercampus/DESIGN.md`):
- Blurple `#4F49F3` as the single brand action color
- dark-first deep surfaces (`#1A1A1A` → `#333333`)
- Figtree, Archivo and JetBrains Mono
- the signature hard "edge" on pressables
- one easing curve (`cubic-bezier(0.2, 0.8, 0.3, 1)`), nothing over 300ms, no springs
- signals (teal done, gold attention, red error) that never use Blurple

Tokens and components live in `Sources/Turbo/UI/DesignSystem.swift`. The island itself
stays pure black so it blends with the hardware notch.

## Build

Requires macOS 13+ and Xcode 15+.

```sh
swift run Turbo               # run from source
./scripts/bundle.sh           # build/Turbo.app (universal, ad-hoc signed) + build/Turbo.zip
swift test                    # core tests (also run on Linux)
python3 scripts/make-icon.py  # re-render the app icon
```

Every push to `main` publishes a fresh `latest-build` release through CI.

## Layout

```
Sources/TurboCore/    Pure Foundation, unit-tested on Linux too
  AgentEvent.swift          hook / notify / rollout / Cowork / relay parsing
  SessionStore.swift        the session state machine (idle → cooking ⇄ needs you → done)
  CloudRelay.swift          cloud setup script, relay hook, channel URLs
  SessionLogTailer.swift    zero-config Codex and Cowork detection
  HookInstaller.swift       safe, idempotent edits to Claude and Codex configs
  HTTP.swift, ClaudeTranscript.swift
Sources/Turbo/        The macOS app (SwiftUI + AppKit)
  AppModel.swift            session board, card queue, relay, demo
  TurboApp.swift            menu bar paw
  Island/                   notch geometry, island panel and views, notch-app detection
  Popup/                    the pop-up: sessions board, agents, settings, welcome
  Visualizer/               Canvas visualizer
  UI/                       design system and shared components
Resources/            app icon, bundled fonts (SIL Open Font License)
```
