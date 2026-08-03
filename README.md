# Mercy Strike

## Foreword

Combat in *Kingdom Come: Deliverance II* does not always need to end in an
immediate death. Mercy Strike is built around a simple idea: selected
near-lethal combat outcomes should be able to become convincing unconscious
knockouts while preserving the game's normal mercy-kill interaction. Like in the GOAT KCD1.

The mod aims to work with the engine rather than replace its combat
presentation. When the conditions are right, an NPC falls through the natural
engine transition, remains alive and unconscious, and can still be finished by
the player.

## Overview

Mercy Strike monitors nearby human combatants while the player is in combat.
A qualifying damage transition makes an NPC a candidate. The mod then makes
one selection decision for that NPC during the current combat encounter.

- Selected NPCs enter the natural-down pipeline.
- Rejected NPCs remain completely vanilla.
- The decision is made only once per NPC per combat encounter.
- Animals, corpses, and protected boss-like targets are excluded.
- Fast polling runs only while it is needed.

> **Development status:** The core natural-down, immortality-release,
> finisher, lifecycle, and cleanup mechanics have been proven in repeated game
> tests. Mercy Strike now uses one authoritative candidate and state-machine
> pipeline with release-oriented probability defaults.

## Core Systems

### Combat candidate detection

The mod uses a lightweight world detector while idle and a faster bounded scan
while combat is active. A nearby human NPC must show a sufficiently large HP
drop at close range before becoming a candidate.

### One decision per encounter

Each candidate receives one authoritative probability roll for the current
combat encounter. Only a selected candidate can receive Mercy Strike's
temporary protection. Rejected candidates are not modified by fallback logic.

This decision includes Warfare scaling, the equipped heavy-weapon modifier,
and user configuration.

### Natural-down transition

A selected candidate receives temporary immortality before a later lethal
transition. This allows the game engine to process a natural-looking fall
without immediately turning the NPC into a corpse.

Mercy Strike observes the transition instead of forcing a custom fall
animation.

### Unconscious state and immortality release

After the engine reports that the NPC is down, Mercy Strike:

1. Secures the unconscious state.
2. Stabilizes the NPC's health.
3. Removes temporary immortality.
4. Verifies that the NPC remains alive and unconscious.

Immortality release uses bounded retries and cleanup paths. Reloading,
abandoning combat, failed state reads, and conscious wounded NPCs all have
terminal cleanup behavior.

### MercyGuard and finishers

After immortality is removed, a short-range MercyGuard protects the
unconscious NPC from delayed bleeding without blocking the vanilla finisher.
It uses a low health trigger with hysteresis rather than continuously writing
health.

MercyGuard stops when the NPC:

- Is finished or dies.
- Is no longer unconscious.
- Remains outside the configured range and grace period.
- Becomes unavailable.

Its fast timer stops automatically when no guarded NPCs remain.

### Lifecycle and performance

Gameplay and save-session restarts use generation-based lifecycle handling.
Old callbacks are invalidated, active temporary immortality is cleaned up, and
the world detector starts with fresh state.

The current polling layers are:

- Slow world detection while idle.
- Combat scanning only during combat.
- Transition monitoring only while selected NPCs are armed or releasing.
- MercyGuard monitoring only while released unconscious NPCs need protection.

## Release Defaults

Mercy Strike ships with deliberately restrained defaults:

- **Base Mercy Strike chance:** 5%.
- **Warfare scaling:** enabled.
- **Warfare bonus at level 30:** +15 percentage points.
- **Recognized axe or mace bonus:** +15 percentage points.

The chance is rolled once for each eligible NPC during a combat encounter,
not once per hit. Bonuses are additive, and the final result is capped at
100%.

| Example | Final chance |
|---|---:|
| Sword, Warfare 0 | 5% |
| Sword, Warfare 6 | 8% |
| Sword, Warfare 30 | 20% |
| Axe or mace, Warfare 0 | 20% |
| Axe or mace, Warfare 30 | 35% |

This keeps Mercy Strikes uncommon with swords while giving heavy weapons a
clear identity and letting the chance grow naturally with Henry's combat
experience. All four values can be adjusted through Mod Configuration Menu.

## Configuration and Optional Integrations

Mercy Strike always works from the Lua defaults in `MS_Config.lua`. Mod
Configuration Menu and KCDUtils/LuaDB add controls and persistence without
becoming gameplay requirements.

