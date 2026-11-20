// The cards: what each costs, whom it targets and what it does (CARDS), and how a play resolves (play_card).
package deckbuilder

import "unified:dmath"
import "unified:sim"

// Every card. None is no card (an empty offer); the rewards offer Cleave ..= Hand_Off.
Card_Id :: enum u8 {
	None,
	Strike,
	Defend,
	Cover,
	Channel,
	Cleave,
	Heavy_Blow,
	Twin_Strike,
	Expose,
	Hex,
	Execute,
	Second_Wind,
	Battle_Cry,
	Taunt,
	Bulwark,
	Linked_Guard,
	Mend,
	Rally,
	Hand_Off,
}

REWARD_FIRST :: Card_Id.Cleave // the cards a reward offers: REWARD_FIRST ..= max(Card_Id)

// Whom a card is played at.
Target_Kind :: enum u8 {
	Self,
	Enemy, // one living enemy (Command_Play_Card.enemy)
	All_Enemies,
	Ally, // any hero in the run, the player's own included (Command_Play_Card.ally)
}

// One step of a card's effect, in order.
Op_Kind :: enum u8 {
	None,
	Damage, // `amount` to the target enemy, `times` times
	Damage_All, // `amount` to every enemy
	Block, // the player's hero gains `amount` block
	Block_Ally, // the target hero gains `amount` block
	Energy_Ally, // the target hero gains `amount` energy
	Draw, // the player's hero draws `amount`
	Draw_Ally, // the target hero draws `amount` from their own pile
	Vulnerable, // the target enemy: `amount` turns of Vulnerable
	Weak, // the target enemy: `amount` turns of Weak
	Strength, // the player's hero: `amount` Strength for the fight
	Taunt, // every enemy targets the player's hero this round
	Heal_Ally, // the target hero heals `amount`
	Energy_On_Kill, // when this card's damage killed its target: every hero gains `amount` energy
	Hand_Off, // the play's `extra` card goes from the player's hand to the target's (home after the fight)
}

Op :: struct {
	kind:   Op_Kind,
	amount: i8,
	times:  u8, // Damage: hits (0: one)
	plus:   i8, // added to `amount` on an upgraded card
}

Card_Def :: struct {
	cost:    u8,
	target:  Target_Kind,
	exhaust: bool, // played: to the exhaust pile, out of the fight
	ops:     [3]Op,
}

// The card table: the rules of every card (README, Cards).
@(rodata)
CARDS := [Card_Id]Card_Def {
	.None = {},
	.Strike = {cost = 1, target = .Enemy, ops = {{kind = .Damage, amount = 6, plus = 3}, {}, {}}},
	.Defend = {cost = 1, target = .Self, ops = {{kind = .Block, amount = 5, plus = 3}, {}, {}}},
	.Cover = {cost = 1, target = .Ally, ops = {{kind = .Block_Ally, amount = 7, plus = 3}, {}, {}}},
	.Channel = {cost = 0, target = .Ally, exhaust = true, ops = {{kind = .Energy_Ally, amount = 1, plus = 1}, {}, {}}},
	.Cleave = {cost = 1, target = .All_Enemies, ops = {{kind = .Damage_All, amount = 6, plus = 3}, {}, {}}},
	.Heavy_Blow = {cost = 2, target = .Enemy, ops = {{kind = .Damage, amount = 14, plus = 4}, {}, {}}},
	.Twin_Strike = {cost = 1, target = .Enemy, ops = {{kind = .Damage, amount = 5, times = 2, plus = 2}, {}, {}}},
	.Expose = {cost = 1, target = .Enemy, ops = {{kind = .Vulnerable, amount = 2, plus = 1}, {}, {}}},
	.Hex = {cost = 1, target = .Enemy, ops = {{kind = .Weak, amount = 2, plus = 1}, {kind = .Draw, amount = 1}, {}}},
	.Execute = {
		cost   = 2,
		target = .Enemy,
		ops    = {{kind = .Damage, amount = 10, plus = 4}, {kind = .Energy_On_Kill, amount = 1}, {}},
	},
	.Second_Wind = {
		cost   = 1,
		target = .Self,
		ops    = {{kind = .Draw, amount = 2, plus = 1}, {kind = .Block, amount = 3, plus = 2}, {}},
	},
	.Battle_Cry = {cost = 1, target = .Self, exhaust = true, ops = {{kind = .Strength, amount = 2, plus = 1}, {}, {}}},
	.Taunt = {cost = 1, target = .Self, ops = {{kind = .Block, amount = 8, plus = 3}, {kind = .Taunt}, {}}},
	.Bulwark = {cost = 2, target = .Ally, ops = {{kind = .Block_Ally, amount = 14, plus = 4}, {}, {}}},
	.Linked_Guard = {
		cost   = 1,
		target = .Ally,
		ops    = {{kind = .Block, amount = 6, plus = 2}, {kind = .Block_Ally, amount = 6, plus = 2}, {}},
	},
	.Mend = {cost = 1, target = .Ally, exhaust = true, ops = {{kind = .Heal_Ally, amount = 8, plus = 4}, {}, {}}},
	.Rally = {cost = 1, target = .Ally, ops = {{kind = .Draw_Ally, amount = 2, plus = 1}, {}, {}}},
	.Hand_Off = {cost = 0, target = .Ally, ops = {{kind = .Hand_Off}, {}, {}}},
}

// Why a play was refused (Event_Play_Refused): the card stays in hand and the energy is kept.
Refusal :: enum u8 {
	Not_Now, // not the heroes' turn, or the hero is down or ready
	Not_In_Hand, // the card is not in the player's hand (played already, or an ally's)
	No_Energy,
	No_Target, // the target is gone: an ally's play killed it first, or it never was
	Hand_Full, // Hand Off: the target's hand is full
}

