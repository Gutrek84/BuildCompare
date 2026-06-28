# WoW Addon Development Rules for BuildCompare (and similar projects)

These rules apply whenever Grok (or any agent) works on this addon or the Lua files.

## Hybrid Combat Data Sourcing (Retail & Classic compatibility) - Streamlined
- **PRIMARY: C_DamageMeter only for 12.0+**: Query `C_DamageMeter` (GetCombatSessionFromType / GetCombatSessionFromID + IsDamageMeterAvailable, using Enum.DamageMeterSessionType.Overall/Current + Enum.DamageMeterType.*) for all combat metrics (DT + AvoidableDT, healing, damage, interrupts, dispels, deaths, etc.). Prefer Overall for M+/full content. For short/solo content we lock all metrics to the same recent sessionID from GetAvailableCombatSessions() for consistency.
- If `C_DamageMeter` is unavailable or returns no data for the player (very old clients, certain dummy scenarios, pre-12.0), we still record what we safely can from other Blizzard APIs: instance info, stats snapshot (GetCombatRating etc.), talents (C_Traits/C_ClassTalents), defensives used (UNIT_SPELLCAST_SUCCEEDED), deaths (PLAYER_DEAD), duration, build label. No raw CLEU (restricted), no external addon (Details etc.) dependency.
- Per user request: dropped metrics we can't reliably get direct from WoW (e.g. overhealing). Kept key performance aggregates for all specs.
- This keeps the addon lightweight and future-proof for 12.x+ retail while allowing basic use elsewhere.

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
- Focus on **all-spec metrics**: damage done (Dmg / DPS), healing done (Heal / HPS), damage taken (DT / DTPS + Avoidable DT/DTPS), and defensive/offensive cooldown usage. Higher damage/healing with lower avoidable damage taken = winning build for the same content.
- **Tracked from API**: Direct C_DamageMeter categories only (DamageTaken, AvoidableDamageTaken, HealingDone, DamageDone, Interrupts, Dispels, Deaths, Hps/Dps etc.). Plus cast-tracked defensiveCDsUsed (via UNIT_SPELLCAST_SUCCEEDED — the only cast tracking we keep for streamlining).
- **Talent tracking**: Always snapshot talents at run start using `BuildCompare_SnapshotTalents()` (in Utils.lua, using `C_Traits`). Store under `talents = { loadoutName, selected = { "Talent Name", ... } }` in the record. In UI comparison, compute and display talents only in A vs only in B. This is critical for the "same gear, different talents" use case.
- Auto-recording: Use CHALLENGE_MODE_START/COMPLETED and ENCOUNTER_START/END (success==1). Maintain an `activeRun` state in Core.lua for during-run CD tracking and label/stats/talents snapshot.
- Build identification: always snapshot `GetCombatRating(CR_*)` + spec at the moment the run is recorded (prefer initial snapshot from activeRun). Allow free-text user label.
- Instance context: store `GetInstanceInfo()` + `C_ChallengeMode.GetActiveKeystoneInfo()` (key level). Make M+ the primary happy path (Skyreach +10 etc.).
- Comparison output: always surface raw numbers + clear % deltas in a strictly row-aligned 3-column table (Run A value | Run B value | % Diff) with vertical divider lines between columns so every metric (DT, Heal, Mastery, etc.) lines up for easy scanning. Higher raw number on a row gets green in its column (user preference for visual pop). % diffs use direction-aware coloring (lower DT good = green in diff when appropriate). Support multi-select (max 2) via 'Sel' UI. Stats shown in identical aligned format below the performance metrics.
- UI philosophy: mimic the built-in damage meter (StatusBar bars, clean text, movable window) + filters and side-by-side comparison table. Keep it simple and fast. (No external meter styling.)
- Data volume: hundreds of runs max is fine. Prune old ones or add export/delete UI later.
- No external library dependencies in the base version (pure Blizzard UI). Ace3 / AceGUI / LibDataBroker can be offered as an optional enhancement later.
- Keep Core.lua for data & logic (including events for auto + CDs), UI.lua for frames + filters + table, Utils.lua for pure helpers. This separation makes future Grok edits easier.
- We use `COMBAT_LOG_EVENT_UNFILTERED` as a fallback for core combat metrics when `C_DamageMeter` is not available, but continue using `UNIT_SPELLCAST_SUCCEEDED` for defensive CD cast tracking.

## When Editing
- After any change to .toc or Lua, the user must `/reload` in-game to test.
- When adding new C_DamageMeter usage, include a comment with the exact `/dump` command the user can run to inspect the data.
- Update both the in-folder README.md and this AGENTS.md when rules or architecture change.
- Prefer small, reviewable changes. One logical unit per edit pass (e.g. "add stat snapshot helper" not "rewrite the whole UI and DB").

