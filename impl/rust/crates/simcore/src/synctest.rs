//! Sync-test (spec/CORE.md §1): every tick save; once W ticks exist, restore W ticks back,
//! re-simulate them with the recorded inputs and compare every re-simulated checksum with the
//! forward one.

use crate::input::InputSet;
use crate::ring::{RING, SnapshotRing};
use crate::sim::Simulation;

#[derive(Debug, Default)]
pub struct SyncTestResult {
    pub ticks: u32,
    pub mismatches: u32,
    pub first_mismatch: Option<u32>,
    pub resimulated: u64,
    pub final_checksum: u64,
}

/// `next_input(sim)` produces the inputs for tick `sim.tick() + 1`.
pub fn run<S: Simulation>(
    sim: &mut S,
    ticks: u32,
    window: u32,
    mut next_input: impl FnMut(&S) -> InputSet,
) -> SyncTestResult {
    assert!(window >= 1 && (window as usize) < RING, "window must be 1..{}", RING - 1);
    let mut ring = SnapshotRing::new(sim);
    ring.save(sim);
    let base = sim.tick();
    let mut inputs: Vec<InputSet> = Vec::with_capacity(ticks as usize);
    let mut forward: Vec<u64> = Vec::with_capacity(ticks as usize);
    let mut r = SyncTestResult::default();
    for k in 1..=ticks {
        let set = next_input(sim);
        sim.step(&set);
        inputs.push(set);
        forward.push(sim.checksum());
        ring.save(sim);
        if k >= window {
            let from = base + k - window;
            ring.restore(sim, from);
            for j in (k - window + 1)..=k {
                sim.step(&inputs[(j - 1) as usize]);
                ring.save(sim);
                r.resimulated += 1;
                if sim.checksum() != forward[(j - 1) as usize] {
                    r.mismatches += 1;
                    r.first_mismatch.get_or_insert(base + j);
                }
            }
        }
    }
    r.ticks = ticks;
    r.final_checksum = forward.last().copied().unwrap_or(0);
    r
}
