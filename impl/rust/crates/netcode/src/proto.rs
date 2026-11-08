//! Relay <-> client messages. Little-endian with explicit sizes; an input is bit-packed into
//! 4 bytes (i8, i8, u8, u8). Unreliable: `Frames` (relay -> client: finalized input sets, every
//! unacknowledged tick up to 32 per packet, plus time-sync stamps) and `Inputs` (client -> relay:
//! every input the relay hasn't confirmed). Everything else goes over the reliable lane.

use crate::wire::{R, W};
use simcore::{Input, InputSet, MAX_PLAYERS};

/// Most finalized ticks per Frames packet.
pub const MAX_FRAMES: usize = 32;
/// Most inputs per Inputs packet.
pub const MAX_INPUTS: usize = 48;
/// Snapshot chunk payload (keeps datagrams under a typical MTU).
pub const CHUNK: usize = 1100;

#[derive(Clone, Debug, PartialEq)]
pub enum Msg {
    Frames {
        relay_us: u64,
        /// The newest `client_us` the relay got from this client, and how long ago (for RTT).
        echo_us: u64,
        hold_us: u32,
        /// Every input of this client up to this tick has arrived or its tick is finalized.
        input_ack: u32,
        first: u32,
        /// (inputs, replaced-by-relay mask) for ticks first, first + 1, ...
        sets: Vec<(InputSet, u8)>,
    },
    Inputs {
        client_us: u64,
        /// Highest contiguous finalized tick this client holds.
        ack: u32,
        first: u32,
        inputs: Vec<Input>,
    },
    Hello {
        player: u8,
        /// 0: initial player; otherwise a late join requested at this tick.
        join_tick: u32,
    },
    Welcome {
        player: u8,
        seed: u64,
        slots: u8,
        initial_mask: u8,
        /// First tick this player's inputs count (1 for initial players, J for a late joiner).
        active_from: u32,
        ticks: u32,
    },
    Checksum {
        tick: u32,
        hash: u64,
    },
    SnapshotRequest {
        joiner: u8,
        min_tick: u32,
    },
    SnapshotBegin {
        joiner: u8,
        tick: u32,
        total: u32,
        /// The finalized inputs of `tick` (the base for predicting the following ticks).
        inputs: InputSet,
    },
    SnapshotChunk {
        joiner: u8,
        offset: u32,
        data: Vec<u8>,
    },
    Bye,
}

fn put_set(w: &mut W, set: &InputSet) {
    for i in set {
        w.bytes(&i.to_bytes());
    }
}

fn get_input(r: &mut R) -> Option<Input> {
    Some(Input::from_bytes(r.take(4)?.try_into().ok()?))
}

fn get_set(r: &mut R) -> Option<InputSet> {
    let mut s = [Input::NEUTRAL; MAX_PLAYERS];
    for i in s.iter_mut() {
        *i = get_input(r)?;
    }
    Some(s)
}

impl Msg {
    pub fn encode(&self) -> Vec<u8> {
        let mut w = W::new();
        match self {
            Msg::Frames { relay_us, echo_us, hold_us, input_ack, first, sets } => {
                w.u8(1).u64(*relay_us).u64(*echo_us).u32(*hold_us).u32(*input_ack).u32(*first).u8(sets.len() as u8);
                for (set, replaced) in sets {
                    w.u8(*replaced);
                    put_set(&mut w, set);
                }
            }
            Msg::Inputs { client_us, ack, first, inputs } => {
                w.u8(2).u64(*client_us).u32(*ack).u32(*first).u8(inputs.len() as u8);
                for i in inputs {
                    w.bytes(&i.to_bytes());
                }
            }
            Msg::Hello { player, join_tick } => {
                w.u8(3).u8(*player).u32(*join_tick);
            }
            Msg::Welcome { player, seed, slots, initial_mask, active_from, ticks } => {
                w.u8(4).u8(*player).u64(*seed).u8(*slots).u8(*initial_mask).u32(*active_from).u32(*ticks);
            }
            Msg::Checksum { tick, hash } => {
                w.u8(5).u32(*tick).u64(*hash);
            }
            Msg::SnapshotRequest { joiner, min_tick } => {
                w.u8(6).u8(*joiner).u32(*min_tick);
            }
            Msg::SnapshotBegin { joiner, tick, total, inputs } => {
                w.u8(7).u8(*joiner).u32(*tick).u32(*total);
                put_set(&mut w, inputs);
            }
            Msg::SnapshotChunk { joiner, offset, data } => {
                w.u8(8).u8(*joiner).u32(*offset).bytes(data);
            }
            Msg::Bye => {
                w.u8(9);
            }
        }
        w.0
    }

    pub fn decode(b: &[u8]) -> Option<Msg> {
        let mut r = R::new(b);
        Some(match r.u8()? {
            1 => {
                let (relay_us, echo_us, hold_us, input_ack, first) = (r.u64()?, r.u64()?, r.u32()?, r.u32()?, r.u32()?);
                let n = r.u8()? as usize;
                let mut sets = Vec::with_capacity(n);
                for _ in 0..n {
                    let replaced = r.u8()?;
                    sets.push((get_set(&mut r)?, replaced));
                }
                Msg::Frames { relay_us, echo_us, hold_us, input_ack, first, sets }
            }
            2 => {
                let (client_us, ack, first) = (r.u64()?, r.u32()?, r.u32()?);
                let n = r.u8()? as usize;
                let mut inputs = Vec::with_capacity(n);
                for _ in 0..n {
                    inputs.push(get_input(&mut r)?);
                }
                Msg::Inputs { client_us, ack, first, inputs }
            }
            3 => Msg::Hello { player: r.u8()?, join_tick: r.u32()? },
            4 => Msg::Welcome {
                player: r.u8()?,
                seed: r.u64()?,
                slots: r.u8()?,
                initial_mask: r.u8()?,
                active_from: r.u32()?,
                ticks: r.u32()?,
            },
            5 => Msg::Checksum { tick: r.u32()?, hash: r.u64()? },
            6 => Msg::SnapshotRequest { joiner: r.u8()?, min_tick: r.u32()? },
            7 => Msg::SnapshotBegin { joiner: r.u8()?, tick: r.u32()?, total: r.u32()?, inputs: get_set(&mut r)? },
            8 => Msg::SnapshotChunk { joiner: r.u8()?, offset: r.u32()?, data: r.rest().to_vec() },
            9 => Msg::Bye,
            _ => return None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let i = Input { move_x: -127, move_z: 89, buttons: 0x81, choice: 3 };
        let msgs = vec![
            Msg::Frames { relay_us: 1, echo_us: 2, hold_us: 3, input_ack: 4, first: 5, sets: vec![([i; 4], 2)] },
            Msg::Inputs { client_us: 9, ack: 8, first: 7, inputs: vec![i, Input::ABSENT] },
            Msg::Welcome { player: 1, seed: u64::MAX, slots: 4, initial_mask: 7, active_from: 1200, ticks: 3600 },
            Msg::SnapshotBegin { joiner: 3, tick: 1199, total: 100, inputs: [i; 4] },
            Msg::SnapshotChunk { joiner: 3, offset: 1100, data: vec![1, 2, 3] },
            Msg::Bye,
        ];
        for m in msgs {
            assert_eq!(Msg::decode(&m.encode()), Some(m));
        }
    }
}
