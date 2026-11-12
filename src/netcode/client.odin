// The client (src/netcode/SPEC.md), generic over the game: a verified frame advanced only with finalized
// inputs, a predicted frame up to the local tick (own inputs and commands + the others' last finalized
// input repeated), rollback on misprediction, a prediction cap, adaptive input delay and a 2% clock slew
// towards relay tick + delay. Own commands are resent until the relay acks them and predicted until a
// finalized tick carries them. Serves and receives late-join snapshots. Driven by client_step from
// the host's loop; talks to the host application through Hooks (all called from client_step).
package netcode

import "core:fmt"
// Used only inside generic procs: @(require) keeps -vet from calling it unused in a program that never instantiates
// them (a game's tests that don't run the netcode).
@(require) import "core:time"

import usim "unified:sim" // the field Client.sim shadows the package name
import "unified:wire"

Client_Config :: struct {
	slot:      int, // the slot to ask for; -1: any free slot
	join_tick: u32, // the earliest tick to become present (0: as soon as possible)
	compat:    u64, // build/game id the relay checks (0: sim.compat_of(game, content))
	content:   []u8, // the game's content (the level, src/level/SPEC.md); borrowed for the client's lifetime
	player:    string, // the player's display name (sent to the relay, shared with everyone)
	name:      string, // for log lines
	poll_us:   i64, // 0: DEFAULT_POLL_US
	quiet:     bool,
}

Status :: enum u8 {
	Idle,
	Connecting,
	Connected, // welcomed and simulating (a late joiner: once its snapshot is restored)
	Failed, // rejected, a protocol error, or the relay never answered
	Disconnected, // left, the session ended, or the connection was lost after it worked
}

// What changed in a step, for the view.
Frame_Info :: struct {
	tick:       u32, // the latest predicted tick (the sim's current tick)
	verified:   u32, // the latest verified tick
	resim_from: u32, // ticks resim_from..tick were computed in this step: their events are new
}

Hooks :: struct($S, $I, $W: typeid, $P: int) {
	user:     rawptr,
	// The local player's input for `tick`, sampled when the client's clock reaches it. `state` is
	// the latest predicted state (nil before the sim exists).
	sample:   proc(user: rawptr, slot: int, tick: u32, state: ^S) -> I,
	// Optional: the local player's commands for `tick`, called right after `sample` for every tick the
	// client generates. usim.send_command(out, cmd) returns false once COMMAND_QUEUE commands wait.
	commands: proc(user: rawptr, slot: int, tick: u32, state: ^S, out: ^usim.Command_Out),
	// After a step that computed new predicted ticks: the view reads sim.state_at(s, f.tick) and
	// f.tick - 1 for interpolation, and usim.events_at for ticks f.resim_from..f.tick.
	frame:    proc(user: rawptr, s: ^usim.Sim(S, I, W, P), f: Frame_Info),
	// Each newly verified tick, in order, with the events it emitted under the final inputs.
	verified: proc(user: rawptr, s: ^usim.Sim(S, I, W, P), tick: u32, events: []usim.Event),
	status:   proc(user: rawptr, status: Status, detail: string),
}

// An own command the client holds until a verified tick carries it.
@(private)
Own_Command :: struct {
	seq:  u32,
	want: u32, // the tick it was sent for (W)
	cmd:  usim.Command,
}

@(private)
Snap_Req :: struct {
	joiner:   int,
	min_tick: u32,
}

FIN_RING :: 512
#assert(CATCHUP_TICKS <= FIN_RING - 64) // a relay never streams ticks the ring would refuse
OWN_RING :: 512
PRED_RING :: 64
CHK_RING :: 64

// What a stepped tick was: verified for the first time, re-simulated after a rollback (with final or predicted
// inputs), or newly predicted.
Step_Kind :: enum u8 {
	Verified,
	Resim,
	Predicted,
}

