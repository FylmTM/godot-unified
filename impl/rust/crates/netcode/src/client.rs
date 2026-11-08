//! The client (spec/CORE.md §2), generic over any [`Simulation`].
//!
//! - **Verified frame** V: advanced only with finalized inputs.
//! - **Predicted frame** L: V plus the local player's own inputs plus predicted remote inputs (the
//!   last finalized input repeated). Every simulated tick is saved in the 16-slot ring.
//! - **New finalized inputs**: compare them with the inputs each predicted tick used; if all match,
//!   V just moves (no restore). Otherwise restore the last correct tick (M - 1 >= V), re-simulate
//!   to L with finalized inputs where known and re-predicted ones beyond.
//! - **Prediction cap**: L - V <= 10; past that the client stalls (doesn't advance L).
//! - **Input delay**: input is sent for L + delay, `delay = clamp(ceil((rtt/2 + 8) / 16.667), 1, 6)`,
//!   re-evaluated every second, +-1 per step. Growing repeats the last input for the skipped tick;
//!   shrinking re-sends a tick and both sides keep the first input for it.
//! - **Time sync**: the relay tick is estimated from relay timestamps plus RTT/2; the local tick
//!   scheduler runs 2 % faster or slower to keep L ~ relay tick + delay (large errors: catch up
//!   immediately / hold). Scheduling only, never the sim.
//! - **Late join**: wait for the relay's chosen snapshot (block + physics, portable bytes), import
//!   it, then fast-forward (the scheduler runs ticks back to back while far behind the target).
//! - **Desync detection**: (tick, checksum) of every 16th verified tick goes to the relay.

use crate::proto::{CHUNK, MAX_INPUTS, Msg};
use crate::transport::{Delivery, Event, PeerId, Transport};
use crate::{LOOP_SLEEP, TICK_US};
use simcore::json::Json;
use simcore::trace::hex;
use simcore::{Input, InputSet, InputSource, MAX_PLAYERS, Simulation, SnapshotRing};
use std::collections::HashMap;
use std::time::{Duration, Instant};

#[derive(Clone, Debug)]
pub struct ClientConfig {
    pub player: u8,
    /// 0 for an initial player; otherwise request a late join at this tick.
    pub join_tick: u32,
    pub max_prediction: u32,
    /// Give up after this long without hearing from the relay.
    pub idle_timeout: Duration,
}

impl ClientConfig {
    pub fn new(player: u8) -> ClientConfig {
        ClientConfig { player, join_tick: 0, max_prediction: 10, idle_timeout: Duration::from_secs(30) }
    }
}

#[derive(Debug, Default)]
pub struct ClientReport {
    pub player: u8,
    pub final_tick: u32,
    pub checksums: Vec<(u32, u64)>,
    pub rollbacks: u64,
    pub depth_sum: u64,
    pub depth_max: u32,
    pub stall_ticks: u64,
    pub predicted_ticks: u64,
    pub resimulated_ticks: u64,
    pub delay: u32,
    pub rtt_ms: f64,
    pub join_tick: Option<u32>,
    pub snapshot_tick: Option<u32>,
    pub snapshot_bytes: usize,
}

impl ClientReport {
    pub fn json(&self) -> Json {
        let avg = if self.rollbacks > 0 { self.depth_sum as f64 / self.rollbacks as f64 } else { 0.0 };
        let cs = self.checksums.iter().map(|&(t, h)| Json::Arr(vec![Json::from(t), Json::from(hex(h))])).collect();
        let mut j = Json::obj()
            .with("player", self.player)
            .with("final_tick", self.final_tick)
            .with("rollbacks", self.rollbacks)
            .with("rollback_depth_avg", avg)
            .with("rollback_depth_max", self.depth_max)
            .with("stall_ticks", self.stall_ticks)
            .with("predicted_ticks", self.predicted_ticks)
            .with("resimulated_ticks", self.resimulated_ticks)
            .with("input_delay", self.delay)
            .with("rtt_ms", self.rtt_ms)
            .with("desyncs", 0u32);
        if let Some(jt) = self.join_tick {
            j = j
                .with("join_tick", jt)
                .with("snapshot_tick", self.snapshot_tick.unwrap_or(0))
                .with("snapshot_bytes", self.snapshot_bytes);
        }
        j.with("checksums", Json::Arr(cs))
    }
}

fn delay_for(rtt_ms: f64) -> u32 {
    (((rtt_ms / 2.0 + 8.0) / 16.667).ceil() as i64).clamp(1, 6) as u32
}

