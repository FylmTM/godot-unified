//! Ring of the last 16 snapshots, slot = tick % 16.

use crate::sim::Simulation;

pub const RING: usize = 16;

pub struct SnapshotRing<S: Simulation> {
    slots: Vec<S::Slot>,
}

impl<S: Simulation> SnapshotRing<S> {
    pub fn new(sim: &mut S) -> Self {
        SnapshotRing { slots: (0..RING).map(|_| sim.new_slot()).collect() }
    }

    /// Saves the current state into slot `tick % 16`.
    pub fn save(&mut self, sim: &mut S) {
        let t = sim.tick() as usize;
        sim.save(&mut self.slots[t % RING]);
    }

    /// The slot holding `tick`, if it has not been overwritten.
    pub fn get(&self, tick: u32) -> Option<&S::Slot> {
        let s = &self.slots[tick as usize % RING];
        (S::slot_tick(s) == tick).then_some(s)
    }

    /// Restores `tick`; panics if the ring no longer holds it (a netcode invariant violation).
    pub fn restore(&self, sim: &mut S, tick: u32) {
        let slot = self.get(tick).unwrap_or_else(|| panic!("snapshot ring lost tick {tick}"));
        sim.restore(slot);
        debug_assert_eq!(sim.tick(), tick);
    }
}
