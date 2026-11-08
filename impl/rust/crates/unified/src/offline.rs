//! Offline modes: sim, synctest, replay, snapshot, resume, bench.

use crate::args::Args;
use game::state::{MAX_ENEMIES, STATE_BYTES};
use game::{Game, Scripted};
use simcore::json::Json;
use simcore::log::InputLog;
use simcore::stats::Samples;
use simcore::trace::{Trace, hex};
use simcore::{InputSet, Simulation, SnapshotRing, synctest};
use std::path::Path;
use std::time::Instant;

pub type Out = Result<(Json, bool), String>;

const LIMIT: u32 = MAX_ENEMIES as u32;

fn write_trace(t: &Trace, path: Option<&str>) -> Result<(), String> {
    if let Some(p) = path {
        t.write(Path::new(p)).map_err(|e| format!("{p}: {e}"))?;
    }
    Ok(())
}

pub fn sim(a: &Args) -> Out {
    let ticks: u32 = a.req("ticks")?;
    let seed: u64 = a.get("seed", 1)?;
    let players: usize = a.get("players", 4)?;
    let t0 = Instant::now();
    let mut g = Game::new(seed, Game::mask_of(players), LIMIT);
    let mut sc = Scripted::new(seed, players);
    let mut log = InputLog::new(seed, players as u8);
    let mut trace = Trace::default();
    let want_trace = a.str("trace").is_some();
    for _ in 0..ticks {
        let set = sc.next(&g);
        g.step(&set);
        log.push(set, 0);
        if want_trace {
            trace.push(g.tick(), g.checksum());
        }
    }
    let fin = g.checksum();
    write_trace(&trace, a.str("trace"))?;
    if let Some(p) = a.str("log") {
        log.write(Path::new(p)).map_err(|e| format!("{p}: {e}"))?;
    }
    Ok((
        Json::obj()
            .with("mode", "sim")
            .with("ticks", ticks)
            .with("seed", seed)
            .with("players", players)
            .with("final_checksum", hex(fin))
            .with("enemies_alive", g.alive_enemies())
            .with(
                "players_state",
                Json::Arr(
                    g.s.players
                        .iter()
                        .map(|p| {
                            Json::obj()
                                .with("alive", p.alive)
                                .with("hp", p.hp)
                                .with("level", p.level)
                                .with("xp", p.xp)
                                .with("pending", p.pending_levelups)
                                .with("fire_interval", p.fire_interval)
                        })
                        .collect(),
                ),
            )
            .with("gems", g.s.gems.count)
            .with("projectiles", g.s.projectiles.count)
            .with("elapsed_ms", t0.elapsed().as_secs_f64() * 1e3),
        true,
    ))
}

pub fn synctest(a: &Args) -> Out {
    let ticks: u32 = a.req("ticks")?;
    let window: u32 = a.req("window")?;
    let seed: u64 = a.get("seed", 1)?;
    let players: usize = a.get("players", 4)?;
    if window == 0 || window >= 16 {
        return Err("--window must be 1..15 (ring of 16)".into());
    }
    let t0 = Instant::now();
    let mut g = Game::new(seed, Game::mask_of(players), LIMIT);
    let mut sc = Scripted::new(seed, players);
    let r = synctest::run(&mut g, ticks, window, |g| sc.next(g));
    let mut j = Json::obj()
        .with("mode", "synctest")
        .with("ticks", ticks)
        .with("window", window)
        .with("seed", seed)
        .with("players", players)
        .with("mismatches", r.mismatches)
        .with("resimulated_ticks", r.resimulated)
        .with("final_checksum", hex(r.final_checksum))
        .with("elapsed_ms", t0.elapsed().as_secs_f64() * 1e3);
    if let Some(t) = r.first_mismatch {
        j = j.with("first_mismatch", t);
    }
    Ok((j, r.mismatches == 0))
}

pub fn replay(a: &Args) -> Out {
    let path: String = a.req("log")?;
    let log = InputLog::read(Path::new(&path))?;
    let mask = log.ticks.first().map_or(Game::mask_of(log.players as usize), |(s, _)| simcore::input::present_mask(s));
    let mut g = Game::new(log.seed, mask, LIMIT);
    let mut trace = Trace::default();
    let mut replaced = 0u32;
    for (set, rep) in &log.ticks {
        g.step(set);
        trace.push(g.tick(), g.checksum());
        replaced += rep.count_ones();
    }
    write_trace(&trace, a.str("trace"))?;
    Ok((
        Json::obj()
            .with("mode", "replay")
            .with("ticks", log.ticks.len())
            .with("seed", log.seed)
            .with("players", log.players)
            .with("replaced_inputs", replaced)
            .with("final_checksum", hex(g.checksum())),
        true,
    ))
}

