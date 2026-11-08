//! Per-player, per-tick input: 4 bytes (spec/CORE.md §1, spec/GAME.md "Input").

use bytemuck::{Pod, Zeroable};

pub const MAX_PLAYERS: usize = 4;
/// `buttons` bit 0: dash (edge-triggered).
pub const BUTTON_DASH: u8 = 1 << 0;
/// `buttons` bit 7: the player is absent (not joined, or disconnected).
pub const ABSENT: u8 = 1 << 7;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Pod, Zeroable)]
pub struct Input {
    pub move_x: i8,
    pub move_z: i8,
    pub buttons: u8,
    pub choice: u8,
}

pub type InputSet = [Input; MAX_PLAYERS];

impl Input {
    pub const NEUTRAL: Input = Input { move_x: 0, move_z: 0, buttons: 0, choice: 0 };
    pub const ABSENT: Input = Input { move_x: 0, move_z: 0, buttons: ABSENT, choice: 0 };

    pub fn is_absent(&self) -> bool {
        self.buttons & ABSENT != 0
    }

    /// Wire / log encoding: `i8, i8, u8, u8`.
    pub fn to_bytes(self) -> [u8; 4] {
        [self.move_x as u8, self.move_z as u8, self.buttons, self.choice]
    }

    pub fn from_bytes(b: [u8; 4]) -> Input {
        Input { move_x: b[0] as i8, move_z: b[1] as i8, buttons: b[2], choice: b[3] }
    }
}

/// The initial player set as a bitmask: the players whose tick-1 input is present.
pub fn present_mask(set: &InputSet) -> u8 {
    let mut m = 0;
    for (p, i) in set.iter().enumerate() {
        if !i.is_absent() {
            m |= 1 << p;
        }
    }
    m
}
