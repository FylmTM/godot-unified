//! The relay (spec/CORE.md §2): owns the 60 Hz tick clock, collects inputs stamped with their
//! target tick, finalizes tick T once every active player's input for T is in or the clock reaches
//! T + tolerance (a missing input becomes that player's last finalized input, flagged replaced),
//! broadcasts finalized sets over the unreliable lane (every unacknowledged tick, up to 32 per
//! packet), keeps the official input log, compares clients' checksums, and brokers late joins.
//! No game logic. Runs on its own thread (session) or as its own process (`unified relay`).

use crate::proto::{MAX_FRAMES, Msg};
use crate::transport::{Delivery, Event, PeerId, Transport};
use crate::{LOOP_SLEEP, TICK_US};
use simcore::json::Json;
use simcore::log::InputLog;
use simcore::{ABSENT, Input, InputSet, MAX_PLAYERS};
use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

#[derive(Clone, Debug)]
pub struct RelayConfig {
    pub slots: u8,
    /// Players that must connect before the clock starts (active from tick 1).
    pub initial_mask: u8,
    pub ticks: u32,
    pub seed: u64,
    /// Hard tolerance in ticks.
    pub tolerance: u32,
    /// Give up if the initial players haven't all connected by then.
    pub start_timeout: Duration,
}

#[derive(Debug, Default)]
pub struct RelayReport {
    pub desyncs: u32,
    pub desync_ticks: Vec<u32>,
    pub finalized: u32,
    pub replaced_inputs: u64,
    pub join_tick: Option<u32>,
    pub snapshot_tick: Option<u32>,
    pub snapshot_bytes: u32,
    pub log: InputLog,
}

impl RelayReport {
    pub fn json(&self) -> Json {
        let mut j = Json::obj()
            .with("desyncs", self.desyncs)
            .with("desync_ticks", Json::Arr(self.desync_ticks.iter().map(|&t| Json::from(t)).collect()))
            .with("finalized", self.finalized)
            .with("replaced_inputs", self.replaced_inputs);
        if let Some(j0) = self.join_tick {
            j = j
                .with("join_tick", j0)
                .with("snapshot_tick", self.snapshot_tick.unwrap_or(0))
                .with("snapshot_bytes", self.snapshot_bytes);
        }
        j
    }
}

struct Slot {
    peer: Option<PeerId>,
    active_from: u32,
    left_at: u32,
    inputs: Vec<Option<Input>>,
    last_final: Input,
    last_client_us: u64,
    last_client_at: Option<Instant>,
    /// Highest contiguous finalized tick the client confirmed; `None`: don't send frames yet
    /// (a late joiner before its snapshot is on the way).
    ack: Option<u32>,
    last_frames_at: Option<Instant>,
    sent_upto: u32,
    bye: bool,
}

