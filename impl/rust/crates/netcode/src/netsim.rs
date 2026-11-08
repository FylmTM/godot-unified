//! Network simulator: wraps any [`Datagram`] socket and applies seeded latency, jitter, loss,
//! duplication and reordering to both directions (so a wrapped client sees the profile's one-way
//! delay on its uplink and its downlink). Decisions come from a seeded RNG; delivery times are real
//! (monotonic) time.

use crate::transport::Datagram;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Profile {
    pub latency_ms: f64,
    pub jitter_ms: f64,
    pub loss: f64,
    pub dup: f64,
    pub reorder: f64,
}

impl Profile {
    pub const IDEAL: Profile = Profile { latency_ms: 0.0, jitter_ms: 0.0, loss: 0.0, dup: 0.0, reorder: 0.0 };
    pub const WAN: Profile = Profile { latency_ms: 50.0, jitter_ms: 15.0, loss: 0.02, dup: 0.01, reorder: 0.01 };
    pub const BAD: Profile = Profile { latency_ms: 120.0, jitter_ms: 40.0, loss: 0.08, dup: 0.03, reorder: 0.05 };

    pub fn parse(name: &str) -> Option<Profile> {
        match name {
            "ideal" => Some(Profile::IDEAL),
            "wan" => Some(Profile::WAN),
            "bad" => Some(Profile::BAD),
            _ => None,
        }
    }

    pub fn is_ideal(&self) -> bool {
        *self == Profile::IDEAL
    }
}

struct Delayed<A> {
    due: Instant,
    order: u64,
    addr: A,
    data: Vec<u8>,
}

pub struct NetSim<D: Datagram> {
    inner: D,
    profile: Profile,
    rng: u64,
    order: u64,
    outgoing: Vec<Delayed<D::Addr>>,
    incoming: Vec<Delayed<D::Addr>>,
    ready: std::collections::VecDeque<(D::Addr, Vec<u8>)>,
}

impl<D: Datagram> NetSim<D> {
    pub fn new(inner: D, profile: Profile, seed: u64) -> NetSim<D> {
        NetSim {
            inner,
            profile,
            rng: seed ^ 0x9E37_79B9_7F4A_7C15,
            order: 0,
            outgoing: Vec::new(),
            incoming: Vec::new(),
            ready: Default::default(),
        }
    }

    /// splitmix64 -> [0, 1)
    fn uniform(&mut self) -> f64 {
        self.rng = self.rng.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.rng;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        (z >> 11) as f64 / (1u64 << 53) as f64
    }

    /// Delivery times for one datagram: empty = lost, two = duplicated.
    fn schedule(&mut self, now: Instant) -> Vec<Instant> {
        let p = self.profile;
        if self.uniform() < p.loss {
            return Vec::new();
        }
        let copies = if self.uniform() < p.dup { 2 } else { 1 };
        let mut out = Vec::with_capacity(copies);
        for _ in 0..copies {
            let mut ms = p.latency_ms + (self.uniform() * 2.0 - 1.0) * p.jitter_ms;
            if self.uniform() < p.reorder {
                ms += p.jitter_ms * 2.0 + 20.0; // held back so later datagrams overtake it
            }
            out.push(now + Duration::from_secs_f64(ms.max(0.0) / 1000.0));
        }
        out
    }

    fn take_due(q: &mut Vec<Delayed<D::Addr>>, now: Instant) -> Vec<Delayed<D::Addr>> {
        let mut due = Vec::new();
        let mut i = 0;
        while i < q.len() {
            if q[i].due <= now {
                due.push(q.swap_remove(i));
            } else {
                i += 1;
            }
        }
        due.sort_by_key(|d| (d.due, d.order));
        due
    }

    fn flush(&mut self, now: Instant) {
        for d in Self::take_due(&mut self.outgoing, now) {
            self.inner.send_to(d.addr, &d.data);
        }
        while let Some((addr, data)) = self.inner.recv_from() {
            for due in self.schedule(now) {
                self.order += 1;
                self.incoming.push(Delayed { due, order: self.order, addr, data: data.clone() });
            }
        }
        for d in Self::take_due(&mut self.incoming, now) {
            self.ready.push_back((d.addr, d.data));
        }
    }
}

impl<D: Datagram> Datagram for NetSim<D> {
    type Addr = D::Addr;

    fn send_to(&mut self, to: D::Addr, bytes: &[u8]) {
        let now = Instant::now();
        for due in self.schedule(now) {
            self.order += 1;
            self.outgoing.push(Delayed { due, order: self.order, addr: to, data: bytes.to_vec() });
        }
        self.flush(now);
    }

    fn recv_from(&mut self) -> Option<(D::Addr, Vec<u8>)> {
        if self.ready.is_empty() {
            self.flush(Instant::now());
        }
        self.ready.pop_front()
    }
}
