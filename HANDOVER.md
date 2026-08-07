# Mercy Strike — Release Candidate Handover

Last updated: 2026-08-07

This document is the authoritative continuation point for Mercy Strike when
development moves to another computer. Read it before changing code. The mod
is close to a `1.0.0` experimental release; avoid broad refactors until the
remaining lifecycle issue and release-candidate tests are complete.

## Repository State at Handover

- Repository used on the previous computer:
  `D:\Steam\steamapps\common\KingdomComeDeliverance2\mods\mercystrike`
- Branch: `feature/optimization-audit`
- HEAD: `28d0523` (`optimization-audit save work and move to the main rig`)
- Remote state at handover: `origin/feature/optimization-audit` also pointed to
  `28d0523`.
- The worktree was clean before this `HANDOVER.md` file was created.
- `main` and `origin/main` pointed to `81be854` (`release-cleanup`).
- `HANDOVER.md` itself is intentionally left uncommitted for the user to
  review.
- Do not commit, push, package, discard, or overwrite user changes unless the
  user explicitly requests it.
- Always inspect `git status` before editing.

Recommended setup on the new computer:

```text
git fetch origin
git checkout feature/optimization-audit
git pull --ff-only
git status
```

If `HANDOVER.md` was not committed or copied to the new computer, copy it
separately before leaving the old computer.

## Runtime and Packaging

- Last explicitly tested KCD2 version: `1.5.6`.
- Mod source originally reported runtime version `0.2.1`.
- `mod.manifest` now declares `1.0.0`.
- The user packages `Data` with KCD PAK Builder. Codex should not package the
  mod unless explicitly asked.
- Runtime log:
  `D:\Steam\steamapps\common\KingdomComeDeliverance2\kcd.log`
- The game has consistently loaded `Data\mercystrike.pak` successfully.

## Project Goal

Convert selected near-lethal NPC combat outcomes into natural-looking
unconscious knockouts while keeping the NPC alive and eligible for KCD2's
normal mercy-kill/finisher interaction.

The design works with the engine's natural downed transition. It does not
force a custom fall animation.

## What Is Working

The core mechanic is considered proven enough for a release candidate:

- Gameplay/session lifecycle generation handling survives ordinary save loads.
- Old world, combat, transition, and MercyGuard callbacks are invalidated.
- The idle world detector and bounded combat scanner start and stop correctly.
- Nearby human combatants are discovered and filtered.
- Each eligible NPC receives one authoritative probability decision per
  combat encounter.
- Selected NPCs receive temporary transition protection (`imm=1`).
- The engine can process a convincing natural fall/down transition.
- Mercy Strike detects the engine health-reset/down signature.
- The unconscious state is secured.
- Health is stabilized before temporary immortality is removed.
- Immortality release has bounded retries and terminal cleanup paths.
- Released NPCs can remain unconscious and can be finished through the vanilla
  mercy-kill interaction.
- MercyGuard protects against delayed bleeding without intentionally blocking
  finishers.
- Fast transition and guard timers stop automatically when idle.
- Multiple-NPC fights and repeated save loads have been tested.
- No recurring Mercy Strike runtime errors were present in the latest test.
- Standalone operation without optional dependencies has been tested.
- Mod Configuration Menu plus KCDUtils/LuaDB operation and persistence have
  been tested.
- Heavy weapon detection works through a vanilla axe/mace UUID index.
- Unknown and modded weapon UUIDs remain neutral instead of being guessed.

## Release RPG Defaults

From `MS_Config.lua`:

- Base Mercy Strike chance: `5%`.
- Warfare scaling: enabled.
- Warfare bonus at level 30: `+15 percentage points`.
- Recognized axe or mace bonus: `+15 percentage points`.
- Final chance cap: `100%`.
- One roll is made per NPC per encounter, not per hit.

Formula:

```text
chance = 5% + (Warfare / 30 * 15%) + heavy-weapon bonus
```

Examples:

| Equipment and Warfare | Final chance |
|---|---:|
| Sword/other, Warfare 0 | 5% |
| Sword/other, Warfare 6 | 8% |
| Sword/other, Warfare 30 | 20% |
| Axe/mace, Warfare 0 | 20% |
| Axe/mace, Warfare 6 | 23% |
| Axe/mace, Warfare 30 | 35% |

Strength scaling was intentionally left out. Heavy weapons already provide a
clear identity without stacking another correlated player-stat bonus.

## Optional Dependencies