pub fn run(t: &mut dyn Transport, cfg: &RelayConfig, progress: Option<&AtomicU32>) -> Result<RelayReport, String> {
    let n = cfg.ticks as usize;
    let slots = cfg.slots.min(MAX_PLAYERS as u8) as usize;
    let mut sl: Vec<Slot> = (0..slots)
        .map(|p| Slot {
            peer: None,
            active_from: if cfg.initial_mask & (1 << p) != 0 { 1 } else { u32::MAX },
            left_at: u32::MAX,
            inputs: vec![None; n + 2],
            last_final: if cfg.initial_mask & (1 << p) != 0 { Input::NEUTRAL } else { Input::ABSENT },
            last_client_us: 0,
            last_client_at: None,
            ack: None,
            last_frames_at: None,
            sent_upto: 0,
            bye: false,
        })
        .collect();
    let mut by_peer: HashMap<PeerId, usize> = HashMap::new();
    let mut rep = RelayReport { log: InputLog::new(cfg.seed, cfg.slots), ..Default::default() };
    let mut finalized: Vec<(InputSet, u8)> = Vec::with_capacity(n);
    let mut checks: BTreeMap<u32, [Option<u64>; MAX_PLAYERS]> = BTreeMap::new();
    let mut join: Option<(usize, usize)> = None; // (joiner, provider)
    let created = Instant::now();
    let mut start: Option<Instant> = None;
    let mut done_at: Option<Instant> = None;
    let mut all_bye_at: Option<Instant> = None;
    let mut events = Vec::new();
    let tick_dur = Duration::from_secs_f64(TICK_US / 1e6);

    loop {
        let now = Instant::now();
        let rel_tick = start.map_or(0, |s| (now.duration_since(s).as_secs_f64() * 1e6 / TICK_US) as u32);
        let f = finalized.len() as u32;
        events.clear();
        t.poll(&mut events);
        for ev in events.drain(..) {
            match ev {
                Event::Connected(_) => {}
                Event::Disconnected(peer) => {
                    if let Some(p) = by_peer.remove(&peer) {
                        sl[p].peer = None;
                        if sl[p].active_from != u32::MAX && sl[p].left_at == u32::MAX && !sl[p].bye {
                            sl[p].left_at = f + 1;
                            eprintln!("relay: player {p} disconnected; absent from tick {}", f + 1);
                        }
                    }
                }
                Event::Message(peer, bytes) => {
                    let Some(msg) = Msg::decode(&bytes) else { continue };
                    if let Msg::Hello { player, join_tick } = msg {
                        let p = player as usize;
                        if p >= slots || sl[p].peer.is_some_and(|q| q != peer) {
                            eprintln!("relay: rejected hello for player {p}");
                            continue;
                        }
                        sl[p].peer = Some(peer);
                        by_peer.insert(peer, p);
                        if let Some(st) = start
                            && (sl[p].active_from == u32::MAX || join_tick > 0)
                        {
                            // Late join: first active at a future tick J.
                            let r = (now.duration_since(st).as_secs_f64() * 1e6 / TICK_US) as u32;
                            let j = join_tick.max(r + 10).max(f + 10).min(cfg.ticks);
                            sl[p].active_from = j;
                            sl[p].left_at = u32::MAX;
                            sl[p].ack = None;
                            rep.join_tick = Some(j);
                            send(t, peer, &welcome(cfg, p, j), Delivery::Reliable);
                            let provider =
                                (0..slots).find(|&q| q != p && sl[q].peer.is_some() && sl[q].active_from <= r);
                            if let Some(q) = provider {
                                join = Some((p, q));
                                let m = Msg::SnapshotRequest { joiner: p as u8, min_tick: j - 1 };
                                send(t, sl[q].peer.unwrap(), &m, Delivery::Reliable);
                                eprintln!("relay: player {p} joins at tick {j}; snapshot from player {q}");
                            } else {
                                eprintln!("relay: player {p} joins at tick {j} but no client can provide a snapshot");
                            }
                        }
                        continue;
                    }
                    let Some(&p) = by_peer.get(&peer) else { continue };
                    match msg {
                        Msg::Inputs { client_us, ack, first, inputs } => {
                            let s = &mut sl[p];
                            s.last_client_us = s.last_client_us.max(client_us);
                            s.last_client_at = Some(now);
                            if let Some(a) = s.ack.as_mut() {
                                *a = (*a).max(ack.min(f));
                            }
                            for (k, inp) in inputs.iter().enumerate() {
                                let tick = first + k as u32;
                                if tick > f && tick <= cfg.ticks && tick >= s.active_from && tick < s.left_at {
                                    // Keep the first input for a tick (delay shrinks re-send it).
                                    s.inputs[tick as usize].get_or_insert(*inp);
                                }
                            }
                        }
                        Msg::Checksum { tick, hash } => {
                            let e = checks.entry(tick).or_insert([None; MAX_PLAYERS]);
                            e[p] = Some(hash);
                            let mut seen = e.iter().flatten();
                            let first_hash = *seen.next().unwrap();
                            if seen.any(|&h| h != first_hash) && !rep.desync_ticks.contains(&tick) {
                                rep.desyncs += 1;
                                rep.desync_ticks.push(tick);
                                let who: Vec<String> = e
                                    .iter()
                                    .enumerate()
                                    .filter_map(|(q, h)| h.map(|h| format!("p{q}={h:016x}")))
                                    .collect();
                                eprintln!("relay: DESYNC at tick {tick}: {}", who.join(" "));
                            }
                        }
                        Msg::SnapshotBegin { joiner, tick, total, .. } => {
                            if let Some((j, q)) = join
                                && q == p
                                && j == joiner as usize
                            {
                                sl[j].ack = Some(tick);
                                rep.snapshot_tick = Some(tick);
                                rep.snapshot_bytes = total;
                                if let Some(jp) = sl[j].peer {
                                    t.send(jp, &bytes, Delivery::Reliable);
                                }
                            }
                        }
                        Msg::SnapshotChunk { joiner, .. } => {
                            if let Some((j, q)) = join
                                && q == p
                                && j == joiner as usize
                                && let Some(jp) = sl[j].peer
                            {
                                t.send(jp, &bytes, Delivery::Reliable);
                            }
                        }
                        Msg::Bye => sl[p].bye = true,
                        _ => {}
                    }
                }
            }
        }

        // Start the clock once every initial player is connected.
        if start.is_none() {
            if (0..slots).all(|p| cfg.initial_mask & (1 << p) == 0 || sl[p].peer.is_some()) {
                start = Some(now);
                for (p, s) in sl.iter_mut().enumerate() {
                    if let Some(peer) = s.peer {
                        s.ack = Some(0);
                        send(t, peer, &welcome(cfg, p, 1), Delivery::Reliable);
                    }
                }
                eprintln!("relay: all {} initial players connected; clock started", cfg.initial_mask.count_ones());
            } else if now.duration_since(created) > cfg.start_timeout {
                return Err("relay: timed out waiting for the initial players".into());
            }
            std::thread::sleep(LOOP_SLEEP);
            continue;
        }
        let st = start.unwrap();
        let rel_tick = rel_tick.max((now.duration_since(st).as_secs_f64() * 1e6 / TICK_US) as u32);
        if let Some(pr) = progress {
            pr.store(rel_tick, Ordering::Relaxed);
        }

        // Finalize in order: all active inputs present, or the hard tolerance expired.
        while (finalized.len() as u32) < cfg.ticks {
            let tick = finalized.len() as u32 + 1;
            let active = |s: &Slot| s.active_from <= tick && tick < s.left_at;
            let ready = sl.iter().all(|s| !active(s) || s.inputs[tick as usize].is_some());
            if !ready && rel_tick < tick + cfg.tolerance {
                break;
            }
            let mut set = [Input::ABSENT; MAX_PLAYERS];
            let mut replaced = 0u8;
            for (p, s) in sl.iter_mut().enumerate() {
                let inp = if !active(s) {
                    Input::ABSENT
                } else if let Some(i) = s.inputs[tick as usize] {
                    i
                } else {
                    replaced |= 1 << p;
                    rep.replaced_inputs += 1;
                    Input { buttons: s.last_final.buttons & !ABSENT, ..s.last_final }
                };
                s.last_final = inp;
                set[p] = inp;
            }
            finalized.push((set, replaced));
            rep.log.push(set, replaced);
        }
        let f = finalized.len() as u32;
        if f == cfg.ticks && done_at.is_none() {
            done_at = Some(now);
        }

        // Frames: every unacknowledged finalized tick (up to 32) when something new is finalized,
        // and at least once per tick (time sync, resends).
        let relay_us = now.duration_since(st).as_micros() as u64;
        for s in sl.iter_mut() {
            let (Some(peer), Some(ack)) = (s.peer, s.ack) else {
                // A joiner waiting for its snapshot still gets time stamps.
                if let (Some(peer), None) = (s.peer, s.ack)
                    && s.last_frames_at.is_none_or(|l| now.duration_since(l) >= tick_dur)
                {
                    s.last_frames_at = Some(now);
                    let m = frames(s, now, relay_us, f, 0, &[]);
                    send(t, peer, &m, Delivery::Unreliable);
                }
                continue;
            };
            let fresh = f > s.sent_upto;
            if !fresh && s.last_frames_at.is_some_and(|l| now.duration_since(l) < tick_dur) {
                continue;
            }
            let first = ack + 1;
            let last = f.min(ack + MAX_FRAMES as u32);
            let sets = if first <= last { &finalized[(first - 1) as usize..last as usize] } else { &[][..] };
            let m = frames(s, now, relay_us, f, first, sets);
            send(t, peer, &m, Delivery::Unreliable);
            s.last_frames_at = Some(now);
            s.sent_upto = f;
        }

        // Done: every connected player said bye after verifying the last tick (or 15 s passed).
        if let Some(d) = done_at {
            let all_bye = sl.iter().all(|s| s.peer.is_none() || s.bye);
            if all_bye && all_bye_at.is_none() {
                all_bye_at = Some(now);
            }
            if all_bye_at.is_some_and(|a| now.duration_since(a) > Duration::from_millis(300))
                || now.duration_since(d) > Duration::from_secs(15)
            {
                break;
            }
        }
        std::thread::sleep(LOOP_SLEEP);
    }
    rep.finalized = finalized.len() as u32;
    Ok(rep)
}

fn welcome(cfg: &RelayConfig, p: usize, active_from: u32) -> Msg {
    Msg::Welcome {
        player: p as u8,
        seed: cfg.seed,
        slots: cfg.slots,
        initial_mask: cfg.initial_mask,
        active_from,
        ticks: cfg.ticks,
    }
}

fn frames(s: &Slot, now: Instant, relay_us: u64, f: u32, first: u32, sets: &[(InputSet, u8)]) -> Msg {
    // Inputs of this client confirmed: everything finalized plus the contiguous run received.
    let mut input_ack = f;
    while (input_ack as usize + 1) < s.inputs.len() && s.inputs[input_ack as usize + 1].is_some() {
        input_ack += 1;
    }
    Msg::Frames {
        relay_us,
        echo_us: s.last_client_us,
        hold_us: s.last_client_at.map_or(0, |a| now.duration_since(a).as_micros() as u32),
        input_ack,
        first,
        sets: sets.to_vec(),
    }
}

fn send(t: &mut dyn Transport, peer: PeerId, m: &Msg, d: Delivery) {
    t.send(peer, &m.encode(), d);
}