Client :: struct($S, $I, $W: typeid, $P: int) {
	game:          ^usim.Game(S, I, W, P),
	cfg:           Client_Config,
	hooks:         Hooks(S, I, W, P),
	tm:            Timing,
	ch:            ^Channel,
	relay:         Peer,
	w:             wire.Writer,
	sim:           ^usim.Sim(S, I, W, P), // nil until welcomed (a late joiner: until its snapshot lands)
	status:        Status,
	detail:        string,
	hello_sent:    bool,
	// from Welcome
	welcomed:      bool,
	slot:          int,
	seed:          u64,
	ticks:         u32, // session length, 0: endless
	first_tick:    u32, // J: first tick this player is present
	// finalized inputs from the relay
	fin:           [FIN_RING]usim.Inputs(I, P),
	fin_tick:      [FIN_RING]u32,
	fin_scratch:   usim.Inputs(I, P), // a finalized tick being decoded
	fin_upto:      u32, // highest contiguous finalized tick held
	// frames
	verified:      u32, // V
	predicted:     u32, // P (the sim's current tick)
	local:         u32, // L (scheduler tick)
	resim_from:    u32,
	pred_inputs:   [PRED_RING]usim.Inputs(I, P),
	chk:           [CHK_RING]struct {
		tick:  u32,
		value: u64,
	},
	// own inputs
	own:           [OWN_RING]I,
	own_last:      u32,
	own_acked:     u32,
	// own commands: sent (until acked) and predicted until a verified tick carries them
	own_cmds:      [dynamic]Own_Command, // seq order
	cmd_seq:       u32, // the last seq given
	cmd_acked:     u32, // the relay has every seq up to this one
	cmd_out:       usim.Command_Out, // for hooks.commands
	// time sync
	started:       bool,
	offset_us:     f64, // relay time - local time
	have_offset:   bool,
	rtt_us:        f64,
	rtt_samples:   int,
	delay:         u32,
	delay_eval_us: i64,
	next_tick_us:  f64,
	last_send_us:  i64,
	// late join
	snap_reqs:     [dynamic]Snap_Req, // joiners waiting for our snapshot
	snap_buf:      [dynamic]u8,
	snap_total:    int,
	snap_tick:     u32,
	// end
	done_sent:     bool,
	end_us:        i64, // when End arrived or stop was called (0: not ending)
	leaving:       bool, // client_stop was called
	// results
	checksums:     [dynamic][2]u64, // (tick, checksum) of verified ticks divisible by 16, from J on
	rollbacks:     int,
	depth_sum:     int,
	depth_max:     int,
	stall_ticks:   int,
	resim_ticks:   int,
	delay_changes: int,
	// for the dev UI's graphs (cumulative; the host takes differences)
	own_replaced:  int, // finalized ticks where the relay replaced our input (it arrived too late)
	steps:         [Step_Kind]int, // ticks stepped, by kind
	step_us:       [Step_Kind]i64, // time spent stepping them, µs
	last_msg_us:   i64, // when the relay's last message arrived (now_us; 0: none yet)
	// roster from the relay
	connected:     [P]bool,
	names:         [P]Player_Name,
}

// The display name of the player in `slot` ("" if none or unknown).
client_player_name :: proc(c: ^Client($S, $I, $W, $P), slot: int) -> string {
	return name_string(&c.names[slot]) if slot >= 0 && slot < P else ""
}

// Creates a client talking to a relay over `link` (the client owns it). Nothing is sent until the
// first client_step.
client_create :: proc(
	game: ^usim.Game($S, $I, $W, $P),
	cfg: Client_Config,
	link: Link,
	hooks: Hooks(S, I, W, P),
) -> ^Client(S, I, W, P) {
	usim.check_plain(I)
	c := new(Client(S, I, W, P))
	c.game = game
	c.cfg = cfg
	if c.cfg.compat == 0 {
		c.cfg.compat = usim.compat_of(game, c.cfg.content)
	}
	if c.cfg.poll_us <= 0 {
		c.cfg.poll_us = DEFAULT_POLL_US
	}
	c.hooks = hooks
	c.tm = timing_of(game.tick_hz)
	c.ch = channel_make()
	li := channel_add_link(c.ch, link)
	c.relay = channel_peer(c.ch, li, 0)
	c.w = wire.writer_make(MAX_DATAGRAM)
	c.delay = 1
	c.slot = -1
	return c
}

client_destroy :: proc(c: ^Client($S, $I, $W, $P)) {
	channel_destroy(c.ch)
	if c.sim != nil {
		usim.destroy(c.sim)
	}
	delete(c.w.buf)
	delete(c.snap_buf)
	delete(c.snap_reqs)
	delete(c.checksums)
	delete(c.own_cmds)
	delete(c.cmd_out.list)
	free(c)
}

// Leaves the session: the relay frees the slot at once. Keep stepping until the status is
// Disconnected (at most ~0.5 s, so the Leave gets through).
client_stop :: proc(c: ^Client($S, $I, $W, $P), now: i64) {
	if c.status == .Failed || c.status == .Disconnected || c.end_us != 0 {
		return
	}
	if c.hello_sent {
		csend(c, msg_begin(&c.w, .Leave), .Reliable, now)
	}
	c.end_us = now
	c.leaving = true
	c.detail = "left"
}

