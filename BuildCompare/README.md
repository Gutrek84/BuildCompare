# BuildCompare — WoW Tank Build & Stat Comparison Addon

Compare different talent/stat builds (mastery-heavy vs crit-heavy etc.) using data from the **built-in damage meter** (C_DamageMeter API introduced in the 2026 Midnight pre-expansion / patch 12.0).

## What it does (for tanks)

- After a Mythic+ or raid pull, record a run with a build label + automatic stat snapshot (mastery/crit/haste/vers).
- Pulls DT (damage taken), DTPS, healing done, HPS from the official built-in meter sessions — **no raw CLEU parsing** (which was removed/restricted in 12.0).
- Stores history in SavedVariables (persistent across logins/reloads).
- In-game window shows runs in a meter-style bar list + % difference readouts between runs.
- Example workflow (your Skyreach case):
  1. Run Skyreach M+10 on "mastery heavy" build → `/bc record "mastery heavy v1"`
  2. Change stats/talents/gear.
  3. Run Skyreach M+10 again → `/bc record "crit heavy v1"`
  4. Open the UI (`/bc`) → instantly see raw DT / healing + the % delta between the two builds.

Supports filtering mentally by instance/key level (data is stored with full metadata). Future: dropdown filters, CSV export, more metrics (absorbs, cooldown usage, etc.).

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
- `/bc record "my mastery build"` — snapshot current instance + stats + meter data and store it.
- `/bc clear` — wipe all saved runs (careful).
- In the UI:
  - "Record Current Run" button (prompts for label).
  - "Refresh" to reload the list from DB.
  - "Clear DB".
  - Bars visualize relative DT.
  - Bottom text shows quick % diff between your two most recent recorded runs (lower DT = generally better survivability for a tank).

## Data Model (what gets stored)

Each run record contains:
- timestamp, instance name, difficulty, keystone level
- buildLabel (your free text)
- spec + class
- stats snapshot (mastery/crit/haste/vers ratings + %)
- dt, dtps, healing, hps, duration (pulled from C_DamageMeter session)
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
- `C_DamageMeter.GetCombatSessionFromType("Overall")` / `"DamageTaken"` etc.
- `C_DamageMeter.GetCombatSessionFromID(id)`

This addon is written to use exactly that. The built-in damage meter in the default UI is now the canonical source.

If the API fields are slightly different on your build, run in-game:
`/dump C_DamageMeter.GetCombatSessionFromType("Overall")`
and adjust `GetPlayerMeterSummary` / `BuildCompare_GetMeterSessionSummary` in Core.lua / Utils.lua accordingly. The comments in the code tell you exactly where to look.

## Development / Iterating with Grok

If you want to keep improving this with AI assistance later:
- Point Grok at the source folder: `grok --cwd "C:\Users\Owner\projects\wow-addons\BuildCompare"`
- Make sure the `AGENTS.md` in this folder (or copy it next to the .toc when testing) is present — it contains the critical "never touch raw CLEU" rule and other WoW Lua conventions.

## Features Implemented (this update)

- **Dropdown-style filters** (Instance / Key Level / Build label) — click the buttons in the UI to cycle through available values + "All". List updates live.
- **Better run comparison table** — "Sel" buttons on run rows let you pick runs. Bottom panel shows detailed side-by-side comparison (DT, DTPS, Healing, Absorbs, CD count, damage type breakdown) **plus Build Stats deltas** (Mastery/Crit/Haste/Vers ratings and % with raw deltas and % change columns) so you can directly see how stat allocation affected your tanking performance.
- **Auto record on M+ completion / boss kill** — Automatically tracks on CHALLENGE_MODE_START / ENCOUNTER_START and records on completion (no manual /bc record needed for standard content).
- **More metrics**:
  - Absorbs captured from the built-in meter.
  - Damage type breakdown (physical / magic at minimum; inspect C_DamageMeter for more).
  - Defensive cooldown tracking (Barkskin, Survival Instincts, Shield Wall, Icebound Fortitude, Anti-Magic Shell, Blessing of Protection, etc.). Logged via cast events during the run and shown in comparisons.
  - **Talent tracking**: When a run starts (M+ / boss pull or manual record), we snapshot your active talent loadout name + the list of selected talents using the modern `C_Traits` API. In the comparison view you can now see exactly which talents were different between two runs (even with identical gear/stats), so you can measure the impact of specific talent choices on your DT/healing.

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

Made with Grok Build in plan + implement mode. Have fun comparing those mastery vs crit pulls on Skyreach!
