# deckbuilder: a co-op deck-building card battler

A co-op card battler, unified's example of a turn-based game with no physics and no world: 1–4 heroes climb one act
of `FLOORS` floors together, each with their own deck, hand, energy and relics, and fight the enemies on the way with
their cards, all playing at once. It shows what rollback netcode does for a game where nothing moves: the sim is pure
rules on a state block (card tables, piles as `sim.List`s, keyed random streams), plays are commands, the shared
"what I'm about to play" is each player's Input, a run saves and continues through the session's Setup, and the
whole Godot side is Controls fed with view data, drawn in code on a felt table (no image assets). A Godot project (this folder is `res://`): the sim, its tests, the
headless binary and the GDExtension in `simulation/` (Odin), everything Godot in `game/`. `uni run deckbuilder`
plays it; `uni coop deckbuilder` opens two windows in one session. How to write gameplay that survives rollback:
`docs/gameplay.md`.

Every rule number is a named constant in `simulation/deckbuilder/tuning.odin` (the cards' and enemies' own numbers in
their tables, `CARDS` and `ENEMIES`); this README names them. There is no physics and no World (`sim.No_World`).

## Controls

The mouse. Click a card to play it: a card at one enemy or at a hero is held up first (its targets light up), then
played by clicking its target (an enemy, or a hero's panel); right click, Esc or a second click puts it down. Hand Off
takes the card to hand over, then the ally. End turn (or Play on, to take it back while the turn lasts) beside the
hand. The camp, map, reward and rest panels are buttons, the map's nodes and the reward's cards too. Esc with no card
held opens the pause menu; F1 is the dev UI.

## The app

The Godot side is the examples' shared app layer (`game/app/`, `game/ui/`: the `.claude/skills/godot-examples` skill
says what each copy shares and where they differ): the main menu (Single player, Host online, Join with code, Join by
address or Host on LAN, Settings) on the felt with a fanned hand, the connect overlay, the pause menu (Resume, Invite
friends, Settings, Leave to menu; alone it pauses), the settings (the class among them) and the session panel top-right
(who is here, the code to share). The `Game` autoload owns the session and takes every one, however it started (the
menus, the session flags, `uni coop`), to the table (`game/table.tscn`).

At the table the session starts at the camp: pick the class (Vanguard or Arcanist, kept in the settings: alone, the
session starts again with it), Start a run, Continue the saved run (playing alone), or Invite friends (the running
session opens online, or on the LAN when this build can't). Online play needs a build with the EOS IDs compiled in:
`uni run` with `.env` set, or the zip `uni release deckbuilder` makes (`docs/EOS.md`).

What the table draws is the sim's, through its views and data: a card's face from its id and the constants (frame by
whom it is played at, cost gem, glyph, rules text), an enemy's medallion, intent badge, block and statuses, each hero's
plate and open hand, the map from the run's nodes and votes. Sounds, banners, flashes and damage numbers follow the
events, at once on an emitted event (a prediction shows them), banners and the log once confirmed.

## Heroes

A run's heroes are kept in the State, apart from the players: the session forgets its longest-absent member, and a
run outlives that. `Command_Start_Run` gives each present player a hero, in slot order, of their Profile's class (Vanguard
`VANGUARD_HP`, Arcanist `ARCANIST_HP`) with its starter deck (`STARTER_VANGUARD`, `STARTER_ARCANIST`). A hero whose
player is away **sleeps**: it is skipped, never targeted, and counts as ready and as having voted and picked, so the
others play on. A player who arrives takes their own hero back, else the lowest sleeping hero (`Event_Hero_Claimed`),
else watches. Hands are open: every player sees every hand and every ally's aim.

## A run

- **Camp** (tick 0): no run. `Command_Start_Run` starts one (`Event_Run_Started`): a seed of its own from the session's
  seed and the runs started, and the act's map from it (`generate_map`: `FLOORS` floors of `LANES` lanes, fights
  first, elites and a treasure or a rest in the middle, a rest before the boss alone on the last floor).
