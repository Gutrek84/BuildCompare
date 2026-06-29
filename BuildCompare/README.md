# BuildCompare — WoW Build & Stat Comparison Addon

Compare different talent/stat builds (mastery-heavy vs crit-heavy etc.) using data from the **built-in damage meter** (C_DamageMeter API introduced in the 2026 Midnight pre-expansion / patch 12.0).

## What it does

- After a Mythic+ or raid pull, record a run with a build label + automatic stat snapshot (mastery/crit/haste/vers).
- Pulls DT (damage taken), DTPS, healing done, HPS from the official built-in meter sessions — **no raw CLEU parsing** (which was removed/restricted in 12.0).
- Stores history in SavedVariables (persistent across logins/reloads).
- In-game window shows runs in a meter-style bar list + % difference readouts between runs.
- Example workflow (your Skyreach case):
  1. Run Skyreach M+10 on "mastery heavy" build → `/bc record "mastery heavy v1"`
  2. Change stats/talents/gear.
  3. Run Skyreach M+10 again → `/bc record "crit heavy v1"`
  4. Open the UI (`/bc`) → instantly see raw DT / healing + the % delta between the two builds.

Supports filtering mentally by instance/key level (data is stored with full metadata). Future: dropdown filters, CSV export.

## Install

1. Copy the entire `BuildCompare` folder into your WoW retail AddOns directory:
   ```
   ...\World of Warcraft\_retail_\Interface\AddOns\BuildCompare\
   ```
   (The folder you are reading this from is the clean source. Do **not** put the parent `wow-addons` folder inside AddOns.)

2. Log into the game (must be a 12.0+ / Midnight client or later for C_DamageMeter).
3. At character select or with `/addons` make sure **BuildCompare** is enabled.
4. In game: `/reload`
5. Type `/bc` (or `/buildcompare`) to open the comparison window.
6. After a run: `/bc record "descriptive build label"` (or click the button in the UI).

## Usage

- `/bc` — open/close the main window (movable).
- `/bc mini` — show the compact live current-run overlay (movable, place over default WoW damage meters for fast glance + clicks during a run).
- `/bc record "my mastery build"` — snapshot current instance + stats + meter data and store it.
- `/bc clear` — wipe all saved runs (careful).
- In the UI:
  - Sel buttons pick up to 2 runs; right side now shows true 3 columns (Run A values | Run B values | Diff %). On any line the column with the numerically higher value is colored green.
  - All numbers in compare use consistent abbreviated formatting (k / m).
  - Top-right "-" button (now snug next to the X, same size) minimizes to the live overlay. The mini shows a "Time: Xm Ys" timer for the current recording duration + DT/AvDT/Heal/DefCDs (no more Rec button; use /bc record or main for saving).
  - Bottom: Start/Stop Custom for manual, Close, Clear DB.
  - Bars visualize relative DT.

## Data Model (what gets stored)

Each run record contains:
- timestamp, instance name, difficulty, keystone level (or delve info)
- buildLabel (your free text)
- spec + class
- stats snapshot (mastery/crit/haste/vers ratings + %)
- talents snapshot (loadoutName + list of selected talent names via C_Traits)
- dt, dtps, avoidableDT, avoidableDTPS, healing, hps, damage, dps, duration, interrupts, dispels, deaths (pulled direct from C_DamageMeter session where available)
- defensiveCDsUsed (tracked during run via UNIT_SPELLCAST_SUCCEEDED — only defensives kept after streamlining)
- reference to the meter session ID (if available)

The DB lives in:
- `WTF\Account\...\SavedVariables\BuildCompare.lua` (account-wide)
- Per-character version also kept.

Keep the number of runs reasonable (hundreds is fine; the list UI caps display at ~20 most recent).

## 2026 API Reality Check (important)

Blizzard removed direct `COMBAT_LOG_EVENT_UNFILTERED` (CLEU) access for addons in patch 12.0 as part of combat/UI restrictions ("addon apocalypse").

