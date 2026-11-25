// The standard scenarios on a Setup other than the game's (Suite.setup) and a reference run pinned on one
// (Reference.setup), as a game proves a Setup that plays differently (a crowd, a mode): every run kind plays it,
// offline, sync-tested, interleaved, in a session (a late joiner too) and the reference's run, snapshot and log.
package test_scenarios

import "core:testing"

import "../toy"
import "unified:headless"
import "unified:headless/scenarios"
import "unified:netcode"
import "unified:sim"

// Things live 5 ticks longer than on the toy's default Setup: every run's checksums move.
@(private = "file")
LONGER_LIVES :: toy.Setup {
	life_bonus = 5,
}

@(private = "file")
LONGER_SUITE := scenarios.Suite(toy.Game) {
	game    = &toy.GAME,
	players = 4,
	seed    = 42,
	ticks   = 640,
	setup   = LONGER_LIVES,
}

// The reference run on LONGER_LIVES, as its text (the toy's other reference: REFERENCE).
LONGER_REFERENCE :: scenarios.Reference {
	seed          = 7,
	players       = 4,
	ticks         = 600,
	snapshot_tick = 300,
	setup         = "life_bonus=5",
	checkpoints   = {0x62e09e4542e4aa24, 0xab83a7846628a0b2, 0x9019a367470cc63f, 0x7434797ee8e8a445},
	trace         = 0xd062dd1257622fab,
	snapshot      = 0x8755f506c6d82cac,
	log           = 0x67932730caa10deb,
	compat        = 0x23d982a0683116b3,
}

@(test)
rollback_every_tick_on_a_setup :: proc(t: ^testing.T) {scenarios.rollback_every_tick(t, &LONGER_SUITE)}
@(test)
presence_churn_on_a_setup :: proc(t: ^testing.T) {scenarios.presence_churn(t, &LONGER_SUITE)}
@(test)
two_runs_match_on_a_setup :: proc(t: ^testing.T) {scenarios.runs_match(t, &LONGER_SUITE)}
@(test)
four_clients_agree_on_a_bad_network_on_a_setup :: proc(t: ^testing.T) {scenarios.session_agrees(
		t,
		&LONGER_SUITE,
		4,
		.Bad,
	)}
@(test)
a_late_joiner_agrees_on_a_setup :: proc(t: ^testing.T) {scenarios.late_join_agrees(t, &LONGER_SUITE, .Wan, 3, 320)}
@(test)
the_reference_run_on_a_setup_reproduces :: proc(t: ^testing.T) {scenarios.reference_reproduces(
		t,
		&toy.GAME,
		LONGER_REFERENCE,
	)}

// Each run kind a scenario starts plays the Setup it is given: its checksums differ from the same run on the game's
// default, and what it records (a log, a snapshot) carries that Setup.
@(test)
every_run_kind_plays_the_setup_it_is_given :: proc(t: ^testing.T) {
	ticks, seed, players := LONGER_SUITE.ticks, LONGER_SUITE.seed, LONGER_SUITE.players
	default_log, setup_log: sim.Input_Log(toy.Game)
	defer sim.log_destroy(&default_log)
	defer sim.log_destroy(&setup_log)
	default_run := headless.run_sim(&toy.GAME, ticks, seed, players, input_log = &default_log)
	setup_run := headless.run_sim(&toy.GAME, ticks, seed, players, input_log = &setup_log, setup = LONGER_LIVES)
	testing.expect(t, setup_run.final_checksum != default_run.final_checksum, "run_sim")
	testing.expect_value(t, setup_log.setup, LONGER_LIVES)
	testing.expect_value(t, default_log.setup, toy.GAME.setup)

	default_synctest := headless.run_synctest(&toy.GAME, ticks, 8, seed, players)
	setup_synctest := headless.run_synctest(&toy.GAME, ticks, 8, seed, players, setup = LONGER_LIVES)
	testing.expect_value(t, setup_synctest.mismatches, 0)
	testing.expect(t, setup_synctest.final_checksum != default_synctest.final_checksum, "run_synctest")
	testing.expect_value(t, setup_synctest.final_checksum, setup_run.final_checksum)

	default_interleaved := headless.run_interleaved(&toy.GAME, ticks, seed, players)
	setup_interleaved := headless.run_interleaved(&toy.GAME, ticks, seed, players, LONGER_LIVES)
	testing.expect_value(t, setup_interleaved.mismatches, 0)
	testing.expect(t, setup_interleaved.final_checksum != default_interleaved.final_checksum, "run_interleaved")
	testing.expect_value(t, setup_interleaved.final_checksum, setup_run.final_checksum)

	default_snapshot, default_checksum := headless.run_snapshot(&toy.GAME, ticks, seed, players)
	defer delete(default_snapshot)
	setup_snapshot, setup_checksum := headless.run_snapshot(&toy.GAME, ticks, seed, players, LONGER_LIVES)
	defer delete(setup_snapshot)
	testing.expect(t, setup_checksum != default_checksum, "run_snapshot")
	if resumed, err := sim.from_snapshot(&toy.GAME, setup_snapshot);
	   testing.expect_value(t, err, sim.Snap_Error.None) {
		testing.expect_value(t, resumed.setup, LONGER_LIVES)
		sim.destroy(resumed)
	}

	config := headless.Session_Config {
		clients = 2,
		profile = netcode.PROFILES[.Wan],
		ticks   = 160,
		seed    = seed,
	}
	default_session := headless.session_run(&toy.GAME, config)
	defer headless.session_result_destroy(&default_session)
	setup_session := headless.session_run(&toy.GAME, config, LONGER_LIVES)
	defer headless.session_result_destroy(&setup_session)
	testing.expect(t, setup_session.ok, "the session on the Setup completes")
	testing.expect_value(t, setup_session.log.setup, LONGER_LIVES)
	default_checksums, setup_checksums := default_session.clients[0].checksums, setup_session.clients[0].checksums
	testing.expect(
		t,
		len(setup_checksums) > 0 &&
		len(setup_checksums) == len(default_checksums) &&
		setup_checksums[len(setup_checksums) - 1] != default_checksums[len(default_checksums) - 1],
		"session_run",
	)
}

// The reference on a Setup pins that Setup's run: the same parameters on the game's default end elsewhere.
@(test)
a_reference_on_a_setup_pins_that_setups_run :: proc(t: ^testing.T) {
	reference := LONGER_REFERENCE
	default_run := headless.run_sim(&toy.GAME, reference.ticks, reference.seed, reference.players)
	testing.expect(t, default_run.final_checksum != reference.checkpoints[3], "the default Setup's run")
	setup, problem := sim.struct_from_text(toy.GAME.setup, reference.setup)
	testing.expect_value(t, problem, "")
	setup_run := headless.run_sim(&toy.GAME, reference.ticks, reference.seed, reference.players, setup = setup)
	testing.expect_value(t, setup_run.final_checksum, reference.checkpoints[3])
}