// The latest predicted state (nil before the sim exists).
client_state :: proc(c: ^Client($S, $I, $W, $P)) -> ^S {
	return &c.sim.state if c.sim != nil else nil
}

client_rtt_ms :: proc(c: ^Client($S, $I, $W, $P)) -> f64 {
	return c.rtt_us / 1000
}

@(private)
set_status :: proc(c: ^Client($S, $I, $W, $P), st: Status, detail: string) {
	if c.status == st {
		return
	}
	c.status = st
	c.detail = detail
	if !c.cfg.quiet && (st == .Failed || st == .Disconnected) {
		fmt.eprintfln("%s: %v (%s)", c.cfg.name, st, detail)
	}
	if c.hooks.status != nil {
		c.hooks.status(c.hooks.user, st, detail)
	}
}

@(private)
csend :: proc(c: ^Client($S, $I, $W, $P), w: ^wire.Writer, d: Delivery, now: i64) {
	channel_send(c.ch, c.relay, w.buf[:], d, now)
}

@(private)
on_welcome :: proc(c: ^Client($S, $I, $W, $P), rd: ^wire.Reader) {
	slot := int(wire.r_u8(rd))
	seed := wire.r_u64(rd)
	hz := int(wire.r_u16(rd))
	ticks := wire.r_u32(rd)
	first := wire.r_u32(rd)
	from_start := wire.r_u8(rd) != 0
	if !rd.ok || c.welcomed || slot >= P || (c.cfg.slot >= 0 && slot != c.cfg.slot) {
		return
	}
	if hz != c.game.tick_hz {
		set_status(c, .Failed, "the relay runs another tick rate")
		return
	}
	c.welcomed = true
	c.slot = slot
	c.seed = seed
	c.ticks = ticks
	c.first_tick = first
	c.own_last = first - 1
	c.own_acked = first - 1
	if first <= 1 || from_start {
		c.sim = usim.create(c.game, seed, c.cfg.content)
		set_status(c, .Connected, "")
	}
}

@(private)
fin_have :: #force_inline proc(c: ^Client($S, $I, $W, $P), t: u32) -> bool {
	return c.fin_tick[t % FIN_RING] == t
}

// The base the finalized ring is anchored to: ticks beyond base + FIN_RING are not accepted yet.
@(private)
fin_base :: proc(c: ^Client($S, $I, $W, $P)) -> u32 {
	return c.sim != nil ? c.verified : c.snap_tick
}

@(private)
on_finalized :: proc(c: ^Client($S, $I, $W, $P), rd: ^wire.Reader, now: i64) {
	relay_time := r_i64(rd)
	echo := r_i64(rd)
	hold := r_i64(rd)
	input_ack := wire.r_u32(rd)
	cmd_ack := wire.r_u32(rd)
	first := wire.r_u32(rd)
	count := u32(wire.r_u8(rd))
	if !rd.ok || !c.welcomed {
		return
	}
	c.cmd_acked = max(c.cmd_acked, min(cmd_ack, c.cmd_seq))
	if echo > 0 {
		sample := f64(now - echo - hold)
		if sample > 0 {
			c.rtt_us = c.rtt_samples == 0 ? sample : c.rtt_us + (sample - c.rtt_us) * 0.1
			c.rtt_samples += 1
		}
	}
	if c.rtt_samples > 0 {
		off := f64(relay_time) + c.rtt_us / 2 - f64(now)
		c.offset_us = c.have_offset ? c.offset_us + (off - c.offset_us) * 0.05 : off
		c.have_offset = true
	}
	c.own_acked = max(c.own_acked, input_ack)
	limit := fin_base(c) + FIN_RING - 64
	lt := &c.fin_scratch
	for k in 0 ..< count {
		t := first + k
		if !usim.inputs_read(rd, lt) {
			break // malformed: the ticks after it can't be found
		}
		// Ticks at or below fin_upto are held or consumed already: a stale datagram must not
		// overwrite the ring slot a newer tick shares with them.
		if t <= c.fin_upto || t > limit || (c.ticks != 0 && t > c.ticks) || fin_have(c, t) {
			continue
		}
		c.fin[t % FIN_RING] = lt^
		c.fin_tick[t % FIN_RING] = t
	}
	for fin_have(c, c.fin_upto + 1) {
		c.fin_upto += 1
	}
}

