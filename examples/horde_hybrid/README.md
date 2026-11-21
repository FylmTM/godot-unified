# horde_hybrid

What the game is in one paragraph: the genre, how many play, what a match or a run is, and what it shows of unified.
`uni run horde_hybrid` plays it. `GUIDE.md` is how to write gameplay that survives rollback (read it before the rules).

## Controls

Each action and its keys and buttons.

## World

The units and axes, what the State holds (and its capacities: `MAX_*`), and the World: the level and what the sim
reads from its markers, or why there is none.

## Input and commands

What `Input` carries and what a player's input moves; each command (`Command_*`) and what it does, naming each tuning
constant rather than its value.

## Systems (`tick`, in this order)

The rules in the order `tick` runs them, one line each, naming each tuning constant rather than its value: what the
world does on its own, how a match or a run ends, and the event (`Event_*`) each emits.

## Events

Each event (`Event_*`), what it says and whose view gets it, and the library's joins and leaves.

## Scripted inputs

What the scripted players do in headless runs and tests (`script.odin`).

## View contract (`simulation/extension`)

What each view and MultiView shows, which events it plays, and the session data (`Data_*`) the HUD reads.