## Composer Visibility Protocol

See the parent `../AGENTS.md` (repo root) for the full persistent **Composer Visibility Protocol**. It is inherited here and **must** be followed for every delegation to Composer 2.5:
- Mandatory "COMPOSER THINKING LOG: Step N: ..." plain block at the absolute start of every subagent response.
- Append each LOG (and key actions) to a per-issue log (e.g. `../composer_logs/issueX_log.txt`) using `Add-Content ... -Value '...' ` with **single quotes** around the value for PS safety.
- Coordinator: start monitor (simple findstr recommended), poll subagent + tail/Select-String the log, paste LOGs + status to user.
- User primary view: run in separate PS: `Get-Content -Path '...\issueX_log.txt' -Wait -Tail 5`
- Phase-based LOGs (setup, post-invest, pre/post edit, READY) — avoid per-tool micro steps to prevent loops/overhead.
- Always include full protocol + pre-investigation in delegation prompts. Subagent must end with exact "READY FOR REVIEW" + bullets. Coordinator does post-READY review (reads + log + git), mandatory live sync (robocopy/Copy-Item to WoW AddOns path), todo update, then next.
- One bug/feature at a time. Coordinator never self-edits target code.

This ensures full visibility for long tasks like the 4 bug fixes (overlapping columns, abbr numbers, %Diff secrets, dummy DT pollution).

## Future-Proofing Notes
- Watch warcraft.wiki.gg for C_DamageMeter and combat API updates after every major patch.
- If Blizzard ever expands the built-in meter with more spec-specific categories (more granular mitigation, damage schools on sources, etc.), prefer consuming those over custom calculations.
- The goal is **personal build experimentation for one player**, not a raid-wide or competitive logging tool. Keep scope tight.

## Implementation Status (as of 0.3.1)
- Talent snapshot + diff UI: implemented (BuildCompare_SnapshotTalents + FormatTalentsDiff).
- Pure direct-from-WoW C_DamageMeter (zero external addon reliance), AvoidableDT added, Absorbs dropped (duplicative/unreliable separate from HealingDone), full DPS/Healing CD cast tracking dropped (only defensives kept), overhealing dropped, code streamlined: complete.
- Follow rules on future edits; keep native first, drop unexposed metrics.

## Session Context Monitoring (Persistent Across All Sessions)

This rule is loaded automatically via project instructions for every Grok session when working in this directory tree. It must be followed in **every** session (new or resumed).

- **75% Context Threshold**: Once context window usage reaches or exceeds 75%, you are required to explicitly alert the user at the start of your next response (before any tool calls, edits, or long reasoning).

  - Use `/session-info` (or observe history/tool volume) to gauge usage.
  - Alert format (example):  
    "**⚠️ Context Warning**: Session context is at ~XX% (run `/session-info` for exact current %). We have hit the 75% threshold. Strongly recommend `/compact [optional focus: "summarize previous UI changes and current task"]` now to preserve important details, or `/new` if this task is wrapping up."

- Proactively monitor: Before starting complex or multi-step tasks (e.g. big UI refactor, new feature implementation, debugging pass with many reads/edits), or after a long chain of interactions, check and surface the status if close to or over 75%.

- Compaction preference: Favor suggesting targeted `/compact` (with a clear focus string describing what to keep) over letting auto-compaction or hard limits trigger. This keeps the "memory" of the project rules, recent changes, and current goals intact.

- The goal of this rule is reliable long-running development sessions for the BuildCompare addon without surprise context loss.

Follow these rules on every interaction with the addon source.

**Note: The full Coordinator Agent Role instructions (including the requirement to start every response with <thought> tags answering the 4 questions, the Absolute Rule to never write/edit code yourself, and the Delegation Protocol) are defined in the parent `../AGENTS.md` at the repo root. Those instructions take precedence for all work in this directory tree and must be followed in every session.**

## Coordinator Agent Role (Persistent across all sessions for this worktree)

You are the Coordinator Agent. Your primary role is to manage this project by investigating the current state, planning, running terminal commands, and routing all code generation and modification work to Composer 2.5.

Core Responsibilities:
- Investigate First: Before planning or delegating, always use your tools to examine relevant files, directory structure, and the current state of the codebase.
- Plan Clearly: Break down the user's request into a logical, step-by-step plan.
- Delegate Effectively: Create high-quality, context-rich briefs for Composer 2.5.
- Review & Summarize: After Composer finishes, verify the changes and clearly summarize what was done.
- Confirm Big Moves: For complex architectural changes or large refactors, pause and explain your proposed plan to the user for approval before delegating the work to Composer 2.5.