@(private)
handle_client_msg :: proc(c: ^Client($S, $I, $W, $P), data: []u8, now: i64) {
	c.last_msg_us = now
	rd := wire.reader_make(data)
	#partial switch Msg(wire.r_u8(&rd)) {
	case .Welcome:
		on_welcome(c, &rd)
	case .Reject:
		detail := "rejected"
		switch Reject_Reason(wire.r_u8(&rd)) {
		case .Full:
			detail = "the session is full"
		case .Slot_Taken:
			detail = "that player slot is taken"
		case .Incompatible:
			detail = "a different game build or level"
		case .Not_Started:
			detail = "the session has not started"
		}
		set_status(c, .Failed, detail)
	case .Finalized:
		on_finalized(c, &rd, now)
	case .Snap_Request:
		req := Snap_Req{int(wire.r_u8(&rd)), wire.r_u32(&rd)}
		if rd.ok {
			append(&c.snap_reqs, req)
		}
	case .Snap_Begin:
		_ = wire.r_u8(&rd)
		tick := wire.r_u32(&rd)
		total := int(wire.r_u32(&rd))
		if !rd.ok || !c.welcomed || c.sim != nil {
			return
		}
		if total == 0 {
			// The provider left and nobody else can send one: start from tick 0 and replay the log.
			c.fin_tick = {}
			c.fin_upto = 0
			c.snap_tick = 0
			c.sim = usim.create(c.game, c.seed, c.cfg.content)
			set_status(c, .Connected, "")
			return
		}
		c.snap_tick = tick
		c.snap_total = total
		clear(&c.snap_buf)
		// Finalized ticks are streamed from the snapshot tick on.
		c.fin_upto = max(c.fin_upto, c.snap_tick - 1)
		for fin_have(c, c.fin_upto + 1) {
			c.fin_upto += 1
		}
	case .Snap_Chunk:
		_ = wire.r_u8(&rd)
		offset := int(wire.r_u32(&rd))
		bytes := rd.data[rd.pos:]
		if !rd.ok || c.sim != nil || offset != len(c.snap_buf) || len(bytes) > c.snap_total - offset {
			return
		}
		append(&c.snap_buf, ..bytes)
		if c.snap_total > 0 && len(c.snap_buf) == c.snap_total {
			load_snapshot(c)
		}
	case .Roster:
		if int(wire.r_u8(&rd)) == P {
			for p in 0 ..< P {
				conn := wire.r_u8(&rd) != 0
				name := r_name(&rd)
				if rd.ok {
					c.connected[p] = conn
					c.names[p] = name
				}
			}
		}
	case .End:
		if c.end_us == 0 {
			c.end_us = now
			c.detail = "session ended"
		}
	}
}

@(private)
load_snapshot :: proc(c: ^Client($S, $I, $W, $P)) {
	sim, err := usim.from_snapshot(c.game, c.snap_buf[:], c.cfg.content)
	if err != .None {
		set_status(c, .Failed, fmt.tprintf("received snapshot does not restore: %v", err))
		return
	}
	c.sim = sim
	c.verified = c.sim.tick
	c.predicted = c.verified
	c.own_last = max(c.own_last, c.verified)
	if !c.cfg.quiet {
		fmt.eprintfln("%s: restored snapshot of tick %d (%d bytes)", c.cfg.name, c.verified, len(c.snap_buf))
	}
	delete(c.snap_buf)
	c.snap_buf = nil
	set_status(c, .Connected, "")
}

// Inputs for predicting tick t: own input and commands, the others' latest finalized input repeated
// (their commands are unknown until finalized: none).
@(private)
predicted_inputs :: proc(c: ^Client($S, $I, $W, $P), t: u32, out: ^usim.Inputs(I, P)) {
	out^ = {}
	if c.fin_upto >= 1 && fin_have(c, c.fin_upto) {
		last := &c.fin[c.fin_upto % FIN_RING]
		out.present = last.present
		out.input = last.input
	}
	if t >= c.first_tick {
		out.present += {c.slot}
		out.input[c.slot] = c.own[min(t, c.own_last) % OWN_RING]
	}
	// Own commands where the relay will put them if they reach it in time: each in the tick it was sent
	// for, or the first tick not finalized yet when that one is (a late command moves on), in order, at
	// most COMMANDS_PER_PLAYER per tick. A wrong guess is an ordinary misprediction.
	at, in_tick: u32 = 0, 0
	for &oc in c.own_cmds {
		tk := max(oc.want, c.fin_upto + 1, at)
		if tk == at && in_tick == usim.COMMANDS_PER_PLAYER {
			tk += 1
		}
		if tk != at {
			at, in_tick = tk, 0
		}
		in_tick += 1
		if tk > t {
			break
		}
		if tk == t {
			usim.add_command(out, oc.cmd)
		}
	}
}

