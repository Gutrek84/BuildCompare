# WoW Addon Development Rules for BuildCompare (and similar projects)

These rules apply whenever Grok (or any agent) works on this addon or the Lua files.

## Critical 2026 API Restrictions (non-negotiable)
- **NEVER** use or register `COMBAT_LOG_EVENT_UNFILTERED` or `COMBAT_LOG_EVENT` or `CombatLogGetCurrentEventInfo()`.
  - These were removed/restricted for addons in Midnight 12.0 ("addon apocalypse").
  - Attempting to use them will cause errors or taint/security issues.
- **ALWAYS** source combat statistics exclusively from the official built-in damage meter API: `C_DamageMeter.*`
  - `C_DamageMeter.IsDamageMeterAvailable()`
  - `C_DamageMeter.GetAvailableCombatSessions()`
  - `C_DamageMeter.GetCombatSessionFromType(...)` and `GetCombatSessionFromID(...)`
  - Poll via ticker/OnUpdate or EventRegistry callbacks as appropriate. Do not assume raw event streams.
- The built-in UI damage meter is now the canonical data source. Addons should enhance or compare on top of it, not duplicate parsing.

If the exact table fields returned by `GetCombatSessionFromType` differ from current code comments, inspect live with `/dump` and update `GetPlayerMeterSummary` / `BuildCompare_GetMeterSessionSummary` accordingly.

## General WoW Lua / Addon Hygiene
- Use `## Interface: 12xxxx` (update on major patches) in the .toc.
- Declare persistence only via `## SavedVariables:` and `## SavedVariablesPerCharacter:` in the .toc. Never write directly to WTF files.
- Initialize DB tables safely on `ADDON_LOADED` or `PLAYER_LOGIN` and guard against nil.
- Prefer account-wide DB (`BuildCompareDB`) for cross-character build comparisons unless the user explicitly wants per-char.
- Avoid taint: do not hook protected frames or call secure functions from insecure code paths. Use `CreateFrame` with standard templates.
- Frame naming: use unique names (`BuildCompareFrame`, etc.) to avoid collisions.
- Performance: combat-time code must be extremely light. Do heavy work on segment end / out of combat.
- Testing: always instruct user to `/reload` after changes. Provide `/dump` one-liners for verifying C_DamageMeter data.
- Versioning: bump the Version line in .toc on meaningful changes.

## Project-Specific Conventions for This Addon
- Focus on **tank metrics**: damage taken (DT / DTPS), healing done/received + absorbs where exposed. Lower DT with comparable or better healing = winning build for the same content.
- **New metrics**: Absorbs, damageBreakdown (physical/magic etc.), defensiveCDsUsed (list of spellId/name/timestamp for known tank defensives).
- Auto-recording: Use CHALLENGE_MODE_START/COMPLETED and ENCOUNTER_START/END (success==1). Maintain an `activeRun` state in Core.lua for during-run CD tracking and label/stats snapshot.
- Build identification: always snapshot `GetCombatRating(CR_*)` + spec at the moment the run is recorded (prefer initial snapshot from activeRun). Allow free-text user label.
- Instance context: store `GetInstanceInfo()` + `C_ChallengeMode.GetActiveKeystoneInfo()` (key level). Make M+ the primary happy path (Skyreach +10 etc.).
- Comparison output: always surface raw numbers + clear % deltas. Color code (green = better for tank survivability when lower DT). Support multi-select via UI.
- UI philosophy: mimic the built-in / Details!-style meter (StatusBar bars, clean text, movable window) + filters and side-by-side comparison table. Keep it simple and fast.
- Data volume: hundreds of runs max is fine. Prune old ones or add export/delete UI later.
- No external library dependencies in the base version (pure Blizzard UI). Ace3 / AceGUI / LibDataBroker can be offered as an optional enhancement later.
- Keep Core.lua for data & logic (including events for auto + CDs), UI.lua for frames + filters + table, Utils.lua for pure helpers. This separation makes future Grok edits easier.
- **Never add raw CLEU** even for CD tracking — use UNIT_SPELLCAST_SUCCEEDED / UNIT_AURA for defensives.

## When Editing
- After any change to .toc or Lua, the user must `/reload` in-game to test.
- When adding new C_DamageMeter usage, include a comment with the exact `/dump` command the user can run to inspect the data.
- Update both the in-folder README.md and this AGENTS.md when rules or architecture change.
- Prefer small, reviewable changes. One logical unit per edit pass (e.g. "add stat snapshot helper" not "rewrite the whole UI and DB").

## Future-Proofing Notes
- Watch warcraft.wiki.gg for C_DamageMeter and combat API updates after every major patch.
- If Blizzard ever expands the built-in meter with more tank-specific categories (absorbs, mitigation, etc.), prefer consuming those over custom calculations.
- The goal is **personal build experimentation for one player**, not a raid-wide or competitive logging tool. Keep scope tight.

Follow these rules on every interaction with the addon source.
