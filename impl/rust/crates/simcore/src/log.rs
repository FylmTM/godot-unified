//! Input log = replay file (spec/CORE.md §1). Little-endian, versioned:
//! header `UNIL`, version u16, seed u64, player count u8, tick count u32; then per tick
//! `[4 x input (4 bytes)]` plus the per-player "replaced by relay" bitmask (u8).

use crate::input::{Input, InputSet, MAX_PLAYERS};
use std::io::{self, Read, Write};
use std::path::Path;

pub const MAGIC: &[u8; 4] = b"UNIL";
pub const VERSION: u16 = 1;
pub const HEADER_BYTES: usize = 4 + 2 + 8 + 1 + 4;
pub const TICK_BYTES: usize = MAX_PLAYERS * 4 + 1;

#[derive(Clone, Debug, Default)]
pub struct InputLog {
    pub seed: u64,
    /// Number of player slots in the session (tick 1's present inputs give the initial set).
    pub players: u8,
    /// Index t holds tick t + 1.
    pub ticks: Vec<(InputSet, u8)>,
}

impl InputLog {
    pub fn new(seed: u64, players: u8) -> InputLog {
        InputLog { seed, players, ticks: Vec::new() }
    }

    pub fn push(&mut self, inputs: InputSet, replaced: u8) {
        self.ticks.push((inputs, replaced));
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_BYTES + self.ticks.len() * TICK_BYTES);
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&VERSION.to_le_bytes());
        out.extend_from_slice(&self.seed.to_le_bytes());
        out.push(self.players);
        out.extend_from_slice(&(self.ticks.len() as u32).to_le_bytes());
        for (set, replaced) in &self.ticks {
            for i in set {
                out.extend_from_slice(&i.to_bytes());
            }
            out.push(*replaced);
        }
        out
    }

    pub fn from_bytes(b: &[u8]) -> Result<InputLog, String> {
        if b.len() < HEADER_BYTES || &b[0..4] != MAGIC {
            return Err("not an input log (bad magic)".into());
        }
        let version = u16::from_le_bytes([b[4], b[5]]);
        if version != VERSION {
            return Err(format!("input log version {version}, expected {VERSION}"));
        }
        let seed = u64::from_le_bytes(b[6..14].try_into().unwrap());
        let players = b[14];
        let n = u32::from_le_bytes(b[15..19].try_into().unwrap()) as usize;
        if b.len() != HEADER_BYTES + n * TICK_BYTES {
            return Err(format!("input log size {} != header + {n} ticks", b.len()));
        }
        let mut ticks = Vec::with_capacity(n);
        for t in 0..n {
            let o = HEADER_BYTES + t * TICK_BYTES;
            let mut set = [Input::NEUTRAL; MAX_PLAYERS];
            for (p, inp) in set.iter_mut().enumerate() {
                *inp = Input::from_bytes(b[o + p * 4..o + p * 4 + 4].try_into().unwrap());
            }
            ticks.push((set, b[o + MAX_PLAYERS * 4]));
        }
        Ok(InputLog { seed, players, ticks })
    }

    pub fn write(&self, path: &Path) -> io::Result<()> {
        std::fs::File::create(path)?.write_all(&self.to_bytes())
    }

    pub fn read(path: &Path) -> Result<InputLog, String> {
        let mut b = Vec::new();
        std::fs::File::open(path)
            .and_then(|mut f| f.read_to_end(&mut b))
            .map_err(|e| format!("{}: {e}", path.display()))?;
        InputLog::from_bytes(&b)
    }
}
