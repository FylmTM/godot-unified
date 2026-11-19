// The enemies: what each is (ENEMIES), what a fight puts up, their intents and how they act on them.
package deckbuilder

import "unified:dmath"
import "unified:sim"

Enemy_Def :: struct {
	hp:    i16, // before scaling by the party (SCALE_HEROES) and the tuning
	cycle: [3]Intent, // its intents in turn (kind None: the cycle is shorter)
}

FORTIFY_OTHER :: 6 // the Bulwark's Fortify: block to another enemy
SUMMON_AT_PCT :: 50 // the Hollow King calls two Gnashers once its HP falls to this %

// The enemies' rules (README, Enemies). A cycle's target is chosen when the intent is (`target` is filled then).
@(rodata)
ENEMIES := [Enemy_Kind]Enemy_Def {
	.Gnasher = {
		hp    = 22,
		cycle = {{kind = .Attack, amount = 6}, {kind = .Attack, amount = 6}, {kind = .Defend, amount = 8}},
	},
	.Spitter = {hp = 18, cycle = {{kind = .Attack_All, amount = 4}, {kind = .Weaken, amount = 2}, {}}},
	.Bulwark = {
		hp    = 34,
		cycle = {{kind = .Fortify, amount = 10}, {kind = .Fortify, amount = 10}, {kind = .Attack, amount = 14}},
	},
	.Hollow_King = {
		hp    = 140,
		cycle = {{kind = .Attack_All, amount = 8}, {kind = .Mark, amount = 2}, {kind = .Crush, amount = 25}},
	},
}

// Puts up the fight of a node (zeroed table: its handles start over each fight), from the fight's stream: two of
// Gnasher and Spitter on the first floors, a Bulwark with them later; an elite is a Bulwark and two Gnashers; the
// boss is alone.
spawn_fight :: proc(t: ^Tick) {
	t.state.enemies = {}
	t.state.boss_summoned = false
	switch t.state.node {
	case .Boss:
		spawn_enemy(t, .Hollow_King)
	case .Elite:
		spawn_enemy(t, .Bulwark)
		spawn_enemy(t, .Gnasher)
		spawn_enemy(t, .Gnasher)
	case .Fight, .None, .Rest, .Treasure:
		count := 2 if t.state.floor < 3 else 2 + int(sim.rng_below(&t.state.fight, 2))
		for k in 0 ..< count {
			kind := Enemy_Kind(sim.rng_below(&t.state.fight, 2)) // Gnasher or Spitter
			if k == 0 && t.state.floor >= 3 do kind = .Bulwark
			spawn_enemy(t, kind)
		}
	}
}

// An enemy at full HP for the party's size, with its first intent.
spawn_enemy :: proc(t: ^Tick, kind: Enemy_Kind) {
	enemy, _, ok := sim.spawn(&t.state.enemies)
	if !ok do return
	heroes: i16 = 0
	for &hero in t.state.heroes do heroes += 1 if hero.in_run else 0
	hp := ENEMIES[kind].hp * (heroes + SCALE_HEROES) / 2
	if t.setup.tuning == .Quick do hp = dmath.max(hp / QUICK_HP_DIV, 1)
	enemy^ = {
		kind   = kind,
		hp     = hp,
		max_hp = hp,
	}
	choose_intent(t, enemy)
}

// The enemy's next intent from its cycle, aimed at an awake hero drawn from the fight's stream (the marked one for a
// Crush). Drawn when the heroes' turn starts, so every client shows the same plan and no command's tick moves it.
choose_intent :: proc(t: ^Tick, enemy: ^Enemy) {
	cycle := ENEMIES[enemy.kind].cycle
	length := u8(0)
	for intent in cycle do length += 1 if intent.kind != .None else 0
	enemy.intent = cycle[enemy.step % length]
	enemy.step += 1
	switch enemy.intent.kind {
	case .Attack_All:
		enemy.intent.target = ALL_HEROES
	case .Crush:
		enemy.intent.target = enemy.marked - 1 if enemy.marked > 0 else random_target(t)
	case .Attack, .Weaken, .Mark:
		enemy.intent.target = random_target(t)
	case .Defend, .Fortify, .None:
	}
}

