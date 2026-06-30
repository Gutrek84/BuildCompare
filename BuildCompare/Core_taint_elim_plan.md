# Concise Implementation Plan: Eliminate Secret-Key Indexing & Secret-Number Comparisons in Core.lua

**Goal**: Make Core.lua taint-safe for 12.0+ (Midnight) by removing *all* direct use of potentially-secret numeric values (from C_DamageMeter session/duration/amounts, or theoretically aura IDs) in:
- Number comparisons (==, ~=, <, >, <=, >=, arithmetic decisions)
- Table key indexing (`tbl[secret] = ...` or lookup)
Preserve 100% existing functionality (M+ auto-record, ENCOUNTER, custom runs, aura tracking for uptimes/weapon imbues, GetNativeMeterData paths for lockedSessionID vs Overall, /bc debug, GetBestSessionIDForCurrentPull, FinalizeRecord, ReconcileActiveAuras, etc.). No behavior change for users or data stored.

**Approach**: 
- Always unbox numeric values intended for logic/math/storage decisions via `BuildCompare_UnboxSecret` (already in Utils) before any ==/compare/index use.
- For opaque IDs that must be passed raw to C_DamageMeter APIs (sessionID), keep the raw, but use safe string-based equality helper for *our* matching logic. Never use raw secret as table key.
- Use string keys for activeAuras (to bulletproof against any numeric ID ever being secret).
- Centralize 3 tiny local helpers in Core.lua near the existing IsSecret (after line ~152).
- All changes *only* in Core.lua. No changes to Utils.lua, UI.lua, .toc.
- Use search_replace only (small targeted hunks). Update comments referencing the old errors.

**Key Risk Locations Identified (from full file read + grep, lines approx as of 2026-06-28 read)**:
- ~151: local IsSecret (keep + duplicate ok for now)
- ~696-720: GetBestSessionIDForCurrentPull (direct sessionID == / ~= , duration d >= <= without full unbox before compare)
- ~780-840: fetchForType inside GetNativeMeterData (passes lockedSessionID which may be secret; inner duration handling)
- ~845-856: getSafeDur + the `dur == 0` / `dur <= 0` chain (comment already calls out the exact error)
- ~957-959, ~1012-1014: (IsSecret(x) or x == 0) patterns in FinalizeRecord + buff uptimes calc for duration/runDuration
- ~435-554, ~1231-1260: activeAuras[instanceID] = , pairs, [instanceID] nil / lookup (numeric keys from auraInstanceID + removed lists; also "mh_imbue" strings mixed). Also Flush.
- ~696 etc: comparisons on latest.sessionID / s.sessionID / latestID
- Minor: debug paths, GetLatestSessionID returns, capturedSource passing of initialSessionID (no index, but comparisons downstream)

**1. Required Helper Functions (add as local functions right after existing IsSecret/GetRate block, ~line 182 area)**

Add exactly these three (concise, taint-safe, no new deps):

local function SafeUnbox(val)
    if not val then return 0 end
    if IsSecret(val) then
        return BuildCompare_UnboxSecret(val)
    end
    return val
end

local function SafeSessionIDsEqual(a, b)
    if a == nil and b == nil then return true end
    if not a or not b then return false end
    -- Never let secret participate in native == for IDs (even if one side plain). Use string identity (safe, no taint, IDs are unique).
    if IsSecret(a) or IsSecret(b) then
        return tostring(a) == tostring(b)
    end
    return a == b
end

local function SafeSetAuraKey(tbl, rawKey, value)
    -- Eliminate any possibility of secret (or even plain large num auraID) as table key. Always string key for activeAuras / similar.
    if not tbl then return end
    local k = tostring(rawKey or "")
    if k == "" then return end
    tbl[k] = value
end

local function SafeGetAuraKey(tbl, rawKey)
    if not tbl then return nil end
    local k = tostring(rawKey or "")
    return tbl[k]
end

local function SafeAuraKeyDelete(tbl, rawKey)
    if not tbl then return end
    local k = tostring(rawKey or "")
    tbl[k] = nil
end

(These will be used for activeAuras everywhere; they are pure and cheap. Can also use for future-proofing other numeric-ID tables.)

**2. Specific Line-by-Line Modifications (target exact current locations; use search_replace with sufficient unique context for each)**