- **Map**: every awake hero votes for a lane of the next floor (`Command_Vote`, `Event_Voted`; the same lane or a
  neighbour). Once all have, the most-voted lane wins, a tie drawn from the floor's vote stream, and the party enters
  that node (`Event_Node_Entered`). Entering a node is the **save point**.
- **Fight, Elite, Boss**: a fight (below). Won: the **Reward**, `OFFERS` cards per hero (`LUCKY_COIN_OFFERS` with the
  Lucky Coin) from their own stream, and a relic each after an elite; each hero takes one or skips
  (`Command_Pick_Reward`, `Event_Reward_Picked`), a deck past `DECK_MAX` losing it. Won against the boss: the run is won.
- **Rest**: each hero heals `REST_HEAL_PCT` of their max HP or upgrades a card of their deck (`Command_Rest`,
  `Event_Rested`).
- **Treasure**: a relic each (`Event_Relic_Gained`), then the map.
- **Over** (the boss fell, or every awake hero is down: `Event_Run_Over`): `OVER_HOLD_S`, then the camp. The save is
  cleared.

## A fight

1. It starts: the enemies (`spawn_fight`, from the fight's stream for the floor), every hero's whole deck shuffled
   into their draw pile from their own stream, block and statuses cleared.
2. **The heroes' turn**: `ENERGY` each, block gone, `HAND_SIZE` cards drawn (`Event_Card_Drawn`; an empty draw pile
   takes the discard pile, shuffled; a hand holds `HAND_MAX`, the rest goes to the discard pile). Every hero plays at
   once: a play (`Command_Play_Card`) is checked on the tick it lands, against the state as the plays before it in that
   tick left it (slot order), so an ally's kill can take a target away. A refused play changes nothing
   (`Event_Play_Refused`, its `Refusal`); one that holds pays its cost and resolves its ops in order
   (`Event_Card_Played`, `Event_Enemy_Hit`, `Event_Enemy_Died`, `Event_Hero_Blocked`, `Event_Hero_Healed`). A card
   that exhausts leaves the fight; the others go to the discard pile.
3. The turn ends once every awake hero still standing is ready (`Command_End_Turn`, which can also take it back).
4. **The enemies' turn**: their block goes, then each living enemy acts on its intent, one every `ENEMY_BEAT_S` of sim
   time (`Event_Enemy_Acted`, `Event_Hero_Hit`, `Event_Hero_Down`). A hero at 0 HP is down for the fight; every awake
   hero down loses the run.
5. The round ends: statuses count down, hands go to the discard pile, every enemy shows its next intent, and the
   heroes' turn comes again.
6. Every enemy fell (`Event_Fight_Won`): a hero down gets up with `REVIVE_PCT` of their max HP, every card goes back
   to its own deck.

## Cards

`CARDS` (`cards.odin`) is every card's cost, target (itself, an enemy, every enemy, or a hero, the player's own
included) and up to three ops, each with what an upgrade adds; `Unified.constants.cards` carries the text the
extension writes from it. Attack damage counts the hero's Strength, Weak and the target's Vulnerable (three halves).
The co-op cards act on an ally (block, energy, draws from their own pile, healing) or for the party: Taunt (every
single-target attack hits the taunter), Execute (energy for every hero when it kills), and Hand Off, which moves
another card from the player's hand to the ally's until the fight ends. The rewards offer every card from `REWARD_FIRST` on.

## Enemies

`ENEMIES` (`enemies.odin`) is each kind's HP and its cycle of intents, shown before they act: attack one hero, attack
everyone, defend, weaken a hero, fortify (block to itself and `FORTIFY_OTHER` to another), and the boss's mark and
crush. An enemy's HP scales with the heroes in the run (`SCALE_HEROES`). A single-target intent aims at an awake
hero drawn when it is chosen; if that hero is asleep or down when it acts, another is drawn. The Hollow King calls two
Gnashers once its HP falls to `SUMMON_AT_PCT`.

## Relics

Each hero their own, from an elite or a treasure: the Whetstone (`WHETSTONE_BONUS` to the first attack of a fight),
the Ember Charm (`EMBER_CHARM_ENERGY` on a fight's first turn), the Bond Ring (`BOND_RING_BLOCK` whenever a card
targets an ally), the Mender's Pouch (`MENDERS_POUCH_HEAL` after each fight won) and the Lucky Coin (more offers).