// A verified tick carries the own commands the relay put in it: they are no longer predicted.
@(private)
drop_verified_commands :: proc(c: ^Client($S, $I, $W, $P), t: u32) {
	n := len(usim.commands(&c.fin[t % FIN_RING], c.slot))
	remove_range(&c.own_cmds, 0, min(n, len(c.own_cmds)))
}

@(private)
record_checksum :: proc(c: ^Client($S, $I, $W, $P)) {
	t := c.sim.tick
	if t % CHECKSUM_EVERY == 0 {
		c.chk[(t / CHECKSUM_EVERY) % CHK_RING] = {t, usim.checksum(c.sim)}
	}
}

@(private)
step_tick :: proc(c: ^Client($S, $I, $W, $P), inputs: ^usim.Inputs(I, P), kind: Step_Kind) {
	t0 := time.tick_now()
	usim.step(c.sim, inputs)
	c.steps[kind] += 1
	c.step_us[kind] += i64(time.duration_microseconds(time.tick_since(t0)))
	record_checksum(c)
	if c.resim_from == 0 || c.sim.tick < c.resim_from {
		c.resim_from = c.sim.tick
	}
}

@(private)
on_tick_verified :: proc(c: ^Client($S, $I, $W, $P), t: u32) {
	if c.hooks.verified != nil {
		c.hooks.verified(c.hooks.user, c.sim, t, usim.events_at(c.sim, t))
	}
}

// Advances the verified frame with newly finalized ticks, rolling back on a misprediction.
@(private)
advance_verified :: proc(c: ^Client($S, $I, $W, $P), now: i64) {
	new_v := c.fin_upto
	if c.sim == nil || new_v <= c.verified {
		return
	}
	old_v := c.verified
	limit := min(new_v, c.predicted)
	m: u32 = 0
	for t in old_v + 1 ..= new_v {
		assert(c.fin_tick[t % FIN_RING] == t, "finalized ring slot holds another tick")
	}
	for t in old_v + 1 ..= limit {
		// Compared as bytes, like the checksum: -0.0 and +0.0 differ, a NaN equals itself.
		if !usim.inputs_same(&c.pred_inputs[t % PRED_RING], &c.fin[t % FIN_RING]) {
			m = t
			break
		}
	}
	for t in old_v + 1 ..= new_v {
		drop_verified_commands(c, t)
		if c.slot >= 0 && c.slot in c.fin[t % FIN_RING].replaced do c.own_replaced += 1
	}
	for t in old_v + 1 ..= (m != 0 ? m - 1 : limit) {
		on_tick_verified(c, t) // predicted right: the ring already holds the verified result
	}
	if m != 0 {
		if !usim.restore(c.sim, m - 1) {
			set_status(c, .Failed, "rollback failed: the target tick is not restorable")
			return
		}
		depth := int(c.predicted - (m - 1))
		c.rollbacks += 1
		c.depth_sum += depth
		c.depth_max = max(c.depth_max, depth)
		for t in m ..= new_v {
			step_tick(c, &c.fin[t % FIN_RING], .Resim)
			on_tick_verified(c, t)
			c.resim_ticks += 1
		}
		for t in new_v + 1 ..= c.predicted {
			in_ := &c.pred_inputs[t % PRED_RING]
			predicted_inputs(c, t, in_)
			step_tick(c, in_, .Resim)
			c.resim_ticks += 1
		}
		c.predicted = max(c.predicted, new_v)
	} else if new_v > c.predicted {
		for t in c.predicted + 1 ..= new_v {
			step_tick(c, &c.fin[t % FIN_RING], .Verified)
			on_tick_verified(c, t)
		}
		c.predicted = new_v
	}
	c.verified = new_v
	// Report the checksums of newly verified ticks (every 16th; a joiner from its join tick on).
	first := (old_v / CHECKSUM_EVERY + 1) * CHECKSUM_EVERY
	for t := first; t <= new_v; t += CHECKSUM_EVERY {
		e := c.chk[(t / CHECKSUM_EVERY) % CHK_RING]
		assert(e.tick == t, "missing checksum for a verified tick")
		if t < c.first_tick {
			continue
		}
		append(&c.checksums, [2]u64{u64(t), e.value})
		w := msg_begin(&c.w, .Checksum)
		wire.w_u8(w, u8(c.slot))
		wire.w_u32(w, t)
		wire.w_u64(w, e.value)
		csend(c, w, .Reliable, now)
	}
}