struct Core<S: Simulation> {
    sim: S,
    ring: SnapshotRing<S>,
    own: usize,
    n: u32,
    /// finalized[t]: the official inputs of tick t (index 0 / the snapshot tick: the base).
    finalized: Vec<Option<InputSet>>,
    used: Vec<InputSet>,
    local: Vec<Option<Input>>,
    f: u32,
    v: u32,
    l: u32,
    first_own: u32,
    last_sent: u32,
    last_input: Input,
    pending_cs: HashMap<u32, u64>,
    rep: ClientReport,
}

impl<S: Simulation> Core<S> {
    fn predict(&self, tick: u32) -> InputSet {
        let base = self.finalized[self.f as usize].expect("finalized base");
        let mut set = base;
        set[self.own] = self.local[tick as usize].unwrap_or(base[self.own]);
        set
    }

    fn step(&mut self, tick: u32, set: InputSet) {
        debug_assert_eq!(self.sim.tick() + 1, tick);
        self.sim.step(&set);
        self.used[tick as usize] = set;
        self.ring.save(&mut self.sim);
        if tick.is_multiple_of(16) {
            self.pending_cs.insert(tick, self.sim.checksum());
        }
    }

    /// Consume newly finalized ticks: verify, roll back if a prediction was wrong, catch up.
    /// Returns the newly verified checksum ticks.
    fn process_finalized(&mut self) -> Vec<(u32, u64)> {
        while self.f < self.n && self.finalized[self.f as usize + 1].is_some() {
            self.f += 1;
        }
        if self.f.min(self.l) <= self.v {
            return Vec::new();
        }
        let upto = self.f.min(self.l);
        let bad = (self.v + 1..=upto).find(|&t| Some(self.used[t as usize]) != self.finalized[t as usize]);
        if let Some(m) = bad {
            self.ring.restore(&mut self.sim, m - 1);
            for t in m..=self.l {
                let set = if t <= self.f { self.finalized[t as usize].unwrap() } else { self.predict(t) };
                self.step(t, set);
                self.rep.resimulated_ticks += 1;
            }
            let depth = self.l - m + 1;
            self.rep.rollbacks += 1;
            self.rep.depth_sum += depth as u64;
            self.rep.depth_max = self.rep.depth_max.max(depth);
        }
        // Finalized ticks beyond L are not simulated here: the scheduler reaches them (using the
        // finalized inputs directly), so L stays tied to time sync and own inputs keep flowing.
        let old = self.v;
        self.v = self.f.min(self.l);
        let mut out = Vec::new();
        for t in (old + 1)..=self.v {
            if t % 16 == 0 {
                let h = self.pending_cs.remove(&t).expect("checksum of a verified tick");
                out.push((t, h));
            }
        }
        self.pending_cs.retain(|&t, _| t > self.v);
        out
    }

    /// Advance the predicted frame by one tick, generating and recording the own input first.
    fn advance(&mut self, delay: u32, source: &mut impl InputSource<S>) {
        let l = self.l + 1;
        let target = (l + delay).min(self.n);
        if target > self.last_sent && target >= self.first_own {
            let from = (self.last_sent + 1).max(self.first_own);
            for t in from..target {
                self.local[t as usize].get_or_insert(self.last_input);
            }
            let inp = source.input(&self.sim, self.own, target);
            self.local[target as usize].get_or_insert(inp);
            self.last_input = inp;
            self.last_sent = target;
        }
        let set = if l <= self.f { self.finalized[l as usize].unwrap() } else { self.predict(l) };
        self.step(l, set);
        self.l = l;
        self.rep.predicted_ticks += 1;
    }
}

