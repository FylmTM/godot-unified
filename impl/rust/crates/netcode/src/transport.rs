//! The transport interface and the connection layer shared by loopback and UDP.
//!
//! Layering: a [`Datagram`] socket moves unreliable datagrams (in-process channels, UDP, or the
//! netsim wrapper around either). [`Endpoint`] turns any of them into a [`Transport`]: peers with
//! connect/disconnect events, an unreliable lane, and a minimal reliable ordered lane (sequence
//! numbers, cumulative ack + 32-bit ack field, retransmission on timeout, a send window). Putting
//! the netsim *under* the reliable lane is what lets snapshots and checksums survive simulated loss.

use crate::wire::{R, W};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::fmt::Debug;
use std::hash::Hash;
use std::time::{Duration, Instant};

pub type PeerId = u32;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Delivery {
    Unreliable,
    Reliable,
}

#[derive(Debug)]
pub enum Event {
    Connected(PeerId),
    Disconnected(PeerId),
    Message(PeerId, Vec<u8>),
}

/// `send(peer, bytes, unreliable|reliable)`, `poll() -> events`, connect/disconnect.
pub trait Transport: Send {
    fn send(&mut self, peer: PeerId, data: &[u8], delivery: Delivery);
    /// Receives, (re)sends and times out; appends events.
    fn poll(&mut self, events: &mut Vec<Event>);
    fn disconnect(&mut self, peer: PeerId);
    /// Reliable messages to `peer` not yet acknowledged.
    fn reliable_pending(&self, peer: PeerId) -> usize;
}

/// An unreliable datagram socket.
pub trait Datagram: Send {
    type Addr: Copy + Eq + Hash + Debug + Send;
    fn send_to(&mut self, to: Self::Addr, bytes: &[u8]);
    fn recv_from(&mut self) -> Option<(Self::Addr, Vec<u8>)>;
}

const K_CONNECT: u8 = 1;
const K_ACCEPT: u8 = 2;
const K_UNREL: u8 = 3;
const K_REL: u8 = 4;
const K_ACK: u8 = 5;
const K_BYE: u8 = 6;

const WINDOW: usize = 128;

fn send_raw<D: Datagram>(sock: &mut D, addr: D::Addr, kind: u8, body: &[u8]) {
    let mut w = W::new();
    w.u8(kind).bytes(body);
    sock.send_to(addr, &w.0);
}
const CONNECT_RETRY: Duration = Duration::from_millis(100);
const PEER_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(PartialEq)]
enum PeerState {
    Connecting,
    Connected,
    Closed,
}

struct Pending {
    seq: u32,
    data: Vec<u8>,
    sent_at: Option<Instant>,
    resent: bool,
}

struct Peer<A> {
    addr: A,
    state: PeerState,
    last_recv: Instant,
    last_connect: Option<Instant>,
    next_seq: u32,
    unacked: VecDeque<Pending>,
    recv_next: u32,
    ooo: BTreeMap<u32, Vec<u8>>,
    ack_dirty: bool,
    srtt_ms: f64,
}

pub struct Endpoint<D: Datagram> {
    sock: D,
    accept: bool,
    peers: Vec<Peer<D::Addr>>,
    by_addr: HashMap<D::Addr, PeerId>,
}

impl<D: Datagram> Endpoint<D> {
    /// `accept`: create peers for incoming connects (the relay side).
    pub fn new(sock: D, accept: bool) -> Endpoint<D> {
        Endpoint { sock, accept, peers: Vec::new(), by_addr: HashMap::new() }
    }

    fn add_peer(&mut self, addr: D::Addr, state: PeerState) -> PeerId {
        let id = self.peers.len() as PeerId;
        self.peers.push(Peer {
            addr,
            state,
            last_recv: Instant::now(),
            last_connect: None,
            next_seq: 0,
            unacked: VecDeque::new(),
            recv_next: 0,
            ooo: BTreeMap::new(),
            ack_dirty: false,
            srtt_ms: 50.0,
        });
        self.by_addr.insert(addr, id);
        id
    }

    /// Starts connecting to `addr`; a `Connected` event follows once it answers.
    pub fn connect(&mut self, addr: D::Addr) -> PeerId {
        self.add_peer(addr, PeerState::Connecting)
    }

    fn raw(&mut self, peer: PeerId, kind: u8, body: &[u8]) {
        let addr = self.peers[peer as usize].addr;
        send_raw(&mut self.sock, addr, kind, body);
    }