// Generates own inputs up to local + delay. A tick skipped because the delay grew repeats the
// last input; when the delay shrinks, the already-sent input for a tick is kept.
@(private)
generate_inputs :: proc(c: ^Client($S, $I, $W, $P)) {
	target := c.local + c.delay
	if c.ticks != 0 {
		target = min(target, c.ticks)
	}
	first_gen := c.own_last < c.first_tick
	for t := c.own_last + 1; t <= target; t += 1 {
		if t < target && !first_gen {
			c.own[t % OWN_RING] = c.own[(t - 1) % OWN_RING]
		} else if c.hooks.sample != nil {
			c.own[t % OWN_RING] = c.hooks.sample(c.hooks.user, c.slot, t, client_state(c))
		} else {
			c.own[t % OWN_RING] = {}
		}
		c.own_last = t
		if c.hooks.commands != nil {
			out := &c.cmd_out
			out.kinds = c.game.commands
			out.slot = c.slot
			out.cap = COMMAND_QUEUE - len(c.own_cmds)
			clear(&out.list)
			c.hooks.commands(c.hooks.user, c.slot, t, client_state(c), out)
			for cmd in out.list[:min(len(out.list), max(out.cap, 0))] {
				c.cmd_seq += 1
				append(&c.own_cmds, Own_Command{seq = c.cmd_seq, want = t, cmd = cmd})
			}
		}
	}
}

@(private)
send_inputs :: proc(c: ^Client($S, $I, $W, $P), now: i64) {
	w := msg_begin(&c.w, .Inputs)
	wire.w_u8(w, u8(c.slot))
	w_i64(w, now)
	wire.w_u32(w, min(c.fin_upto, fin_base(c) + FIN_RING - 64))
	first := max(c.own_acked + 1, c.first_tick)
	last := min(c.own_last, first + inputs_window(I) - 1)
	wire.w_u32(w, first)
	count := last >= first ? last - first + 1 : 0
	wire.w_u8(w, u8(count))
	for t in first ..< first + count {
		w_raw(w, &c.own[t % OWN_RING])
	}
	// Commands the relay hasn't acked, in seq order, as many as fit.
	k := 0
	for k < len(c.own_cmds) && c.own_cmds[k].seq <= c.cmd_acked {
		k += 1
	}
	wire.w_u32(w, k < len(c.own_cmds) ? c.own_cmds[k].seq : c.cmd_seq + 1)
	ncmd_at := len(w.buf)
	wire.w_u8(w, 0)
	n := 0
	for ; k < len(c.own_cmds) && n < 255; k += 1 {
		oc := &c.own_cmds[k]
		if len(w.buf) + COMMAND_SEND_HEAD + int(oc.cmd.size) > MAX_MESSAGE {
			break
		}
		wire.w_u32(w, oc.want)
		wire.w_u8(w, oc.cmd.kind)
		wire.w_u8(w, oc.cmd.size)
		wire.w_bytes(w, oc.cmd.data[:oc.cmd.size])
		n += 1
	}
	w.buf[ncmd_at] = u8(n)
	csend(c, w, .Unreliable, now)
	c.last_send_us = now
}

@(private)
at_end :: #force_inline proc(c: ^Client($S, $I, $W, $P), t: u32) -> bool {
	return c.ticks != 0 && t >= c.ticks
}

