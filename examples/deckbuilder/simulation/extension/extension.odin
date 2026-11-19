package deckbuilder_extension

import "core:fmt"
import "core:strings"
import "unified:godot"

import g "../deckbuilder"

GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame = fill_frame,
	data = Data,
	view_data = {.Card = Card_View, .Enemy = Enemy_View}, // their enums are GDScript classes (EnumTargetKind, ...)
	input_values = Aim,
	is_2d = true, // a Control UI: nothing is posed
}

@(export, link_name = "deckbuilder_init")
deckbuilder_init :: proc "c" (
	get_proc_address: godot.Get_Proc_Address,
	library: godot.Class_Library,
	initialization: ^godot.Initialization,
) -> godot.Init_Result {
	return godot.init(&g.GAME, GLUE, get_proc_address, library, initialization, constants = constants)
}

// What a card says, made from its rules (g.CARDS), so the text never disagrees with them.
Card_Text :: struct {
	text:     string,
	upgraded: string, // its upgraded version's
}

// The constants (Unified.constants): each card's text and each relic's, by their enums, and the map's size.
Data_Constants :: struct {
	cards:  [g.Card_Id]Card_Text,
	relics: [g.Relic]string,
	floors: i32, // g.FLOORS
	lanes:  i32,
}

constants :: proc() -> Data_Constants {
	result: Data_Constants
	for id in g.Card_Id do result.cards[id] = {
		text     = card_text(id, false),
		upgraded = card_text(id, true),
	}
	result.floors, result.lanes = g.FLOORS, g.LANES
	result.relics = {
		.Whetstone     = fmt.aprintf("The first attack of each fight deals %d more.", g.WHETSTONE_BONUS),
		.Ember_Charm   = fmt.aprintf("The first turn of each fight: +%d energy.", g.EMBER_CHARM_ENERGY),
		.Bond_Ring     = fmt.aprintf("Whenever you target an ally, gain %d block.", g.BOND_RING_BLOCK),
		.Menders_Pouch = fmt.aprintf("Heal %d after each fight.", g.MENDERS_POUCH_HEAL),
		.Lucky_Coin    = fmt.aprintf("%d card rewards instead of %d.", g.LUCKY_COIN_OFFERS, g.OFFERS),
	}
	return result
}

// A card's rules text, op by op (allocated for the process: constants live as long as it).
card_text :: proc(id: g.Card_Id, upgraded: bool) -> string {
	def := g.CARDS[id]
	out := strings.builder_make()
	for op in def.ops {
		amount := g.op_amount(op, upgraded)
		switch op.kind {
		case .None:
			continue
		case .Damage:
			fmt.sbprintf(&out, "Deal %d damage", amount)
			if op.times > 1 do fmt.sbprintf(&out, " %d times", op.times)
		case .Damage_All:
			fmt.sbprintf(&out, "Deal %d damage to every enemy", amount)
		case .Block:
			fmt.sbprintf(&out, "Gain %d block", amount)
		case .Block_Ally:
			fmt.sbprintf(&out, "A hero gains %d block", amount)
		case .Energy_Ally:
			fmt.sbprintf(&out, "A hero gains %d energy", amount)
		case .Draw:
			fmt.sbprintf(&out, "Draw %d", amount)
		case .Draw_Ally:
			fmt.sbprintf(&out, "A hero draws %d", amount)
		case .Vulnerable:
			fmt.sbprintf(&out, "%d Vulnerable", amount)
		case .Weak:
			fmt.sbprintf(&out, "%d Weak", amount)
		case .Strength:
			fmt.sbprintf(&out, "Gain %d Strength", amount)
		case .Taunt:
			fmt.sbprint(&out, "Enemies target you this round")
		case .Heal_Ally:
			fmt.sbprintf(&out, "Heal a hero %d", amount)
		case .Energy_On_Kill:
			fmt.sbprintf(&out, "On a kill, every hero gains %d energy", amount)
		case .Hand_Off:
			fmt.sbprint(&out, "Give an ally another card from your hand")
		}
		fmt.sbprint(&out, ". ")
	}
	if def.exhaust do fmt.sbprint(&out, "Exhaust.")
	return strings.trim_space(strings.to_string(out))
}

// What the UI's scripts set on Unified.input: the card the player holds up and at whom (the Input).
Aim :: struct {
	card:  u8, // a hand place + 1 (0: none)
	enemy: u8, // an enemy's table index + 1
	hero:  u8, // a hero + 1
	_pad:  u8,
}

sample_input :: proc(_: int, input: ^g.Input) {
	aim := godot.input_values(Aim)
	input^ = {
		card  = aim.card,
		enemy = aim.enemy,
		hero  = aim.hero,
	}
}