pub fn snapshot(a: &Args) -> Out {
    let ticks: u32 = a.req("ticks")?;
    let out: String = a.req("out")?;
    let seed: u64 = a.get("seed", 1)?;
    let players: usize = a.get("players", 4)?;
    let mut g = Game::new(seed, Game::mask_of(players), LIMIT);
    let mut sc = Scripted::new(seed, players);
    for _ in 0..ticks {
        let set = sc.next(&g);
        g.step(&set);
    }
    let mut slot = g.new_slot();
    g.save(&mut slot);
    let bytes = Game::export_slot(&slot);
    std::fs::write(&out, &bytes).map_err(|e| format!("{out}: {e}"))?;
    Ok((
        Json::obj()
            .with("mode", "snapshot")
            .with("tick", g.tick())
            .with("bytes", bytes.len())
            .with("state_bytes", STATE_BYTES)
            .with("physics_bytes", bytes.len() - STATE_BYTES - 24)
            .with("checksum", hex(g.checksum())),
        true,
    ))
}

pub fn resume(a: &Args) -> Out {
    let path: String = a.req("in")?;
    let ticks: u32 = a.req("ticks")?;
    let bytes = std::fs::read(&path).map_err(|e| format!("{path}: {e}"))?;
    let mut g = Game::from_snapshot(&bytes)?;
    let players = g.s.initial_mask.count_ones() as usize;
    let mut sc = Scripted::new(g.s.seed(), players);
    let from = g.tick();
    let mut trace = Trace::default();
    for _ in 0..ticks {
        let set = sc.next(&g);
        g.step(&set);
        trace.push(g.tick(), g.checksum());
    }
    write_trace(&trace, a.str("trace"))?;
    Ok((
        Json::obj()
            .with("mode", "resume")
            .with("from_tick", from)
            .with("ticks", ticks)
            .with("final_checksum", hex(g.checksum())),
        true,
    ))
}

pub fn bench(a: &Args) -> Out {
    let enemies: u32 = a.get("enemies", 1000)?;
    let window: u32 = a.get("window", 8)?;
    let ticks: u32 = a.get("ticks", 600)?;
    if window == 0 || window >= 16 {
        return Err("--window must be 1..15".into());
    }
    let mut g = Game::new(1, Game::mask_of(4), enemies);
    g.prespawn(enemies);
    let mut sc = Scripted::new(1, 4);
    let mut ring = SnapshotRing::new(&mut g);
    ring.save(&mut g);
    let (mut step, mut save, mut restore, mut resim) =
        (Samples::default(), Samples::default(), Samples::default(), Samples::default());
    let mut inputs: Vec<InputSet> = Vec::with_capacity(ticks as usize + 1);
    inputs.push(Default::default());
    let mut alive_sum = 0u64;
    let us = |t: Instant| t.elapsed().as_secs_f64() * 1e6;
    for _ in 0..ticks {
        let set = sc.next(&g);
        inputs.push(set);
        let t0 = Instant::now();
        g.step(&set);
        step.push(us(t0));
        let t0 = Instant::now();
        ring.save(&mut g);
        save.push(us(t0));
        alive_sum += g.alive_enemies() as u64;
        let now = g.tick();
        if now >= window {
            let t0 = Instant::now();
            ring.restore(&mut g, now - window);
            restore.push(us(t0));
            let t0 = Instant::now();
            for k in (now - window + 1)..=now {
                g.step(&inputs[k as usize]);
                ring.save(&mut g);
            }
            resim.push(us(t0));
        }
    }
    let slot_bytes = ring.get(g.tick()).map_or(0, Game::slot_bytes);
    let total = step.mean() + resim.mean();
    Ok((
        Json::obj()
            .with("mode", "bench")
            .with("enemies", enemies)
            .with("window", window)
            .with("ticks", ticks)
            .with("enemies_alive_avg", alive_sum as f64 / ticks.max(1) as f64)
            .with("step_us", step.json())
            .with("save_us", save.json())
            .with("restore_us", restore.json())
            .with("resim_us", resim.json())
            .with("step_plus_resim_ms", total / 1000.0)
            .with("snapshot_bytes", slot_bytes)
            .with("state_bytes", STATE_BYTES)
            .with("physics_bytes", slot_bytes - STATE_BYTES)
            .with("resim_note", "W x (step + save), after a restore"),
        true,
    ))
}
