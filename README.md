# Research Manager — User Guide

A crafting-research assistant. It keeps track of
trait research across *all* your characters, tells you what to research next for
the best payoff, finds matching items already in your bags, and helps your
crafters make and hand off the traits your alts are still missing.

---

## What you need installed

Research Manager will not load until these are present. The in-game **AddOns**
screen lists any that are missing; install those and reload.

**Required**

| Dependency | Minimum version |
|---|---|
| [FCO ItemSaver](https://www.esoui.com/downloads/info1932-FCOItemSaver.html) | 2.8.3 |
| [LibAddonMenu-2.0](https://www.esoui.com/downloads/info7-LibAddonMenu.html) | 41 |
| [LibAddonMenuOrderListBox](https://www.esoui.com/downloads/info3088-LibAddonMenuOrderListBox.html) | 012 |
| [LibCustomMenu](https://www.esoui.com/downloads/info1146-LibCustomMenu.html) | 730 |
| [LibDialog](https://www.esoui.com/downloads/info1242-LibDialog.html) | 127 |
| [LibFeedback](https://www.esoui.com/downloads/info2451-LibFeedback.html) | — |
| [LibFilters-3.0](https://www.esoui.com/downloads/info1342-LibFilters-3.0.html) | 350 |
| [LibLazyCrafting](https://www.esoui.com/downloads/info1851-LibLazyCrafting.html) | 2.3 |
| [LibMainMenu-2.0](https://www.esoui.com/downloads/info2511-LibMainMenu-2.0.html) | 40400 |
| [LibShifterBox](https://www.esoui.com/downloads/info2779-LibShifterBox.html) | 000700 |

**Optional**

- [LibDebugLogger](https://www.esoui.com/downloads/info2275-LibDebugLogger.html) — extra logging if you have it; not needed for normal use.

> Most of these libraries are already pulled in by popular addons (FCO ItemSaver
> in particular ships several of them), so you may have little to install.

---

### Downloading from GitHub (no Minion required)

The addon lives at [github.com/zixhwizs/ResearchManager](https://github.com/zixhwizs/ResearchManager).
You can install it by hand without the Minion addon manager:

1. Open [github.com/zixhwizs/ResearchManager](https://github.com/zixhwizs/ResearchManager)
   in your browser.
2. Click the green **`< > Code`** button, then **Download ZIP**. (Direct link:
   [ResearchManager-main.zip](https://github.com/zixhwizs/ResearchManager/archive/refs/heads/main.zip).)
3. **Unzip** the download. GitHub wraps everything in a folder named
   `ResearchManager-main` (the branch name is appended) — that outer folder is the
   repository, **not** the addon itself. Open it and you'll find the actual addon
   folder, plain **`ResearchManager`**, inside.

> GitHub does not bundle the required libraries — they are separate downloads.
> Grab each one from the [dependency list above](#what-you-need-installed) (the
> in-game AddOns screen will also flag any that are still missing).

### Putting it in place

1. Copy the inner **`ResearchManager`** folder (the one with `ResearchManager.txt`
   inside it — **not** the `ResearchManager-main` wrapper) into your ESO AddOns
   directory:
   - **Live:** `Documents/Elder Scrolls Online/live/AddOns/`
   - **PTS:** `Documents/Elder Scrolls Online/pts/AddOns/`
   You should end up with `…/AddOns/ResearchManager/ResearchManager.txt`. If you
   see `…/AddOns/ResearchManager-main/ResearchManager/…`, you copied one level too
   high — move the inner folder up.
2. Do the same for each required library folder so it sits directly under
   `AddOns/`.
3. Launch the game, open **AddOns** from the main menu, and make sure
   **Research Manager** (and every required library above) is enabled.
4. Reload the UI: type `/reloadui` in chat, or restart the game.

---

## Getting started

1. **Bind a key to open the window.** Go to **Settings → Controls → Keybindings
   → Research Manager** and set a key for **Toggle Research Manager Window** (and
   optionally the two chat-print actions). Everything below is driven from that
   window and the settings panel — no typing required.
2. **Visit a crafting station on each of your characters at least once.** That's
   how the addon learns each character's research progress. It scans
   automatically whenever you load into the world, and saves the data
   account-wide.
3. **Open the window** with your bound key to see where everyone stands — overall
   progress, what's researching, and who's missing what.
4. **To craft missing traits for an alt,** hop onto a character that knows the
   trait and use the **Queue** buttons in the window (see
   [Crafting traits for your alts](#crafting-traits-for-your-alts)).
5. **Put the crafted item in the bank.** Once the item is made, deposit it into
   your account bank so the recipient can reach it. (With auto-deposit enabled,
   just opening the bank does this for you.)
6. **Log in on the character that needs the trait and visit the matching
   crafting station.** Withdraw the item from the bank if needed, then start
   research at the station — or let auto-research handle it for you if it's
   enabled.

> **Using Dolgubon's Lazy Writ Crafter?** If you do daily writs and research at
> the same station visit, open Lazy Writ Crafter's settings and **disable "Exit
> Crafting Window"** (under *Timesavers*), then enable **"Auto-exit station when
> done"** in Research Manager's settings. Otherwise Writ Crafter closes the
> station the moment your writ finishes — before Research Manager gets a chance to
> start research. With this swap, Research Manager does its work first and then
> closes the station itself.

---

## What it does (features)

- **Tracks research on every character.** Active research slots, time remaining
  on each, and which traits are known vs. still missing across all four smithing
  professions — Blacksmithing, Clothier, Woodworking, and Jewelry.
- **Recommends what to research next.** A ranking engine with four selectable
  strategies (see [Optimizer strategies](#optimizer-strategies)).
- **Scans your bags and bank** for items that match a trait your current
  character hasn't researched yet, so you don't deconstruct something you needed.
- **Per-trait priorities.** Tell the addon which traits matter to you (e.g.
  Divines on armor, Nirnhoned on weapons) with a slider for every trait, and the
  recommendations follow your preference.
- **Cross-character gifting.** Knows which alt is missing what and which of your
  other characters can craft it. When you craft a matching item, it marks it for
  the right recipient and helps hand it off through your account bank.
- **The Research Manager window** — a four-pane overview with statistics, a
  per-character research tree, your pending craft queue, and the queue of crafted
  items waiting to be researched.
- **Auto-research at stations.** Walk up to a crafting station and it can start
  research automatically on the marked items in your bags.
- **Auto-deposit on bank open.** Opening your bank ships gift items to the
  account bank for the recipient, no mailing required.
- **Tooltip badges** on items that fill a trait you still need.
- **Deconstruct / sell warnings** when you're about to break down or sell an item
  that fills a needed trait (it warns — it does not block you).

---

## Keybinds

The addon is operated through its window and settings panel. Bind these in
**Settings → Controls → Keybindings → Research Manager**:

- **Toggle Research Manager Window** — opens and closes the main window. This is
  the one to set first.
- **Print Research Status to Chat** — a quick per-craft summary with active
  research timers, printed to chat.
- **Print Research Recommendations to Chat** — your top recommendations for what
  to research next on the current character, printed to chat.

---

## The Research Manager window

Open it with your **Toggle Research Manager Window** keybind. It's resizable, you
can drag the splitters between panes, and its size and position are remembered.
Four panes, left to right:

- **Statistics** — an account-wide rollup (overall %, completed lines, estimated
  time to finish all research) plus a block per character with their own %,
  completed lines, active slots, ETA, and a per-craft breakdown.
- **Characters** — a collapsible tree: character → skill → research slot. Shows
  what's researching with a completion timer, and a quick slot summary on the
  collapsed row. Each character has a **Queue** button, and there's a **Queue All
  Characters** button at the top.
- **Crafting queue** — your pending crafts grouped by station, with **Remove** on
  each row and a **Clear Queue** button.
- **Research queue** — crafted items bound to a recipient and waiting to be
  researched, grouped by recipient. Your current character's group is open by
  default so the things *you* need to research are right there.

---

## Settings panel

Open it from **Settings → Addons → Research Manager**.

- **General** — include the bank in scans, tooltip badges, decon/sell warnings,
  chat notifications.
- **Optimizer** — pick a recommendation strategy.
- **Trait priorities** — three submenus (Weapons / Armor / Jewelry) with a slider
  (0–100) for each trait, plus a per-category reset.
- **Crafting for alts** — quality of crafted gifts (default Normal), level mode
  (Fixed or Auto), and the fixed-level slider with a Champion-points checkbox.
- **Cross-character gifting** — turn auto-marking of crafted gift items and
  auto-deposit to the bank on or off.
- **Auto-research** — turn automatic research-on-station-visit on or off.

---

## Optimizer strategies

Choose one in the settings panel; the recommendations (the **Print Research
Recommendations to Chat** keybind) use whichever is selected.

- **Balanced** *(default)* — favors high-priority traits and lines you've already
  made progress on, while discouraging starting a brand-new 30-day trait when a
  better use of the slot exists. The all-rounder.
- **Highest priority** — strictly follows your trait priority sliders; ties go to
  the shorter research.
- **Shortest first** — always the fastest research, to free a slot quickly. Handy
  when you're knocking out early, cheap traits.
- **Fill slots** — any unknown trait, just to keep every research slot busy.

Adjust the per-trait priority sliders to steer any of these toward the traits you
actually care about.

---

## Crafting traits for your alts

When one of your characters knows a trait an alt is still missing, Research
Manager can craft it and route it to that alt. There are two ways to do it.

### Hand-crafting (manual)

1. Get on a character that knows the needed trait and craft an item with it at
   the station.
2. The moment it lands in your bags, the addon marks it with the FCO ItemSaver
   **Research** icon — which also locks it from being deconstructed or sold — and
   binds it to the recipient. It shows up in the **Research queue** pane.
3. Open your **account bank**; with auto-deposit on, the item is deposited for the
   recipient to pick up.

### Queued crafting (automatic, via LibLazyCrafting)

1. On a crafter, open the window and press a **Queue** button — the per-character
   button on an alt's row, or **Queue All Characters** at the top of the
   Characters pane. The addon works out which missing traits that character can
   make, skips lines already covered, respects your priorities, and never queues
   more for a craft than the recipient has free research slots. If a matching
   item is already in your bags, it claims that instead of making a duplicate.
   The queued crafts appear in the **Crafting queue** pane.
2. Visit the relevant station(s). LibLazyCrafting performs each queued craft for
   you.
3. New crafts get marked and bound just like the manual flow. Open the bank to
   auto-deposit.
4. When the **recipient** alt later walks up to a station, auto-research (if
   enabled) starts research on the items waiting for them — up to their free
   slots, one trait per research line, in your priority order.

---

## Good to know

- **Gift matching is by broad category, not a single exact line.** A crafted
  weapon with Sharpened counts as a gift for any weapon line the alt still needs
  Sharpened on; the alt's station sorts out which specific line accepts it.
- **A research line only researches one trait at a time.** The addon won't queue
  or auto-start a second trait for a line that's already busy — distinct item
  types (Ice / Inferno / Healing staff, etc.) are still handled separately.
- **Bank items are only scanned when "Include bank" is enabled** in the General
  settings.
- **Warnings don't block you.** Decon/sell warnings are reminders in chat; the
  action still goes through if you choose to do it.
- **Nothing auto-equips or auto-mails.** The addon marks, queues, and deposits —
  the actual researching and any mailing stay in your hands by design.

---