**Step A: Enhance local IsSecret area + insert helpers (no removal of existing IsSecret/SafeDiv/GetRate)**  
- After line ~178 (end of GetRate), before "-- Slash command", insert the 5 helpers above.  
- Optionally add comment: -- Taint-safe unbox/equal/key wrappers. Use everywhere a meter session/dur or aura numeric ID is used for decision, compare, or key.

**Step B: Update GetLatestSessionID (~159)**  
- Change: return sessions[#sessions].sessionID  
- To: return SafeUnbox( sessions[#sessions].sessionID )

(Keep API raw if needed later, but unbox here for consistency since callers use it for initialSessionID capture/compare.)

**Step C: GetBestSessionIDForCurrentPull (lines ~696-720 entire function body targeted)**  
- Replace the two direct session compares:  
  `if latest and latest.sessionID == initialSessionID then`  
  --> `if latest and SafeSessionIDsEqual(latest.sessionID, initialSessionID) then`  
- Inside loop: `if s.sessionID == initialSessionID then` --> `if SafeSessionIDsEqual(s.sessionID, initialSessionID) then`  
- For duration: after `local d = s.durationSeconds`  
  Add immediately: `d = SafeUnbox(d)`  
  Then the existing `if IsSecret(d) then` can stay or simplify to `if d == 0 then` (since unboxed). Keep IsSecret guard for belt-and-suspenders but now on unboxed it won't hit.  
- Change final: `if latestID ~= initialSessionID then` --> `if not SafeSessionIDsEqual(latestID, initialSessionID) then`  
- Also unbox the returned IDs? For now return raw sessionID (the original from sessions[i].sessionID) when deciding locked -- because locked is passed to GetCombatSessionFromID. We return the raw one from the table (it may be secret, but that's intended for API). The matching is now safe. Add comment.

**Step D: Inside GetNativeMeterData + fetchForType (~775-850 area)**  
- In the `if lockedSessionID then` branch (preferCurrent path): before any use, ensure `lockedSessionID` usage comment notes it may be secret but only passed to C_ API, never compared or keyed here. (No == on it inside fetch.)  
- In getSafeDur (rename or keep; ~848):  
  Update to:  
  local function getSafeDur(d)  
      if not d then return 0 end  
      local u = SafeUnbox(d)  
      if IsSecret(d) or u == 0 then return 0 end   -- note: check secret on *original* for intent, but return plain 0  
      return u  
  end  
- The post-fetch dur chain (~854-856):  
  `local dur = 0`  
  `if dtD then dur = getSafeDur(dtD.duration) end`  
  `if dur == 0 and healD then ...`  -- safe because getSafeDur always returns plain non-secret now  
  `if dur <= 0 then dur = 1 end`  
  Add comment above chain: -- dur is *always* a plain Lua number here. All meter .duration values were unboxed at source in fetch returns.  
- In the two places inside fetch returns where duration is set: they already do BuildCompare_UnboxSecret -- leave as-is (or change one to SafeUnbox for consistency, no functional diff).  
- When returning the top-level summary duration (line ~871 area): leave as-is (may be unboxed; UI tolerates secret anyway).  
- For the three fetchForType(..., lockedSessionID) calls at bottom of GetNative (~833-839): the locked arg is only used inside if preferCurrent, and inside the locked path it is *passed* to API not compared. OK. No change.

**Step E: FinalizeRecord duration handling (~957-960 area) + runDuration (~1012 area)**  
- Replace both guarded patterns:  
  Old:  
  `local duration = capturedSource.duration or 0`  
  `if (IsSecret(duration) or duration == 0) and capturedSource.startGetTime then`  
    `duration = GetTime() - capturedSource.startGetTime`  
  `elseif (IsSecret(duration) or duration == 0) and capturedSource.startTime then`  
    `duration = time() - capturedSource.startTime`  
  `end`  
  New (2x, once for duration, once for runDuration):  
  `local duration = SafeUnbox(capturedSource.duration or 0)`  
  `if duration == 0 and capturedSource.startGetTime then`  
      `duration = GetTime() - capturedSource.startGetTime`  
  `elseif duration == 0 and capturedSource.startTime then`  
      `duration = time() - capturedSource.startTime`  
  `end`  
- Do same for the `local runDuration = duration` block later (~1010). Unbox once, then plain ==0 .  
- After unbox block, `if runDuration <= 0 then runDuration = 1 end` -- now always safe.  
- In the buff calc loop, the `dur > 0` are from GetTime() diffs (plain). OK.  
- Add comment: -- duration/runDuration now guaranteed plain number before any comparison. Eliminates all secret-number compare paths for run lengths.

**Step F: Aura tracking - eliminate numeric (potential secret) key indexing (multiple sites)**  
Sites: ReconcileActiveAuras (~440-470), CheckWeaponEnchants (strings "mh_imbue" -- leave or wrap too), FlushActiveAuras (~546-554), Start/ captured copy (data only), UNIT_AURA handler (~1231-1260), PLAYER_ENTERING_WORLD reset.

- In ReconcileActiveAuras:  
  - For currentAuras build: `currentAuras[instID] = ...` --> `SafeSetAuraKey(currentAuras, instID, aura.spellId)` (note: value is spellID, key is inst)  
  - For removals loop: `for instanceID, cache in pairs(...)` stays (pairs ok). Inside: `if type(instanceID) == "number" then` can relax or keep (now keys are strings, so change test to `if instanceID and instanceID ~= "" then` or remove type check since we control keys now. Better: `local cache = SafeGetAuraKey(activeRun.activeAuras, instanceID)` then if cache ... `SafeAuraKeyDelete(...)`  
  - Additions: `if not activeRun.activeAuras[instanceID] then` --> use SafeGet... ; `activeRun.activeAuras[instanceID] = ` --> `SafeSetAuraKey(activeRun.activeAuras, instanceID, {spellID=..., startTime=...})`  
- In Flush: `for instanceID, cache in pairs(activeRun.activeAuras) do`  -- pairs fine; inside no re-key. After flush set `{}` .  
- In CheckWeaponEnchants: the "mh_imbue" / "oh_imbue" are *string* literals -- safe. Optionally wrap: `SafeSetAuraKey(..., "mh_imbue", ...)` for uniformity (still string key).  
- In UNIT_AURA:  
  - removals: `for _, instanceID in ipairs(...) do local cache = activeRun.activeAuras[instanceID]` --> `local cache = SafeGetAuraKey(activeRun.activeAuras, instanceID)` ; delete via SafeAuraKeyDelete  
  - additions: `activeRun.activeAuras[instID] = ` --> SafeSet...  
- Also in the initial Reconcile call sites and capturedSource copy: data carries the (now string-keyed) activeAuras table. No change needed (pairs and access go through helpers).  
- In FlushActiveAuras and Reconcile removal: the `if duration > 0` inside are fine (GetTime plain).  
- Add at top of aura funcs: -- All activeAuras keys now strings via Safe* helpers. Eliminates secret-key indexing risk entirely (and future-proofs if auraInstanceID ever protected).

**Step G: Minor / defensive cleanups**  
- In GetActorTotalFromSpells / ByType (~724+): the `sessionID` param is passed raw to pcall(GetCombat...FromID) -- correct, leave. No compares inside.  
- In OnCombatEvent and StartCustomRun captured: initialSessionID stored raw from GetLatest -- now will be unboxed from Step B, which is acceptable (plain number works for later matching via Safe* and for API? -- if API needs secret object, we may need to capture raw separately. To be safe: in StartCustomRun and activeRun init, capture BOTH initialSessionID (raw for API) and initialSessionIDSafe (for our compares). But to keep minimal change: since unbox produces equivalent number and GetBest/GetCombat accept numbers, and previous unbox was already happening for amounts, proceed with unbox for session too. If live test shows GetCombatFromID fails with unboxed, we can adjust in follow-up. Document in plan verification.  
- In all places that do `if IsSecret(x) then` for display in debug/Print -- leave (they are correct).  
- Update the big comment at ~845 (the one quoting the exact dur secret compare error) to note: "Fixed by SafeUnbox + always-plain dur locals + SafeSessionIDsEqual. No secret participates in any == or key op."  
- No other files touched. Ensure no new globals.

**3. Verification Steps (must be performed by user after Composer + sync)**  
a. From Grok WoW folder: run the sync command (Coordinator will do immediately post-READY, user can repeat):  
   `Copy-Item -Recurse -Force "c:\wowproject\BuildCompare" "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\"`  
b. In-game: `/reload`  
c. `/bc debug` :  
   - Confirm no Lua errors/taint in chat or console.  
   - Look for "Sessions count", "SessionID: ..." lines -- values should appear numeric not "secret".  
   - "Native C_DamageMeter Summary" shows real numbers (or "Pending Reload" only if no combat yet).  
   - Do a short combat (dummy or open world), then `/bc debug` again -- verify locked session path picked reasonable short duration, all values populated (DT, interrupts etc).  
d. Test full flows (no data loss or breakage):  
   - `/bc mini` (if used)  
   - Start custom: UI Start Custom button or equivalent, do combat, `/bc record "test safe v1"` or Stop. Verify in `/bc` list it saved with reasonable DT/heal/duration, no "Pending".  
   - If in M+ or raid boss possible: trigger auto via CHALLENGE or ENCOUNTER.  
   - Check buff uptimes in saved records (open UI, compare or inspect record via /dump) -- weapon imbues + tracked buffs must still accumulate correctly.  
   - `/dump GetNativeMeterData(true, nil)` and `/dump GetNativeMeterData(false, nil)` -- exercise both paths.  
   - Select 2 runs in UI, verify % diffs still compute (unbox in UI already, but data from Core now cleaner).  
e. `/dump BuildCompareDB.runs[#BuildCompareDB.runs]` -- confirm durations etc are plain numbers (not secret objects).  
f. No taint reported on reload or during / in combat. If taint, use `/console taintLog 1` before reload and check.  
g. If session API calls break (unlikely), note exact error for revert/adjust.

**4. Logging Instructions for Composer (MANDATORY PROTOCOL - see root + BuildCompare/AGENTS.md)**  
- Use dedicated log: `c:\wowproject\composer_logs\secret_taint_core_log.txt`  
- At very first action in session: `Set-Content -Path 'c:\wowproject\composer_logs\secret_taint_core_log.txt' -Value '=== secret_taint_core_log.txt started $(Get-Date) ==='`  
- **Every response from Composer MUST start with plain text block (no ``` fences before it):**  
  COMPOSER THINKING LOG: Step N: Received previous results (if any). [Concise detailed: what tool results showed (quote key code snippets/lines), current decision, exact next tool/edits planned. Ref specific lines from plan + current file state.]  
- Immediately after writing that LOG block in thought, append full copy (plus any extra) via:  
  `Add-Content -Path 'c:\wowproject\composer_logs\secret_taint_core_log.txt' -Value 'COMPOSER THINKING LOG: Step N: [exact copy of the block + details]'`  
  (Wrap the -Value arg in **single quotes** ' ' for PS safety with newlines/quotes inside.)  
- Phase-based only (not after every grep): 1. Startup/truncate + first LOG. 2. Post initial re-read of Core.lua + analysis vs plan. 3. Before each search_replace (quote the old_string target). 4. Post-edit re-read + verify grep for remaining "==|<=|activeAuras\[" patterns. 5. Final before READY.  
- End the entire task with a visible:  
  READY FOR REVIEW  
  - Summary bullets of every search_replace performed (with line ranges).  
  - Confirmation that no direct secret compares or tbl[nonstringkey from meter/aura] remain (grep results).  
  - List of helpers added + calls inserted.  
  - Any deviations from plan and why.  
  - Exact commands user should run for test (/reload, /bc debug, /dump ...).  
- Only work on "secret taint fix for Core.lua issue". Do not touch other files or add features.  
- If stuck, output the LOG + ask in log, but keep moving with minimal assumptions. Research WoW secret value patterns via comments only (no external).

**Success Criteria for Plan**: After implementation + tests, zero instances of raw secret participating in ==/compare or used as table key in Core.lua. Existing run recording, CD tracking, aura uptimes, meter summaries, and debug all continue to work identically.

**Coordinator Notes (for delegation)**: Provide this full plan.md + excerpts from the actual Core.lua reads (key functions with lines) + the AGENTS composer protocol text in the subagent prompt. Start monitor on the log file. After READY, read the log + file diffs, perform the live sync Copy-Item, git status, then report.

**File to edit**: ONLY c:/wowproject/BuildCompare/Core.lua (relative ok in tools). Source of truth is this Grok folder.

This plan is complete and unambiguous for one-pass implementation by Composer 2.5.