    fn on_packet(&mut self, addr: D::Addr, pkt: &[u8], now: Instant, events: &mut Vec<Event>) {
        let Some(&kind) = pkt.first() else { return };
        let id = match self.by_addr.get(&addr) {
            Some(&id) => id,
            None if self.accept && kind == K_CONNECT => {
                let id = self.add_peer(addr, PeerState::Connected);
                events.push(Event::Connected(id));
                id
            }
            None => return,
        };
        let p = &mut self.peers[id as usize];
        if p.state == PeerState::Closed {
            return;
        }
        p.last_recv = now;
        if p.state == PeerState::Connecting && kind != K_CONNECT {
            p.state = PeerState::Connected; // any answer (ACCEPT or later traffic) completes it
            events.push(Event::Connected(id));
        }
        let mut r = R::new(&pkt[1..]);
        match kind {
            K_CONNECT => self.raw(id, K_ACCEPT, &[]),
            K_ACCEPT => {}
            K_UNREL => events.push(Event::Message(id, r.rest().to_vec())),
            K_REL => {
                let Some(seq) = r.u32() else { return };
                let p = &mut self.peers[id as usize];
                p.ack_dirty = true;
                if seq >= p.recv_next && !p.ooo.contains_key(&seq) && seq - p.recv_next < 4 * WINDOW as u32 {
                    p.ooo.insert(seq, r.rest().to_vec());
                    while let Some(m) = p.ooo.remove(&p.recv_next) {
                        events.push(Event::Message(id, m));
                        p.recv_next += 1;
                    }
                }
            }
            K_ACK => {
                let (Some(next), Some(bits)) = (r.u32(), r.u32()) else { return };
                let p = &mut self.peers[id as usize];
                p.unacked.retain(|m| {
                    let acked =
                        m.seq < next || (m.seq > next && m.seq - next <= 32 && bits & (1 << (m.seq - next - 1)) != 0);
                    if acked
                        && !m.resent
                        && let Some(t) = m.sent_at
                    {
                        let sample = now.duration_since(t).as_secs_f64() * 1000.0;
                        p.srtt_ms = 0.875 * p.srtt_ms + 0.125 * sample;
                    }
                    !acked
                });
            }
            K_BYE => {
                p.state = PeerState::Closed;
                events.push(Event::Disconnected(id));
            }
            _ => {}
        }
    }
}

impl<D: Datagram> Transport for Endpoint<D> {
    fn send(&mut self, peer: PeerId, data: &[u8], delivery: Delivery) {
        let Some(p) = self.peers.get_mut(peer as usize) else { return };
        match delivery {
            Delivery::Unreliable => {
                if p.state == PeerState::Connected {
                    let addr = p.addr;
                    send_raw(&mut self.sock, addr, K_UNREL, data);
                }
            }
            Delivery::Reliable => {
                if p.state != PeerState::Closed {
                    let seq = p.next_seq;
                    p.next_seq += 1;
                    p.unacked.push_back(Pending { seq, data: data.to_vec(), sent_at: None, resent: false });
                }
            }
        }
    }

    fn poll(&mut self, events: &mut Vec<Event>) {
        let now = Instant::now();
        while let Some((addr, pkt)) = self.sock.recv_from() {
            self.on_packet(addr, &pkt, now, events);
        }
        let Endpoint { sock, peers, .. } = self;
        for (id, p) in peers.iter_mut().enumerate() {
            match p.state {
                PeerState::Closed => continue,
                PeerState::Connecting => {
                    if p.last_connect.is_none_or(|t| now.duration_since(t) >= CONNECT_RETRY) {
                        p.last_connect = Some(now);
                        p.last_recv = now;
                        send_raw(sock, p.addr, K_CONNECT, &[]);
                    }
                    continue;
                }
                PeerState::Connected => {}
            }
            if now.duration_since(p.last_recv) > PEER_TIMEOUT {
                p.state = PeerState::Closed;
                events.push(Event::Disconnected(id as PeerId));
                continue;
            }
            if p.ack_dirty {
                p.ack_dirty = false;
                let next = p.recv_next;
                let mut bits = 0u32;
                for (&s, _) in p.ooo.range(next + 1..next + 33) {
                    bits |= 1 << (s - next - 1);
                }
                let mut w = W::new();
                w.u32(next).u32(bits);
                send_raw(sock, p.addr, K_ACK, &w.0);
            }
            let rto = Duration::from_secs_f64((p.srtt_ms * 2.0 + 20.0).clamp(40.0, 1000.0) / 1000.0);
            for m in p.unacked.iter_mut().take(WINDOW) {
                let due = match m.sent_at {
                    None => true,
                    Some(t) => now.duration_since(t) >= rto,
                };
                if due {
                    m.resent |= m.sent_at.is_some();
                    m.sent_at = Some(now);
                    let mut w = W::new();
                    w.u32(m.seq).bytes(&m.data);
                    send_raw(sock, p.addr, K_REL, &w.0);
                }
            }
        }
    }

    fn disconnect(&mut self, peer: PeerId) {
        if let Some(p) = self.peers.get_mut(peer as usize)
            && p.state != PeerState::Closed
        {
            p.state = PeerState::Closed;
            self.raw(peer, K_BYE, &[]);
        }
    }

    fn reliable_pending(&self, peer: PeerId) -> usize {
        self.peers.get(peer as usize).map_or(0, |p| p.unacked.len())
    }
}