Mercy Strike is intended to remain fully usable without dependencies.

| Available integration | Intended behavior |
|---|---|
| None | Full gameplay with `MS_Config.lua` defaults |
| Mod Menu only | In-game changes for the current game run |
| KCDUtils/LuaDB only | Existing saved values load if available; no UI |
| Full stack | In-game configuration with persistence |

LuaUtils is not required. The current weapon classifier uses the base Lua API
and the vanilla UUID index.

## Current Protection and MercyGuard Strategy

Relevant release defaults:

```text
transition poll                 100 ms
normal absolute transition     90 s
engine-down settle             1500 ms
release health minimum         25%
MercyGuard poll                100 ms
MercyGuard trigger             8%
MercyGuard floor               10%
MercyGuard radius              10 m
outside-radius grace           10 s
```

MercyGuard currently:

- Starts only after a successful natural down and immortality release.
- Does not continuously write health.
- Clamps health from at or below 8% to 10%, with a one-second cooldown.
- Stops if the NPC dies/is finished, wakes, becomes unavailable, has repeated
  state/distance read failures, or remains farther than 10 metres away for 10
  seconds.
- Stops and is forgotten on a gameplay/save-session restart.
- Is not reacquired for an already-unconscious NPC after loading.
- Has no maximum lifetime while Henry remains nearby and the NPC remains
  unconscious.

When MercyGuard stops, Mercy Strike does not deliberately kill the NPC. The
NPC is left to the game. This is intentional: forced cleanup death would
undermine the player's decision to spare someone and could affect quests.

The latest test proved that an unconscious NPC can persist through a save and
load after MercyGuard has been cleared. That persistence belongs to the game
state; Mercy Strike was no longer actively sustaining the NPC.

## Latest Test — Important Diagnosis

The latest supplied `kcd.log` contained several gameplay generations.

### Generation 2

- KO stress mode was enabled correctly.
- Combat reported a `100%` base selection chance.
- `tneb_kozlik` was selected, armed, naturally downed, stabilized, released,
  and guarded.
- MercyGuard later observed `hp=0` and stopped with `deadOrFinished`. This may
  have been a finisher or an engine death; the state machine itself reached
  release correctly.

### Generation 3

- After loading, the console command reported `KO stress mode already ON`.
- Combat actually reported an `8%` effective normal chance.
- Both NPCs were rejected by normal probability rolls.

### Generation 4 and 5

- Stress mode still incorrectly claimed to be active, but normal `8%` settings
  were in effect.
- `tneb_mikes` happened to pass the normal roll (`roll=0.0381`).
- He naturally went down, was clamped to 25%, immortality was removed, and
  MercyGuard started.
- Guard heartbeats observed health declining to roughly 23.3% and 21.7%.
- Loading the save stopped the MercyGuard poller and cleared runtime entity
  state.
- The NPC remained unconscious after loading because the game preserved the
  condition, not because Mercy Strike reacquired or guarded him.

### Generation 6

- Stress mode again claimed to be active while combat used the normal `8%`
  chance.
- Both NPCs were rejected and died normally.
- Therefore, the two deaths do not indicate failure of the natural-down
  pipeline.

## P0 — Fix Before Further Stress Testing

### KO stress mode lifecycle bug

`Dev._koStressSnapshot` survives `OnGameplayStarted`, but normal RPG settings
are reloaded during `MS.ResetSession`. This creates a split state:

- `#ms_dev_ko_stress_on()` says stress mode is already ON.
- `applyBaseChance` and Warfare settings have returned to persisted defaults.
- Other stress overrides, including the 300-second timeout and verbose/acquire
  logging, may still remain active.

This makes post-load tests misleading.

Required behavior:

- KO stress mode is session-only.
- Every gameplay/session restart must restore its snapshot and clear
  `_koStressSnapshot`.
- Log that stress mode was reset to OFF by the lifecycle.
- After loading, `#ms_dev_ko_stress_on()` must enable a fresh 100% test session.
- Do not persist stress values to LuaDB.

Suggested implementation direction:

1. Add a bounded `MercyStrike.Dev.ResetSessionState(reason)` helper.
2. If a stress snapshot exists, restore all five overridden values:
   `applyBaseChance`, `scaleWithWarfare`, transition absolute timeout,
   verbose logging, and acquisition diagnostics.
3. Clear `_koStressSnapshot`.
4. Call it from `MS.ResetSession` before optional integrations reload persisted
   RPG settings.