// A hero still standing, from the fight's stream: an awake one, or with nobody here (a run continued from a save, at
// tick 0) any of the run's (ALL_HEROES: none). An intent at a hero asleep when it acts finds another (enemy_act).
random_target :: proc(t: ^Tick) -> u8 {
	standing: [PLAYERS]u8
	count := 0
	for pass in 0 ..< 2 {
		for &hero, index in t.state.heroes {
			if hero.in_run && !hero.down && (pass == 1 || awake(t, index)) {
				standing[count] = u8(index)
				count += 1
			}
		}
		if count > 0 do break
	}
	if count == 0 do return ALL_HEROES
	return standing[sim.rng_below(&t.state.fight, u32(count))]
}

// The enemy acts on its intent. A single target that can't be hit any more (asleep, down) gives way to another drawn
// from the fight's stream; a taunting hero takes every single-target attack.
enemy_act :: proc(t: ^Tick, handle: sim.Handle(Enemy)) {
	enemy := sim.get(&t.state.enemies, handle)
	if enemy == nil do return
	intent := enemy.intent
	target := int(intent.target)
	if intent.kind == .Attack || intent.kind == .Crush || intent.kind == .Weaken || intent.kind == .Mark {
		for &hero, index in t.state.heroes do if hero.taunt && awake(t, index) && !hero.down do target = index
		if target >= PLAYERS || !awake(t, target) || t.state.heroes[target].down {
			target = int(random_target(t))
			if target == ALL_HEROES do return
		}
		intent.target = u8(target)
	}
	sim.emit(t, Event_Enemy_Acted{enemy = handle, intent = intent})
	damage := intent.amount
	if enemy.weak > 0 do damage = damage * 3 / 4
	switch intent.kind {
	case .None:
	case .Attack, .Crush:
		hit_hero(t, target, damage)
	case .Attack_All:
		for _, index in t.state.heroes do if awake(t, index) do hit_hero(t, index, damage)
	case .Defend:
		enemy.block += intent.amount
	case .Fortify:
		enemy.block += intent.amount
		others := sim.iterate(&t.state.enemies)
		for other, other_handle in sim.next(&others) {
			if other_handle == handle do continue
			other.block += FORTIFY_OTHER
			break
		}
	case .Weaken:
		t.state.heroes[target].weak += u8(intent.amount)
	case .Mark:
		t.state.heroes[target].vulnerable += u8(intent.amount)
		enemy.marked = u8(target) + 1
	}
}

// A hero's hit on an enemy: three halves while Vulnerable, taken by its block first. True when it killed it; the
// Hollow King calls two Gnashers the first time its HP falls to SUMMON_AT_PCT.
hit_enemy :: proc(t: ^Tick, handle: sim.Handle(Enemy), damage: i16) -> (killed: bool) {
	enemy := sim.get(&t.state.enemies, handle)
	if enemy == nil do return false
	damage := damage
	if enemy.vulnerable > 0 do damage = damage * 3 / 2
	blocked := dmath.min(damage, enemy.block)
	enemy.block -= blocked
	taken := dmath.min(damage - blocked, enemy.hp)
	enemy.hp -= taken
	sim.emit(t, Event_Enemy_Hit{enemy = handle, amount = taken, blocked = blocked})
	if enemy.hp <= 0 {
		sim.emit(t, Event_Enemy_Died{enemy = handle})
		sim.despawn(&t.state.enemies, handle)
		return true
	}
	if enemy.kind == .Hollow_King &&
	   !t.state.boss_summoned &&
	   i32(enemy.hp) * 100 <= i32(enemy.max_hp) * SUMMON_AT_PCT {
		t.state.boss_summoned = true
		spawn_enemy(t, .Gnasher)
		spawn_enemy(t, .Gnasher)
	}
	return false
}