/// Runs one client until its verified frame reaches the session's last tick.
pub fn run<S: Simulation, I: InputSource<S>>(
    t: &mut dyn Transport,
    relay: PeerId,
    cfg: &ClientConfig,
    make_sim: impl FnOnce(u64, u8) -> S,
    mut source: I,
) -> Result<ClientReport, String> {
    let epoch = Instant::now();
    let now_us = || epoch.elapsed().as_micros() as u64 + 1;
    let send = |t: &mut dyn Transport, m: &Msg, d: Delivery| t.send(relay, &m.encode(), d);
    send(t, &Msg::Hello { player: cfg.player, join_tick: cfg.join_tick }, Delivery::Reliable);

    let mut events = Vec::new();
    let mut last_heard = Instant::now();
    // --- handshake ---
    let (seed, initial_mask, active_from, n) = loop {
        events.clear();
        t.poll(&mut events);
        let mut welcome = None;
        for ev in events.drain(..) {
            if let Event::Message(_, b) = ev {
                last_heard = Instant::now();
                if let Some(Msg::Welcome { seed, initial_mask, active_from, ticks, .. }) = Msg::decode(&b) {
                    welcome = Some((seed, initial_mask, active_from, ticks));
                }
            }
        }
        if let Some(w) = welcome {
            break w;
        }
        if last_heard.elapsed() > cfg.idle_timeout.max(Duration::from_secs(60)) {
            return Err("client: no welcome from the relay".into());
        }
        std::thread::sleep(LOOP_SLEEP);
    };

    let own = cfg.player as usize;
    let mut sim = make_sim(seed, initial_mask);
    let ring = SnapshotRing::new(&mut sim);
    let mut base = [Input::ABSENT; MAX_PLAYERS];
    for (p, b) in base.iter_mut().enumerate() {
        if initial_mask & (1 << p) != 0 {
            *b = Input::NEUTRAL;
        }
    }
    let size = n as usize + 2;
    let mut c = Core {
        sim,
        ring,
        own,
        n,
        finalized: vec![None; size],
        used: vec![base; size],
        local: vec![None; size],
        f: 0,
        v: 0,
        l: 0,
        first_own: active_from,
        last_sent: active_from.saturating_sub(1),
        last_input: Input::NEUTRAL,
        pending_cs: HashMap::new(),
        rep: ClientReport { player: cfg.player, ..Default::default() },
    };
    let joiner = initial_mask & (1 << own) == 0;
    let mut ready = !joiner;
    if ready {
        c.ring.save(&mut c.sim);
        c.finalized[0] = Some(base);
    } else {
        c.rep.join_tick = Some(active_from);
    }

    let mut snap: Option<(u32, InputSet, Vec<u8>, usize)> = None;
    let mut snap_request: Option<(u8, u32)> = None;
    let mut relay_input_ack = 0u32;
    let mut rtt_ms: Option<f64> = None;
    let mut offset_us: Option<f64> = None;
    let mut delay = 1u32;
    let mut last_delay_eval = Instant::now();
    let mut next_tick_at = 0f64;
    let mut last_inputs_sent = Instant::now() - Duration::from_secs(1);
    let tick_dur = Duration::from_secs_f64(TICK_US / 1e6);

    while !(ready && c.v >= n) {
        events.clear();
        t.poll(&mut events);
        let mut changed = false;
        for ev in events.drain(..) {
            let Event::Message(_, bytes) = ev else { continue };
            let Some(msg) = Msg::decode(&bytes) else { continue };
            last_heard = Instant::now();
            match msg {
                Msg::Frames { relay_us, echo_us, hold_us, input_ack, first, sets } => {
                    let now = now_us();
                    if echo_us > 0 && now > echo_us + hold_us as u64 {
                        let sample = (now - echo_us - hold_us as u64) as f64 / 1000.0;
                        let r = rtt_ms.map_or(sample, |r| r * 0.9 + sample * 0.1);
                        if rtt_ms.is_none() {
                            delay = delay_for(r);
                        }
                        rtt_ms = Some(r);
                        let o = relay_us as f64 + r * 500.0 - now as f64;
                        offset_us = Some(offset_us.map_or(o, |x| x * 0.95 + o * 0.05));
                    }
                    relay_input_ack = relay_input_ack.max(input_ack);
                    for (k, (set, _)) in sets.into_iter().enumerate() {
                        let tick = (first + k as u32) as usize;
                        if tick >= 1 && tick <= n as usize && c.finalized[tick].is_none() {
                            c.finalized[tick] = Some(set);
                            changed = true;
                        }
                    }
                }
                Msg::SnapshotRequest { joiner, min_tick } => snap_request = Some((joiner, min_tick)),
                Msg::SnapshotBegin { tick, total, inputs, .. } if !ready => {
                    snap = Some((tick, inputs, vec![0; total as usize], 0));
                }
                Msg::SnapshotChunk { offset, data, .. } if !ready => {
                    if let Some((_, _, buf, got)) = snap.as_mut() {
                        let o = offset as usize;
                        if o + data.len() <= buf.len() {
                            buf[o..o + data.len()].copy_from_slice(&data);
                            *got += data.len();
                        }
                    }
                }
                _ => {}
            }
        }

        // Late join: restore the snapshot, then fast-forward.
        if !ready
            && let Some((tick, inputs, buf, got)) = &snap
            && *got == buf.len()
        {
            c.sim.import(buf).map_err(|e| format!("client {own}: snapshot import failed: {e}"))?;
            if c.sim.tick() != *tick {
                return Err(format!("client {own}: snapshot is tick {}, expected {tick}", c.sim.tick()));
            }
            c.ring.save(&mut c.sim);
            c.finalized[*tick as usize] = Some(*inputs);
            c.f = *tick;
            c.v = *tick;
            c.l = *tick;
            c.last_sent = c.last_sent.max(*tick);
            c.rep.snapshot_tick = Some(*tick);
            c.rep.snapshot_bytes = buf.len();
            ready = true;
            changed = true;
            eprintln!("client {own}: restored snapshot of tick {tick} ({} bytes)", buf.len());
        }

        if ready && changed {
            for (tick, hash) in c.process_finalized() {
                c.rep.checksums.push((tick, hash));
                send(t, &Msg::Checksum { tick, hash }, Delivery::Reliable);
            }
        }

        // Serve a snapshot for a late joiner once our verified frame is far enough.
        if let Some((joiner, min_tick)) = snap_request
            && ready
            && c.v >= min_tick
        {
            let slot = c.ring.get(c.v).expect("verified slot in ring");
            let bytes = S::export_slot(slot);
            let inputs = c.finalized[c.v as usize].unwrap();
            send(t, &Msg::SnapshotBegin { joiner, tick: c.v, total: bytes.len() as u32, inputs }, Delivery::Reliable);
            for (k, chunk) in bytes.chunks(CHUNK).enumerate() {
                let m = Msg::SnapshotChunk { joiner, offset: (k * CHUNK) as u32, data: chunk.to_vec() };
                send(t, &m, Delivery::Reliable);
            }
            eprintln!("client {own}: sent snapshot of tick {} ({} bytes) for player {joiner}", c.v, bytes.len());
            snap_request = None;
        }

        // Tick scheduler.
        let mut advanced = false;
        if ready
            && c.v < n
            && let Some(off) = offset_us
        {
            let now = now_us() as f64;
            if next_tick_at == 0.0 {
                next_tick_at = now;
            }
            let target = (now + off) / TICK_US + delay as f64;
            for _ in 0..4 {
                if c.l >= n {
                    break;
                }
                let err = c.l as f64 - target;
                let due = now >= next_tick_at;
                if !due && err >= -3.0 {
                    break;
                }
                if err > 3.0 {
                    next_tick_at = now + TICK_US;
                    break;
                }
                if c.l - c.v >= cfg.max_prediction {
                    if due {
                        c.rep.stall_ticks += 1;
                        next_tick_at = now + TICK_US;
                    }
                    break;
                }
                c.advance(delay, &mut source);
                advanced = true;
                let rate = if err > 0.5 {
                    1.02
                } else if err < -0.5 {
                    0.98
                } else {
                    1.0
                };
                next_tick_at = next_tick_at.max(now - 2.0 * TICK_US) + TICK_US * rate;
            }
        }

        if advanced {
            for (tick, hash) in c.process_finalized() {
                c.rep.checksums.push((tick, hash));
                send(t, &Msg::Checksum { tick, hash }, Delivery::Reliable);
            }
        }

        // Inputs (+ ack and timestamp) to the relay.
        if advanced || last_inputs_sent.elapsed() >= tick_dur {
            let from = (relay_input_ack.max(c.f) + 1).max(c.first_own);
            let to = c.last_sent.min(from + MAX_INPUTS as u32 - 1);
            let inputs: Vec<Input> = if ready && from <= to {
                (from..=to).map(|t| c.local[t as usize].unwrap_or(Input::NEUTRAL)).collect()
            } else {
                Vec::new()
            };
            send(t, &Msg::Inputs { client_us: now_us(), ack: c.f, first: from, inputs }, Delivery::Unreliable);
            last_inputs_sent = Instant::now();
        }

        if let Some(r) = rtt_ms
            && last_delay_eval.elapsed() >= Duration::from_secs(1)
        {
            last_delay_eval = Instant::now();
            let want = delay_for(r);
            if want > delay {
                delay += 1;
            } else if want < delay {
                delay -= 1;
            }
        }
        if last_heard.elapsed() > cfg.idle_timeout {
            return Err(format!(
                "client {own}: relay silent for {:?} (verified {}, local {})",
                cfg.idle_timeout, c.v, c.l
            ));
        }
        if !changed && !advanced {
            std::thread::sleep(LOOP_SLEEP);
        }
    }

    // Done: say bye and let the reliable lane drain (checksums, bye).
    send(t, &Msg::Bye, Delivery::Reliable);
    let flush_start = Instant::now();
    while t.reliable_pending(relay) > 0 && flush_start.elapsed() < Duration::from_secs(3) {
        events.clear();
        t.poll(&mut events);
        std::thread::sleep(LOOP_SLEEP);
    }
    c.rep.final_tick = c.v;
    c.rep.delay = delay;
    c.rep.rtt_ms = rtt_ms.unwrap_or(0.0);
    Ok(c.rep)
}
