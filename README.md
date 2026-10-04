# Turbo

<img src="Resources/AppIcon.png" width="128" align="right" alt="Turbo: a pup in a graduation cap">

A Mac Dynamic Island for developers running lots of AI sessions at once. Fire off
work in **Claude Code** or **Codex** (local or cloud) or **Cowork**, go do something
else, and Turbo taps you in the notch the moment a session finishes or needs you.
One click shows every session's status, and one more opens the thread.

Built by BetterCampus, on the BetterCampus design system.

## Install

The repo is private, so installs go through the [GitHub CLI](https://cli.github.com)
(`brew install gh`, then `gh auth login` once). Paste into Terminal (macOS 13+, Apple
Silicon and Intel):

```sh
bash <(gh api repos/UseBetterCanvas/turbo/contents/scripts/install.sh -H "Accept: application/vnd.github.raw")
```

It installs Turbo into Applications and opens it. After that, update from inside the app:
Settings → Updates → **Update**.
Look for the paw in your menu bar.

Prefer the browser? While signed into GitHub, download **Turbo.zip** from the
[latest build](https://github.com/UseBetterCanvas/turbo/releases/tag/latest-build), unzip it
and drag Turbo.app to Applications. Turbo isn't notarized by Apple yet, so macOS will say it
"could not verify" it: click **Done**, then go to System Settings → Privacy & Security,
scroll down and click **Open Anyway**. The Terminal install skips this.

## Three shapes, all from the notch

Turbo lives in the notch, like the iPhone's Dynamic Island, and is always exactly one of:

1. **A tiny island.** A paw beside the notch when nothing's cooking. While sessions cook:
   a flame for the agent, a timer and a count, which turns gold when any session needs you.
2. **A medium island.** Hover the tiny island and it grows into a list of every session with
   its status. It also pops out on its own when a session finishes ("Done: waffle-web ·
   3m 12s") or hits a permission prompt. If several land at once they take turns
   ("+2 more"), and "needs you" always cuts the line.
3. **The pop-up.** Click the island (or the paw in the menu bar) and a panel grows out of the
   notch: every session grouped into **Needs You**, **Cooking** and **Done**, each with an
   **Open** button that goes straight to the thread. Setup and settings live here too.

**Keyboard:** press **⌃⌥Space** anywhere to open the board on whatever needs you. Then
**J / K** (or the arrows) to move, **Return** to open, **A / D** to allow or deny,
**X** to dismiss a finished session, and **1 to 9** to jump straight to a session.

**Triage helpers:**
- Sessions are named by what they were asked ("Fix the flaky syrup tests"), with the repo beside the status.
- Waiting sessions show how long they've waited, and Turbo nudges you again after 3 minutes.
- A cooking session with no activity for 5 minutes says so, in case it's stuck.
- **Always Allow** on a permission prompt saves that exact command to the repo's
  `.claude/settings.local.json`, so it stops asking.
- Right-click the menu bar paw for **Quiet for 1 Hour** or **Quiet Until Tomorrow**: no sounds,
  no done cards, and needs-you still shows silently.
- The teal dot on the tiny island only counts finished sessions you haven't opened yet.

**Visualizer:** a fun, full-screen view of the progress, one click away from the hover list
or the pop-up. Every tool call is a beat and every finished session sets off a finale.

If another notch app is running (HeyClicky, NotchNook, Alcove…) and the two overlap,
Settings → Island → Placement can move Turbo just below the notch.

## How it hears your sessions

| Agent | How | Setup |
|---|---|---|
| **Claude Code (cloud)** on claude.ai/code | A hook in each cloud session posts thin pings to a private [ntfy.sh](https://ntfy.sh) channel. Turbo subscribes to it. | Settings → Connections → Claude Code (cloud) → **Copy Setup Script**, then paste it at the end of your cloud environment's Setup script. |
| **Claude Code** in your terminal or the desktop app | [Hooks](https://code.claude.com/docs/en/hooks) in `~/.claude/settings.json` post to Turbo on `127.0.0.1:47823`. | One click: Settings → Connections → **Connect**. |
| **Codex** (CLI, IDE extension) | Turbo reads Codex's session logs in `~/.codex/sessions/`. | None. |
| **Codex (cloud)** on chatgpt.com/codex | Turbo asks the Codex CLI for your recent cloud tasks (`codex cloud list --json`) every 20 seconds, using your existing login. | None if the Codex CLI is installed and signed in (`brew install codex && codex login`). |
| **Cowork** | Cowork doesn't fire hooks, so Turbo reads each session's `audit.jsonl` in Claude Desktop's data folder. | None. |

**What cloud pings contain:** the event name (prompt sent, tool used, needs permission,
finished), the session id, the tool name, the repo folder name, permission-prompt text and
the cloud session id (so **Open** can take you to `claude.ai/code/session_…`). Never your
prompts, code, tool inputs or Claude's replies. The channel is a random 24-character name
only your Mac and your environments know, and **New Channel** rotates it. If your cloud
environment restricts network access, add `ntfy.sh` to its allowed domains.

Local config edits are backed up first (`settings.json.turbo-backup`), tagged
`turbo-hook`, and fully removable.

## Signing and notarization

Until Turbo is notarized, browser downloads trigger macOS's "Apple could not verify" prompt
(the Terminal install doesn't). CI signs with a Developer ID and notarizes automatically once
these repository secrets exist (Settings → Secrets and variables → Actions):

| Secret | What it is |
|---|---|
| `MACOS_CERT_P12_BASE64` | Your "Developer ID Application" certificate exported as .p12, base64-encoded (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERT_PASSWORD` | The password you set when exporting the .p12 |
| `APPSTORE_API_KEY_P8_BASE64` | An App Store Connect API key (.p8, "Developer" access), base64-encoded |
| `APPSTORE_KEY_ID` | That key's ID |
| `APPSTORE_ISSUER_ID` | Your App Store Connect issuer ID |

Both need an Apple Developer Program membership. Without the secrets, builds are ad-hoc signed.

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
  CodexCloud.swift          Codex cloud task parsing and change tracking
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
