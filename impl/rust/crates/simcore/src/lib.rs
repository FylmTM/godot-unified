//! The game-agnostic core of the unified sim harness (spec/CORE.md §1).
//!
//! A game implements [`Simulation`] (fixed-tick step, save/restore into ring slots, checksum,
//! portable export/import); everything here (snapshot ring, sync-test, input logs, traces) and
//! the netcode crate are written against that trait only.

pub mod input;
pub mod json;
pub mod log;
pub mod ring;
pub mod sim;
pub mod stats;
pub mod synctest;
pub mod trace;

pub use input::{ABSENT, BUTTON_DASH, Input, InputSet, MAX_PLAYERS};
pub use ring::SnapshotRing;
pub use sim::{InputSource, Simulation};

/// 60 Hz fixed tick: `0.016666668f32`, bits 0x3C888889.
pub const DT: f32 = 0.016666668;
const _: () = assert!(DT.to_bits() == 0x3C88_8889);

/// Every state block and wire format is little-endian; the checksum hashes raw bytes.
#[cfg(not(target_endian = "little"))]
compile_error!("unified assumes a little-endian target");