| Available integration | Behavior |
|---|---|
| None | Lua defaults; full gameplay functionality |
| Mod Menu only | In-game settings for the current session |
| KCDUtils/LuaDB only | Persisted settings without an in-game menu |
| Full stack | In-game settings with persistence |

The initial Mod Menu layout is:

```text
Mercy Strike Chance
  Base Mercy Strike Chance       0-100%
Weapon Influence
  Heavy Weapon Bonus             0-100%
Character Progression
  Scale With Warfare             On/Off
  Warfare Bonus at Mastery       0-100%
```

The base chance is the probability that an eligible NPC receives Mercy
Strike's one selection decision for the encounter. When Warfare scaling is
enabled, the configured bonus grows with Henry's Warfare skill and reaches its
full value at Warfare 30. The bonus uses additive percentage points: a 5% base
chance with a 15% mastery bonus produces a 20% chance at Warfare 30.

The heavy weapon bonus adds percentage points when Henry has a recognized axe
or mace in his right hand at the candidate decision. For example, a 5% base
chance, a current 6% Warfare contribution, and a 15% heavy weapon bonus produce
a 26% final chance. The complete result is clamped to 100%.

Changes apply to new candidate decisions. With KCDUtils/LuaDB available, the
complete validated record is saved globally in the `mercystrike` namespace.
Missing or invalid fields fall back independently to `MS_Config.lua`.

Combat acquisition thresholds, polling intervals, temporary protection,
health stabilization, release timing, and MercyGuard remain internal safety
settings and are intentionally not exposed to users.

Logging is split into compact core, verbose development, and optional-
integration channels. Core state decisions remain visible by default, while
poller lifecycle, candidate observations, release detail, health clamps, and
acquisition probes are quiet. LuaDB and Mod Menu messages use the integration
channel. Errors and the result of a manually requested console probe are
always visible. `#ms_debug_on()` enables verbose and acquisition diagnostics
for the current session; `#ms_debug_off()` restores the compact view.

KCD2's runtime item table exposes an equipped item's UUID and database name,
but not its XML weapon class. Mercy Strike therefore indexes the shipped
Class 3 (axe) and Class 5 (mace) UUIDs from the game item tables. The
right-hand weapon is read once when the candidate receives its authoritative
probability decision; switching weapons afterward does not reroll that NPC.

Unknown IDs remain neutral, preserving compatibility without guessing from
item names. Add-ons can register new heavy weapon UUIDs through
`MercyStrike.WeaponClassifier.RegisterHeavyWeapon`. LuaUtils is not required;
the classifier and chance calculation use the base Lua API. Automatic verbose
weapon logging is disabled, while the bounded manual snapshot remains
available through `#ms_probe_weapon()`.

Development console helpers are explicit and never run automatically:

```text
#ms_help()             List every Mercy Strike console command
#ms_dev_give_mace()    Add one full-condition spiked bludgeon for testing
#ms_dev_give_axe()     Add one full-condition work axe for testing
#ms_dev_show_chance()  Show the equipped weapon and current chance breakdown
```

The two give commands intentionally modify Henry's inventory and are intended
only for controlled development saves.

The design is intentionally probabilistic: Mercy Strike creates occasional
memorable outcomes rather than making every NPC unconscious.

## Planned Features

- Add weapon-aware balancing for other weapon families.
- Refine the Mod Menu wording and layout through in-game testing.
- Continue tuning fall timing, release timing, and MercyGuard through broader
  gameplay testing.
- Strengthen boss, quest-NPC, civilian, and special-entity safeguards.

## Known Limitations

- An NPC can die normally if a lethal hit reaches zero HP before Mercy Strike
  has selected and armed that NPC. This includes an opening attack that starts
  combat and kills immediately, or a first qualifying observed damage
  transition that is already lethal. Several rapid attacks can also land before
  the combat detector acquires the encounter; visible hits are not necessarily
  observed HP transitions.
- Mercy Strike intentionally does not run a permanent fast pre-combat poller
  or broadly pre-arm nearby NPCs. This protects performance and avoids
  modifying civilians without reliable combat evidence.
- Modded heavy weapons with new UUIDs remain neutral unless their add-on
  registers the UUID with Mercy Strike's classifier.
- Some low-health fallback transitions can look less natural than an
  engine-detected fall. Animation and timing polish comes after the final
  selection logic is stable.