**All damage/healing data must come from the new `C_DamageMeter` namespace**:
- `C_DamageMeter.IsDamageMeterAvailable()`
- `C_DamageMeter.GetAvailableCombatSessions()`
- `C_DamageMeter.GetCombatSessionFromType(Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.DamageTaken)` (and other types like HealingDone=2, AvoidableDamageTaken=8, DamageDone=0, Deaths=9, etc.)
- `C_DamageMeter.GetCombatSessionFromID(id, type)`

This addon is written to use exactly that. The built-in damage meter in the default UI is now the canonical source.

If the API fields are slightly different on your build, run in-game:
`/dump C_DamageMeter.IsDamageMeterAvailable()`
`/dump C_DamageMeter.GetAvailableCombatSessions()`
`/dump C_DamageMeter.GetCombatSessionFromType(Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.DamageTaken)`
and inspect the returned structure (combatSources, find isLocalPlayer). GetPlayerMeterSummary / GetNativeMeterData in Core.lua are now purely native C_DamageMeter (streamlined, no external addon dependency at all).


## Features Implemented (this update)

- **Dropdown-style filters** (Instance / Key Level / Build label) — click the buttons in the UI to cycle through available values + "All". List updates live.
- **Better run comparison table** — "Sel" buttons on run rows let you pick runs. Bottom panel shows detailed side-by-side comparison (DT + AvoidableDT, DTPS, Healing, Def CDs, aggregate Damage/Healing, interrupts/dispels/deaths) **plus Build Stats deltas** (Mastery/Crit/Haste/Vers ratings and % with raw deltas and % change columns) and talent differences so you can directly see how stat allocation + talent choices affected your performance.
- **Auto record on M+ completion / boss kill / delve** — Automatically tracks on CHALLENGE_MODE_START / ENCOUNTER_START and records on completion. Delves are now supported as trackable content (the whole delve instance is one run; individual mob packs no longer create spammy solo records).
- **Pure native meter support (no external addons)**: All combat metrics (DT + AvoidableDT/DTPS, healing/HPS, damage/DPS, interrupts, dispels, deaths) come directly from the built-in `C_DamageMeter` API (12.0+ Midnight) via the exposed Enum.DamageMeterType values. For content where the meter has no session data, the record still captures build stats, talents, defensive CDs used (via allowed UNIT_SPELLCAST events), instance info, etc. Streamlined: removed Absorbs (frequently duplicative or not isolated per-pull), removed broad DPS/Healing CD cast tracking (only defensive CDs kept for focus and code size), dropped overhealing.
- **More metrics**:
  - Avoidable Damage Taken (direct from C_DamageMeter type 8) — critical for evaluating how much DT was actually avoidable/mitigable by the build.
  - Defensive cooldown tracking (Barkskin, Survival Instincts, Shield Wall, Icebound Fortitude, Anti-Magic Shell, Blessing of Protection, etc.). Logged via cast events during the run and shown in comparisons (only defensives; other CD categories removed to streamline).
  - **Talent tracking**: When a run starts (M+ / boss pull or manual record), we snapshot your active talent loadout name + the list of selected talents using the modern `C_Traits` / `C_ClassTalents` API. In the comparison view you now see exactly which talents were unique to each run (A-only vs B-only).

Old saved runs remain fully compatible.

## Roadmap / Ideas (pull requests welcome)

- Proper scrolling dropdown menus (instead of cycling buttons).
- CSV / clipboard export of runs.
- Per-character vs account DB toggle.
- WeakAuras or Plater integration hooks.
- More granular damage schools or external healing tracking.

## Credits & References

- Official addon creation: https://warcraft.wiki.gg/wiki/Create_a_WoW_AddOn_in_15_Minutes
- 12.0 API changes (C_DamageMeter): https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes
- Community discussion on the new damage data model (EpicDamageMeter, reddit r/wowaddondev, etc.).