5. Keep this protected with `pcall` so a development helper cannot break the
   gameplay lifecycle.

Do not simply clear the snapshot without restoring the non-persistent timeout
and logging overrides.

### Stress lifecycle verification

Before combat:

```text
#ms_dev_ko_stress_on()
#ms_show_cfg()
```

Expected: base `1.00`, Warfare scaling `false`, transition timeout `300`,
stress `true`, verbose/acquisition enabled.

Load a save and run:

```text
#ms_show_cfg()
```

Expected: release defaults/persisted values restored, transition timeout `90`,
stress `false`, and normal logging flags.

Then run stress ON again. Expected: it enables normally instead of saying
`already ON`.

## P1 — MercyGuard Lifetime Decision

Current guard protection can continue indefinitely while Henry remains within
10 metres. It is bounded by distance and session lifecycle, but not by time.

Recommended release-hardening option:

- Add an internal `mercyGuardMaxDurationS`, provisionally `180` seconds.
- When it expires, stop MercyGuard with `reason=maxDuration`.
- Stop protection only; do not kill the NPC, remove the unconscious buff, or
  set health to zero.
- Keep this internal rather than exposing it in Mod Menu.

This recommendation has not yet been approved or implemented. It should be
discussed with the user after fixing stress mode. A recovery/bleed-out system
would be a new gameplay feature and should not be improvised during release
cleanup.

If the maximum duration is implemented, test both terminal paths:

- Stay within 10 metres until `maxDuration` and confirm the guard poller stops.
- Move beyond 10 metres for more than 10 seconds and confirm
  `reason=outsideGrace`.

In both cases, confirm Mercy Strike does not intentionally kill the NPC.

## Remaining Release Cleanup

The branch is close but not yet a final release candidate.

1. Synchronize runtime and manifest versions:
   - `mod.manifest` is `1.0.0`.
   - `MS_Main.lua` still initializes `MercyStrike.version = "0.2.1"`.
   - Change the runtime version to `1.0.0` before packaging the release.
2. Clean the remaining XML comment:
   - The buff name is already `buff_mercystrike_transition_protection`.
   - Its comment still says `Temporary feasibility probe`.
   - Replace the comment only; keep the GUID unchanged.
3. Add the short **The Unknown: Temporary Immortality** disclosure to the
   README/mod page.
4. Add or confirm installation, requirements, compatibility, troubleshooting,
   and testing/reporting instructions on the mod page.
5. Keep internal names such as `immortalityProbe...` for `1.0.0`; renaming a
   stable state machine immediately before release adds unnecessary risk.
6. Review `git diff` and `git diff --check` carefully.

Suggested disclosure:

> **The Unknown: Temporary Immortality**
>
> Mercy Strike briefly gives a selected NPC the engine's immortality flag
> (`imm=1`). This allows an otherwise lethal hit to pass through the game's
> natural downed transition without immediately turning the NPC into a corpse.
> Testing shows that protected NPCs still take damage normally, and there is
> no evidence that the flag equalizes NPC statistics or behavior. However, the
> native implementation is not fully exposed to Lua. Mercy Strike therefore
> applies the flag only to selected combatants, keeps it active briefly, and
> removes it through bounded release and cleanup paths.

Note: `imm=0` disables immortality. Mercy Strike's temporary protection uses
`imm=1`.

## Release-Candidate Test Plan

After the stress lifecycle fix and any approved MercyGuard bound:

### Focused stress session

- Enable `#ms_dev_ko_stress_on()` after the final save load.
- Test several ordinary multi-NPC fights.
- Produce at least five successful knockouts.
- Use immediate and delayed finishers.
- Leave one unconscious NPC nearby for a while.
- Move outside guard range and return.
- End combat while an NPC is down.
- Save/load after a successful released knockout.
- If practical, save/load while temporary transition state may still be active.
- Disable stress mode afterward.

The final log should demonstrate:

- No `[MercyStrike][ERROR]` entries.
- Every armed NPC reaches release or terminal cleanup.
- Temporary immortality is not retained indefinitely.
- Transition and MercyGuard pollers stop when idle.
- Session generation increases on gameplay reload.
- Finishers remain available.
- Stress mode is definitely `100%` when claimed and definitely reset after a
  load.

### Dependency smoke tests

Only brief smoke tests remain necessary because the matrix was already tested:

- Standalone: boot, one normal fight, one save reload.
- Full stack: Mod Menu values load, change, persist, and affect a new decision.