## Systems (`tick`, in this order)

1. `claim_heroes`: who arrived takes a hero (Heroes).
2. `apply_commands`: each slot's commands in slot order (`Command_Start_Run`, `Command_Play_Card`, `Command_End_Turn`,
   `Command_Vote`, `Command_Pick_Reward`, `Command_Rest`; `Command_Dev_Win_Fight` in a dev UI build). A command outside its phase is
   ignored.
3. The phase: `count_votes` on the map, `heroes_turn` and `enemies_turn` in a fight, `check_picked` at a reward or a
   rest, `over_hold` at the end.

## Randomness

Nothing random is drawn from a shared sequence that a command's tick could move: every draw comes from a stream keyed
by the run's seed, a purpose (`Roll`), a hero and a floor (`sim.rng_keyed`), so a hero's shuffles, offers and relics
on a floor are the same however the party plays, and a continued run deals its fight again exactly. Intents are drawn
when the heroes' turn starts, never when a play lands.

## The save

`Game.save` gives the run as it entered its last node (`State.save`, a `Setup`: the floor and lane, the run's seed and
each hero's class, HP, relics and deck), and nothing at the camp or after the run's end. The `Game` autoload writes it to
`user://deckbuilder_save.json` whenever it changes (`UnifiedSession.save_changed`, `UnifiedSetup.to_json`), on every
player's machine, so any of them can host the continuation. Continue starts a single session with it
(`UnifiedSetup.from_json`); its tick 0 restores the heroes, asleep until their players come, and enters the node
again. A save this build can't read (`UnifiedSetup.json_problem`) is named at the camp instead of offered.

## Tunings

`Setup.tuning`: `play` (`GAME`, what the Godot side runs) and `quick` (`GAME_QUICK`: enemy HP divided by
`QUICK_HP_DIV`, so the scripted party crosses the act; the headless binary, the end-to-end suite, the reference run
and the bench run it).

## Scripted inputs

The scripted player (`script.odin`) is a pure function of (seed, slot, tick). It can't see its hand: it names its own
starter cards by where a run deals them in the card table, every `SCRIPT_PLAY_EVERY` ticks at the first enemies and an
ally, ends its turn every `SCRIPT_END_TURN_EVERY`, votes, picks and rests every `SCRIPT_CHOOSE_EVERY`, and slot 0
starts a run every `SCRIPT_START_EVERY` at the camp. Many of its plays are refused, which keeps the refusal path
exercised. Its Profile alternates the classes by slot (`scripted_profile`).

## View contract (`simulation/extension`)

- Scene views, Controls with data only (the host sets their fields and never poses them):
  - `card` (`View_Card`), one per card in a hand, keyed by the card's handle: it spawns under the board's Hands node
    (its marker's `parent_path`) and moves itself into its holder's hand box, the local hero's big hand or an ally's
    small one, in slot order. `playable` says the local player could play it now; `held` that its holder aims it.
  - `enemy` (`View_Enemy`), keyed by its handle, in the enemies' row: HP, block, statuses, its intent and whom at, and
    which heroes aim at it.
  A played or discarded card and a dead enemy fade while their view lingers; a rollback that brings them back
  revives them.
- Session data: `Unified.data.run` (`Data_Run`: the phase, floor, map, votes, the local hero's offers and deck) and
  `Unified.data.heroes` (`Data_Heroes`: each hero's row, with their aim and pile sizes).
- Constants: each card's text (and its upgraded text), cost, target and whether it exhausts (a reward's or a rest's
  card, which no view holds, is drawn from them), each relic's text, `FLOORS` and `LANES`.
- Input: the aim (`Input`: the held card's place in the hand, the enemy or hero it hovers), set by the table
  (`Unified.input`); every ally's panel and every enemy show it.
- Commands: everything else (plays, end turn, votes, rewards, rests, starting a run). Events update the log, flash a
  hero's panel or shake a refused card; effects play on an emitted event (a prediction shows them at once), the log
  once confirmed.