// Scheduler: advances the local tick at the tick rate ± 2% towards relay tick + delay.
@(private)
schedule :: proc(c: ^Client($S, $I, $W, $P), now: i64) -> (advanced: bool) {
	if !c.welcomed || !c.have_offset || c.rtt_samples < 3 {
		return
	}
	tick_us := c.tm.tick_us
	relay_tick := (f64(now) + c.offset_us) / tick_us
	if !c.started {
		c.started = true
		c.delay = want_delay(c.rtt_us, c.tm)
		c.delay_eval_us = now
		c.local = max(u32(max(relay_tick, 0)) + c.delay, c.verified)
		c.next_tick_us = f64(now) + tick_us
		generate_inputs(c)
		return true
	}
	if now - c.delay_eval_us >= 1_000_000 {
		c.delay_eval_us = now
		want := want_delay(c.rtt_us, c.tm)
		if want > c.delay {
			c.delay += 1
			c.delay_changes += 1
		} else if want < c.delay {
			c.delay -= 1
			c.delay_changes += 1
		}
	}
	cap := c.tm.prediction_cap
	err := relay_tick + f64(c.delay) - f64(c.local)
	period := tick_us
	if err > 1.0 {
		period *= 0.98
	} else if err < 0 {
		period *= 1.02
	}
	for f64(now) >= c.next_tick_us {
		c.next_tick_us += period
		if at_end(c, c.local) || err < -4 {
			continue // finished, or far ahead of the relay: hold
		}
		if c.sim != nil && c.local + 1 > c.verified + cap {
			c.stall_ticks += 1
			continue
		}
		c.local += 1
		err -= 1
		advanced = true
		generate_inputs(c)
	}
	// Far behind (e.g. after a stall): catch up without waiting for the slew.
	for err > 4 && !at_end(c, c.local) && (c.sim == nil || c.local + 1 <= c.verified + cap) {
		c.local += 1
		err -= 1
		advanced = true
		generate_inputs(c)
	}
	return
}

@(private)
predict :: proc(c: ^Client($S, $I, $W, $P)) {
	if c.sim == nil {
		return
	}
	for c.predicted < c.local && c.predicted < c.verified + c.tm.prediction_cap && !at_end(c, c.predicted) {
		t := c.predicted + 1
		in_ := &c.pred_inputs[t % PRED_RING]
		predicted_inputs(c, t, in_)
		step_tick(c, in_, .Predicted)
		c.predicted = t
	}
}

@(private)
serve_snapshot :: proc(c: ^Client($S, $I, $W, $P), now: i64) {
	if len(c.snap_reqs) == 0 || c.sim == nil {
		return
	}
	data: []u8
	defer delete(data)
	for i := 0; i < len(c.snap_reqs); {
		req := c.snap_reqs[i]
		if c.verified < req.min_tick {
			i += 1
			continue
		}
		if data == nil {
			data = usim.snapshot_encode(c.sim, c.verified)
		}
		w := msg_begin(&c.w, .Snap_Begin)
		wire.w_u8(w, u8(req.joiner))
		wire.w_u32(w, c.verified)
		wire.w_u32(w, u32(len(data)))
		csend(c, w, .Reliable, now)
		for off := 0; off < len(data); off += SNAP_CHUNK {
			cw := msg_begin(&c.w, .Snap_Chunk)
			wire.w_u8(cw, u8(req.joiner))
			wire.w_u32(cw, u32(off))
			wire.w_bytes(cw, data[off:min(off + SNAP_CHUNK, len(data))])
			csend(c, cw, .Reliable, now)
		}
		if !c.cfg.quiet {
			fmt.eprintfln(
				"%s: sent snapshot of tick %d (%d bytes) for player %d",
				c.cfg.name,
				c.verified,
				len(data),
				req.joiner,
			)
		}
		ordered_remove(&c.snap_reqs, i)
	}
}