Do not repeatedly uninstall every partial dependency combination unless a new
integration regression appears.

### Final release-default smoke test

- Start from a fresh gameplay session with stress mode OFF.
- Confirm the boot log reports version `1.0.0`.
- Confirm effective defaults/persisted user settings are expected.
- Run one ordinary fight using real probability.
- Check for errors and idle poller shutdown.

### Package verification

The user will package with KCD PAK Builder.

- Confirm the PAK contains the current scripts and buff XML.
- Confirm packed files match the loose source used for the test.
- Do not rebuild or modify unrelated mods.

## Known Limitations Accepted for 1.0.0

- A lethal opening hit can occur before combat acquisition and cannot always
  be converted.
- Several rapid hits may land between polling observations.
- An NPC may occasionally become unconscious while standing or midway through
  a fall. This is a visual timing issue and can look funny.
- Unknown modded heavy-weapon UUIDs remain neutral unless registered.
- Boss protection is currently primarily name-pattern based (`boss`). It is
  not a comprehensive quest-NPC classifier.
- A saved unconscious NPC may remain unconscious according to engine state
  after Mercy Strike runtime tracking has been cleared.

These are not reasons to add a permanent fast pre-combat poller or broadly
pre-arm nearby NPCs. Performance and civilian safety were deliberately favored.

## Not Release Blockers

- Strength scaling.
- More weapon-family modifiers.
- A recovery or bleed-out simulation.
- Detailed before/after soul probing for undocumented `imm=1` side effects.
- Complete universal boss/quest NPC identification, provided the limitation is
  stated accurately.
- Further animation timing tuning beyond evidence-driven fixes.

## Useful Console Commands

```text
#ms_help()                 List Mercy Strike console commands
#ms_deps()                 Show optional dependency/settings status
#ms_show_cfg()             Show effective settings and runtime flags
#ms_reload_cfg()           Reload defaults and persisted settings
#ms_debug_on()             Enable verbose/acquisition diagnostics
#ms_debug_off()            Restore compact diagnostics
#ms_set_static(chance)     Set a session-only fixed chance (0.0-1.0)
#ms_set_scaled()           Restore Warfare scaling for the session
#ms_probe_weapon()         Print an equipped-weapon snapshot
#ms_dev_ko_stress_on()     Enable 100% candidate selection for testing
#ms_dev_ko_stress_off()    Restore the pre-test snapshot
#ms_dev_show_chance()      Show current chance and weapon breakdown
#ms_dev_give_mace()        Add a test spiked bludgeon
#ms_dev_give_axe()         Add a test work axe
```

The give commands modify Henry's inventory and should be used only on
development saves.

## Source Map

- `Data/Scripts/Systems/mercystrike_init.lua` — system entry point.
- `Data/Scripts/MercyStrike/MS_Main.lua` — lifecycle, detection, candidate
  decisions, natural-down state machine, release, and MercyGuard.
- `MS_Config.lua` — release defaults and internal safety parameters.
- `MS_Poller.lua` — named timer/poller management.
- `MS_Unconscious.lua` — unconscious buff application and immediate health
  buffer.
- `MS_Settings.lua` — optional LuaDB persistence.
- `MS_ModMenu.lua` — optional Mod Configuration Menu integration.
- `MS_WeaponClassifier.lua` — heavy-weapon UUID classification and extension
  API.
- `MS_WeaponProbe.lua` — manual equipment diagnostics.
- `MS_Dev.lua` — explicit session-only testing helpers.
- `MS_Util.lua` — engine-safe helpers and console commands.
- `MS_Log.lua` — compact/core/verbose/integration logging policy.
- `Data/Libs/Tables/rpg/buff__mercystrike.xml` — non-persistent transition
  protection buff (`imm=1`).

## Recommended Immediate Continuation

1. Inspect status and confirm branch/HEAD.
2. Fix KO stress lifecycle reset first.
3. Update/add a focused lifecycle test log.
4. Decide whether to add a 180-second MercyGuard maximum; never force-kill on
   guard cleanup.
5. Synchronize the runtime version and clean the XML comment.
6. Finish documentation/disclosure.
7. Run the release-candidate test plan.
8. Review diff, then let the user commit/merge/package unless explicitly asked
   otherwise.

Do not resume feature expansion before these release tasks. The project has
already achieved its difficult core mechanic; the priority is now trustworthy
state cleanup, reproducible testing, and a clean `1.0.0` handoff.
