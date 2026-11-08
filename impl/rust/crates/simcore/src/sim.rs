//! The contract between the harness/netcode and a game.

use crate::input::{Input, InputSet};

/// A deterministic fixed-tick simulation with snapshots.
///
/// Ticks are numbered from 1: after the k-th `step` the state is tick k. A `Slot` is an in-memory
/// snapshot (state block copy + physics image) reused by the ring without reallocating.
pub trait Simulation {
    type Slot;

    fn new_slot(&mut self) -> Self::Slot;
    /// The tick the current state represents.
    fn tick(&self) -> u32;
    fn step(&mut self, inputs: &InputSet);
    /// XXH3-64 of the canonical state (block + physics bodies).
    fn checksum(&self) -> u64;
    fn save(&mut self, slot: &mut Self::Slot);
    fn restore(&mut self, slot: &Self::Slot);
    fn slot_tick(slot: &Self::Slot) -> u32;
    /// Size of a saved slot (block + physics image), for reporting.
    fn slot_bytes(slot: &Self::Slot) -> usize;
    /// Portable snapshot bytes of a saved slot (restorable on another machine / OS).
    fn export_slot(slot: &Self::Slot) -> Vec<u8>;
    /// Replace the whole state with a portable snapshot.
    fn import(&mut self, bytes: &[u8]) -> Result<(), String>;
}

/// Produces a player's input for a tick from the (possibly predicted) state before that tick.
pub trait InputSource<S> {
    fn input(&mut self, sim: &S, player: usize, tick: u32) -> Input;
}