// One step of the client: receive, verify (rolling back if needed), advance the local clock,
// predict, publish, send. Returns when it wants to run next (a now_us value).
client_step :: proc(c: ^Client($S, $I, $W, $P), now: i64) -> (wake_us: i64) {
	if c.status == .Failed || c.status == .Disconnected {
		return now + 100_000
	}
	if !c.hello_sent {
		w := msg_begin(&c.w, .Hello)
		wire.w_u16(w, PROTOCOL_VERSION)
		wire.w_u8(w, c.cfg.slot < 0 ? ANY_SLOT : u8(c.cfg.slot))
		wire.w_u32(w, c.cfg.join_tick)
		wire.w_u64(w, c.cfg.compat)
		name := name_of(c.cfg.player)
		w_name(w, &name)
		csend(c, w, .Reliable, now)
		c.hello_sent = true
		set_status(c, .Connecting, "")
	}
	for ev in channel_poll(c.ch, now) {
		switch ev.kind {
		case .Message:
			handle_client_msg(c, ev.data, now)
		case .Disconnected:
			if ev.peer == c.relay && c.end_us == 0 {
				set_status(
					c,
					c.welcomed ? .Disconnected : .Failed,
					c.welcomed ? "connection lost" : "no answer from the relay",
				)
			}
		case .Connected:
		}
	}
	if c.status == .Failed || c.status == .Disconnected {
		return now + 100_000
	}
	c.resim_from = 0
	if !c.leaving {
		advance_verified(c, now)
		advanced := schedule(c, now)
		predict(c)
		if c.resim_from != 0 && c.hooks.frame != nil {
			c.hooks.frame(c.hooks.user, c.sim, Frame_Info{c.predicted, c.verified, c.resim_from})
		}
		serve_snapshot(c, now)
		if c.welcomed && (advanced || f64(now - c.last_send_us) >= c.tm.tick_us) {
			send_inputs(c, now)
		}
		if c.welcomed && c.ticks != 0 && c.verified >= c.ticks && !c.done_sent {
			w := msg_begin(&c.w, .Done)
			wire.w_u8(w, u8(c.slot))
			wire.w_u32(w, c.verified)
			csend(c, w, .Reliable, now)
			c.done_sent = true
		}
	}
	channel_flush(c.ch, now)
	if c.end_us != 0 {
		// Linger briefly so the last acks (End) or our Leave go out, then leave once our reliable
		// queue is empty.
		if (channel_idle(c.ch, c.relay) && now - c.end_us > 100_000) || now - c.end_us > 2_000_000 {
			set_status(c, .Disconnected, c.detail)
		}
	}
	wake_us = now + c.cfg.poll_us
	if c.started {
		wake_us = min(wake_us, i64(c.next_tick_us) + 1)
	}
	return
}

// What a client reports about its session: the headless CLI's client object (src/headless/SPEC.md,
// CLI conventions), the Godot host's result line, and the end-to-end scenarios' checks.
Client_Result :: struct {
	player:             int,
	join_tick:          u32, // the first tick the player is present
	final_tick:         u32, // the last verified tick (= the session's ticks on success)
	checksums:          [][2]u64, // (tick, checksum) of every verified tick divisible by 16, from join_tick on
	rollbacks:          int,
	rollback_depth_avg: f64,
	rollback_depth_max: int,
	stall_ticks:        int,
	resim_ticks:        int,
	delay:              u32,
	delay_changes:      int,
	rtt_ms:             f64,
	ok:                 bool, // verified every tick of the session and did not fail
	net:                Channel_Stats,
}

// A client's results; the checksums are copied into `allocator` (the caller deletes them).
client_result :: proc(c: ^Client($S, $I, $W, $P), allocator := context.allocator) -> Client_Result {
	checksums := make([][2]u64, len(c.checksums), allocator)
	copy(checksums, c.checksums[:])
	return {
		player = c.slot,
		join_tick = c.first_tick,
		final_tick = c.verified,
		checksums = checksums,
		rollbacks = c.rollbacks,
		rollback_depth_avg = c.rollbacks > 0 ? f64(c.depth_sum) / f64(c.rollbacks) : 0,
		rollback_depth_max = c.depth_max,
		stall_ticks = c.stall_ticks,
		resim_ticks = c.resim_ticks,
		delay = c.delay,
		delay_changes = c.delay_changes,
		rtt_ms = c.rtt_us / 1000,
		ok = c.ticks != 0 && c.verified == c.ticks && c.status != .Failed,
		net = c.ch.stats,
	}
}

// The JSON object of a client's results (temp-allocated).
client_json :: proc(r: Client_Result) -> string {
	b := make([dynamic]u8, 0, 64 + len(r.checksums) * 32, context.temp_allocator)
	for e, i in r.checksums {
		if i > 0 {
			append(&b, ',')
		}
		append(&b, ..transmute([]u8)fmt.tprintf(`[%d,"%016x"]`, e[0], e[1]))
	}
	return fmt.tprintf(
		`{{"player":%d,"final_tick":%d,"checksums":[%s],"rollbacks":%d,"rollback_depth_avg":%.2f,"rollback_depth_max":%d,"stall_ticks":%d,"resim_ticks":%d,"join_tick":%d,"delay":%d,"delay_changes":%d,"rtt_ms":%.1f,"ok":%v,"net":%s}}`,
		r.player,
		r.final_tick,
		string(b[:]),
		r.rollbacks,
		r.rollback_depth_avg,
		r.rollback_depth_max,
		r.stall_ticks,
		r.resim_ticks,
		r.join_tick,
		r.delay,
		r.delay_changes,
		r.rtt_ms,
		r.ok,
		channel_stats_json(r.net),
	)
}