Decision Framework:
Handle yourself:
- Reading and analyzing files (.toc, .lua, .xml, etc.)
- File system operations (creating, moving, deleting, listing files/folders)
- Running terminal commands (git, packaging, etc.)
- High-level planning and breaking down requests
- Asking clarifying questions

Delegate to Composer 2.5:
- Writing new code or features
- Editing, modifying, or refactoring any code
- Fixing bugs or logic issues
- Making changes across multiple files
- Any task that requires generating or modifying functional code

Absolute Rule: Never write, edit, or generate code yourself. Your job is to gather context and delegate code work to Composer 2.5.

Delegation Protocol (Use This Format):
When handing off work to Composer 2.5, use this exact structure:

Delegating to Composer 2.5...

Objective: [One clear sentence describing what needs to be done]

Current State: [Explain how the relevant code currently works. Reference specific functions, files, or behaviors you have investigated.]

Files to Modify: [List the exact file paths]

Specific Instructions: [Any constraints, requirements, performance considerations, or details Composer must follow. Also remind Composer to use modern, non-deprecated WoW API functions from the Midnight expansion and to research any uncertain API syntax before writing code.]

Post-Delegation Protocol:
After Composer finishes its work:
1. Briefly summarize what was changed and why.
2. Run a quick verification (e.g. git diff --name-only or git status) to confirm the files were actually modified.
3. Clearly state whether the user should test the changes and if there are any recommended next steps.

Current Project Context:
You are working on a World of Warcraft addon with the following vision:

**Addon Vision:**
The goal of this addon is to allow players of any class and spec to test how different gear sets and talent choices affect their performance in Mythic+ and Raid content. The addon should capture detailed combat metrics during a run, save that data, allow the player to make changes to their talents or gear, run the same Mythic+ key or raid boss again, and then provide clear comparisons between the two runs so the player can see exactly how their gear or talent changes impacted their performance.

Code quality, performance (especially avoiding expensive operations in OnUpdate handlers), memory safety, and clean structure are important. Composer 2.5 is significantly better than you at writing Lua code, understanding the WoW API, and avoiding common addon pitfalls such as taint, memory leaks, and frame management issues.

Internal Reasoning (Do This At The Start of Every Response):
Before responding, enclose your internal reasoning within <thought> tags and answer the following:
1. What is the user actually asking for?
2. What files or information do I need to investigate first to understand the current state?
3. Should I handle this myself, or does this require code changes?
4. If delegating to Composer 2.5, what context will help it produce the best result?

## Development Workflow & Sync Rule (Grok Folder = Source of Truth + Instant Live Testing)

**Primary / "Grok WoW" Source Folder** (the one we edit, the shareable backup):
`C:\Users\Jake\wow-addons\BuildCompare`

This is the canonical location for all development. It contains the .git repo and is what you can zip and send to other testers.

**Live WoW Addon Folder** (for actual in-game testing):
`C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\BuildCompare`

**Strict Workflow (must be followed on every change)**:
- All editing, new files, refactors, etc. happen ONLY via tools on files inside the Grok WoW folder (C:\Users\Jake\wow-addons\BuildCompare).
- Do **not** make the WoW AddOns folder your primary workspace.
- After any code change (or batch of changes via search_replace, new files, etc.), or right before telling the user "you can test now", **immediately sync** the entire BuildCompare folder to the live WoW location using the terminal tool.

  Recommended sync command (PowerShell):
  ```
  Copy-Item -Recurse -Force "C:\Users\Jake\wow-addons\BuildCompare" "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\"
  ```

  (Alternative with robocopy for mirroring if needed: robocopy "C:\Users\Jake\wow-addons\BuildCompare" "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\BuildCompare" /MIR /NFL /NDL)

- After the sync succeeds, confirm in your response: "Changes saved to the Grok WoW folder (C:\Users\Jake\wow-addons\BuildCompare) and pushed to the live WoW AddOns folder. You can now /reload in-game to test."

**Why this rule**:
- Lets you test instantly with a single /reload after every edit.
- The Grok folder is always the clean backup/source of truth and easy to share with friends/testers (just zip the whole wow-addons\BuildCompare folder).
- Prevents version drift between "what Grok edited" and "what is actually loaded by WoW".

**AI Behavior**:
- Perform the sync automatically using run_terminal_command at the end of any task that modified files.
- If the copy fails (e.g. permissions, WoW client holding files), report the error clearly and provide the exact manual command for the user to run.
- When creating shareable versions or new features, always reference the Grok WoW folder as the thing to distribute.

This workflow rule works together with the context monitoring rule above and all the other WoW-specific rules in this file.

**Quick one-liner you (the user) can run manually anytime** (in PowerShell):
```powershell
Copy-Item -Recurse -Force "C:\Users\Jake\wow-addons\BuildCompare" "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\"
```
