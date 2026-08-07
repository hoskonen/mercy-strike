# Mercy Strike

## Foreword

Mercy Strike brings the spirit of *Kingdom Come: Deliverance*'s mercy strike
back to *Kingdom Come: Deliverance II* as a dynamic RPG system. A defeated
enemy may collapse unconscious instead of dying outright, leaving Henry with
the choice to spare them or use the game's normal mercy-kill interaction.

The outcome is shaped by Henry's Warfare skill and the weapon in his hand.
Experienced fighters become more likely to produce knockouts, while axes and
maces receive a distinct advantage. Mercy Strike aims to make character growth
and weapon choice visible in combat instead of adding a fixed random KO chance.

## Overview

Mercy Strike works with the game's combat systems rather than replacing them:

- **Warfare progression:** Henry's Warfare skill steadily improves the chance
  of a Mercy Strike.
- **Weapon identity:** recognized axes and maces gain an additional knockout
  bonus.
- **Natural falls:** the engine performs the downed transition; the mod does
  not force a custom animation.
- **Meaningful aftermath:** unconscious NPCs remain alive and eligible for the
  vanilla mercy-kill interaction.
- **Vanilla outcomes remain:** NPCs that are not selected are left completely
  untouched.
- **Optional configuration:** Mod Configuration Menu and KCDUtils/LuaDB add
  in-game balancing and persistence without becoming requirements.

> **Experimental:** The core natural-down, finisher, lifecycle, and cleanup
> systems have been proven through extensive testing, but this remains an
> ambitious engine-driven mod. Please read the known limitations and report
> unusual animation timing or NPC behavior.

## Dynamic RPG System

Mercy Strike uses one authoritative chance roll for each eligible NPC during a
combat encounter. It is not a per-hit lottery, and changing weapons afterward
does not reroll that NPC.

With the default settings:

- Base Mercy Strike chance is **5%**.
- Warfare adds up to **+15 percentage points** at level 30.
- A recognized axe or mace adds **+15 percentage points**.
- Bonuses are additive and the final chance is capped at 100%.

```text
Mercy Strike chance = 5% + Warfare contribution + heavy-weapon bonus
Warfare contribution = Warfare level / 30 x 15%
Heavy-weapon bonus = +15% with a recognized axe or mace
```

| Henry's equipment and skill | Final chance |
|---|---:|
| Sword or other weapon, Warfare 0 | 5% |
| Sword or other weapon, Warfare 6 | 8% |
| Sword or other weapon, Warfare 30 | 20% |
| Axe or mace, Warfare 0 | 20% |
| Axe or mace, Warfare 6 | 23% |
| Axe or mace, Warfare 30 | 35% |

This keeps knockouts uncommon early in the game while allowing Henry's combat
experience to matter. Heavy weapons begin with a meaningful advantage and
retain it throughout progression. Unknown modded weapon IDs remain neutral
rather than being guessed from their names.

## Known Limitations

- An NPC can die normally if a lethal hit reaches zero HP before Mercy Strike
  has selected and armed that NPC. This includes an opening attack that starts
  combat and kills immediately, or a first qualifying observed damage
  transition that is already lethal. Several rapid attacks can also land
  before the combat detector acquires the encounter; visible hits are not
  necessarily observed HP transitions.
- Mercy Strike intentionally does not run a permanent fast pre-combat poller
  or broadly pre-arm nearby NPCs. This protects performance and avoids
  modifying civilians without reliable combat evidence.
- Occasionally, the unconscious-state transition does not align perfectly
  with the NPC's animation. An NPC may become unconscious while still standing
  or midway through a fall, producing an unintentionally funny result. This is
  a visual timing issue; the knockout itself may still succeed normally.
- Modded heavy weapons with new UUIDs remain neutral unless their add-on
  registers the UUID with Mercy Strike's classifier.

## How Mercy Strike Works

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

## Configuration and Optional Integrations

Mercy Strike has no required dependencies and works fully from the built-in
defaults in `MS_Config.lua`. Mod Configuration Menu provides in-game controls.
KCDUtils/LuaDB adds persistence when used with the menu; neither participates
in combat or knockout logic.

| Available integration | Behavior |
|---|---|
| None | Full gameplay using built-in defaults |
| Mod Menu only | In-game settings for the current game run; defaults return after restarting the game |
| KCDUtils/LuaDB only | Loads an existing saved record if present; otherwise uses defaults; no configuration interface |
| Full stack | In-game settings with persistence across game restarts |

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

The four player-facing RPG values can all be adjusted. The equipped right-hand
weapon is captured when the candidate receives its decision, so switching
weapons afterward does not alter or repeat the roll.

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
#ms_deps()             Show dependency and active settings status
#ms_dev_ko_stress_on() Select every acquired candidate and extend protection
#ms_dev_ko_stress_off() Restore the pre-test runtime settings
#ms_dev_give_mace()    Add one full-condition spiked bludgeon for testing
#ms_dev_give_axe()     Add one full-condition work axe for testing
#ms_dev_show_chance()  Show the equipped weapon and current chance breakdown
```

KO stress mode is session-only: it selects every acquired candidate, extends
the transition timeout to five minutes, and enables focused diagnostics. It
does not write LuaDB or change release defaults. First-hit lethal attacks can
still occur before candidate acquisition. Enable it before combat and disable
it after the encounter.

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
