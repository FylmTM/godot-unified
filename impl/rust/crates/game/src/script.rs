//! Scripted inputs (spec/GAME.md "Scripted inputs"): per player a xorshift32 seeded
//! `seed * 7919 + p + 1`, re-drawn every 24 ticks (at ticks 1, 25, 49, ...).

use crate::Game;
use crate::consts::{COS, SIN};
use crate::rng::{seed32, xorshift32};
use simcore::{BUTTON_DASH, Input, InputSet, InputSource, MAX_PLAYERS};

pub const REDRAW: u32 = 24;

#[derive(Clone, Debug)]
pub struct ScriptGen {
    rng: u32,
    r: u32,
    next_draw: u32,
    last_draw: u32,
}

impl ScriptGen {
    pub fn new(seed: u64, player: usize) -> ScriptGen {
        let s = seed.wrapping_mul(7919).wrapping_add(player as u64 + 1);
        ScriptGen { rng: seed32(s), r: 0, next_draw: 1, last_draw: 0 }
    }

    /// The input for `tick`. Ticks must be requested in non-decreasing order; skipped ticks still
    /// advance the draws, so the result depends only on (seed, player, tick, pending).
    pub fn input(&mut self, tick: u32, pending_levelups: u32) -> Input {
        while self.next_draw <= tick {
            self.r = xorshift32(&mut self.rng);
            self.last_draw = self.next_draw;
            self.next_draw += REDRAW;
        }
        let r = self.r;
        let (move_x, move_z) = if r % 9 == 8 {
            (0, 0)
        } else {
            let d = (r % 8) as usize;
            ((COS[d] * 127.0) as i8, (SIN[d] * 127.0) as i8)
        };
        let buttons = if tick == self.last_draw && r.is_multiple_of(13) { BUTTON_DASH } else { 0 };
        let choice = if pending_levelups > 0 { (r % 3) as u8 + 1 } else { 0 };
        Input { move_x, move_z, buttons, choice }
    }
}

/// Scripted inputs for the first `players` slots (the rest absent): `sim`, `synctest`, `bench`.
pub struct Scripted {
    gens: Vec<ScriptGen>,
}

impl Scripted {
    pub fn new(seed: u64, players: usize) -> Scripted {
        Scripted { gens: (0..players.min(MAX_PLAYERS)).map(|p| ScriptGen::new(seed, p)).collect() }
    }

    /// The inputs for the tick after the game's current one.
    pub fn next(&mut self, g: &Game) -> InputSet {
        let tick = g.s.tick + 1;
        let mut set = [Input::ABSENT; MAX_PLAYERS];
        for (p, sg) in self.gens.iter_mut().enumerate() {
            set[p] = sg.input(tick, g.s.players[p].pending_levelups);
        }
        set
    }
}

/// One player's scripted inputs, for a networked client.
pub struct PlayerScript(pub ScriptGen);

impl InputSource<Game> for PlayerScript {
    fn input(&mut self, sim: &Game, player: usize, tick: u32) -> Input {
        self.0.input(tick, sim.s.players[player].pending_levelups)
    }
}