// A card's amount for an op: its own, plus `plus` when upgraded.
op_amount :: proc(op: Op, upgraded: bool) -> i16 {
	return i16(op.amount) + (i16(op.plus) if upgraded else 0)
}

// Plays a card: the hero's command (Command_Play_Card) checked against the state as it is on this tick (an ally's play may
// have changed it since the player sent it), then paid and resolved op by op. A refusal changes nothing and says why.
play_card :: proc(t: ^Tick, hero_index: int, play: Command_Play_Card) {
	hero := &t.state.heroes[hero_index]
	refuse :: proc(t: ^Tick, hero_index: int, play: Command_Play_Card, why: Refusal) {
		sim.emit(t, Event_Play_Refused{card = play.card, hero = u8(hero_index), reason = why})
	}
	if t.state.phase != .Heroes && t.state.phase != .Enemies do return // no fight: nothing to refuse
	if t.state.phase != .Heroes || hero.down || hero.ready {
		refuse(t, hero_index, play, .Not_Now)
		return
	}
	card := sim.get(&t.state.cards, play.card)
	at := hand_index(hero, play.card)
	if card == nil || at < 0 {
		refuse(t, hero_index, play, .Not_In_Hand)
		return
	}
	def := CARDS[card.id]
	if int(hero.energy) < int(def.cost) {
		refuse(t, hero_index, play, .No_Energy)
		return
	}
	enemy: ^Enemy
	ally := -1
	switch def.target {
	case .Self, .All_Enemies:
	case .Enemy:
		enemy = sim.get(&t.state.enemies, play.enemy)
		if enemy == nil {
			refuse(t, hero_index, play, .No_Target)
			return
		}
	case .Ally:
		ally = int(play.ally) - 1
		if ally < 0 || ally >= PLAYERS || !t.state.heroes[ally].in_run || t.state.heroes[ally].down {
			refuse(t, hero_index, play, .No_Target)
			return
		}
	}
	extra_at := -1
	for op in def.ops {
		if op.kind != .Hand_Off do continue
		extra_at = hand_index(hero, play.extra)
		if extra_at < 0 || play.extra == play.card || ally == hero_index {
			refuse(t, hero_index, play, .No_Target)
			return
		}
		if t.state.heroes[ally].hand.count >= HAND_MAX {
			refuse(t, hero_index, play, .Hand_Full)
			return
		}
	}

	hero.energy -= def.cost
	sim.ordered_remove(&hero.hand, at)
	sim.emit(t, Event_Card_Played {
		card   = play.card,
		hero   = u8(hero_index),
		played = card.id,
		ally   = play.ally if def.target == .Ally else 0,
		enemy  = play.enemy if def.target == .Enemy else {},
	})
	if def.target == .Ally && ally != hero_index && .Bond_Ring in hero.relics {
		gain_block(t, hero_index, BOND_RING_BLOCK)
	}
	killed := false
	for op in def.ops {
		amount := op_amount(op, card.upgraded)
		switch op.kind {
		case .None:
		case .Damage:
			for _ in 0 ..< dmath.max(int(op.times), 1) {
				if sim.get(&t.state.enemies, play.enemy) == nil do break // the first hit killed it
				killed ||= hit_enemy(t, play.enemy, attack_damage(hero, amount))
			}
		case .Damage_All:
			damage := attack_damage(hero, amount)
			enemies := sim.iterate(&t.state.enemies)
			for _, handle in sim.next(&enemies) do hit_enemy(t, handle, damage)
		case .Block:
			gain_block(t, hero_index, amount)
		case .Block_Ally:
			gain_block(t, ally, amount)
		case .Energy_Ally:
			t.state.heroes[ally].energy += u8(amount)
		case .Draw:
			draw(t, hero_index, int(amount))
		case .Draw_Ally:
			draw(t, ally, int(amount))
		case .Vulnerable:
			if target := sim.get(&t.state.enemies, play.enemy); target != nil do target.vulnerable += u8(amount)
		case .Weak:
			if target := sim.get(&t.state.enemies, play.enemy); target != nil do target.weak += u8(amount)
		case .Strength:
			hero.strength += i8(amount)
		case .Taunt:
			hero.taunt = true
		case .Heal_Ally:
			heal(t, ally, amount)
		case .Energy_On_Kill:
			if !killed do break
			for &other in t.state.heroes do if other.in_run && !other.down do other.energy += u8(amount)
		case .Hand_Off:
			extra := hero.hand.items[hand_index(hero, play.extra)]
			sim.ordered_remove(&hero.hand, hand_index(hero, play.extra))
			if moved := sim.get(&t.state.cards, extra); moved != nil do moved.holder = u8(ally)
			sim.append(&t.state.heroes[ally].hand, extra)
			sim.emit(t, Event_Card_Drawn{card = extra, hero = u8(ally)})
		}
	}
	sim.append(&hero.exhaust if def.exhaust else &hero.discard, play.card)
	check_fight_won(t)
}

// Where a card is in the hero's hand (-1: not there).
hand_index :: proc(hero: ^Hero, card: sim.Handle(Card)) -> int {
	for held, i in sim.slice(&hero.hand) do if held == card do return i
	return -1
}

// A hero's attack before the target's defences: the card's amount, their Strength, the Whetstone on the fight's first
// attack, three quarters of it while Weak.
attack_damage :: proc(hero: ^Hero, amount: i16) -> i16 {
	damage := amount + i16(hero.strength)
	if .Whetstone in hero.relics && !hero.whetstone_used {
		damage += WHETSTONE_BONUS
		hero.whetstone_used = true
	}
	if hero.weak > 0 do damage = damage * 3 / 4
	return dmath.max(damage, 0)
}
