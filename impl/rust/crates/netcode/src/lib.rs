//! Quantum-style netcode (spec/CORE.md §2): a game-agnostic input [`relay`] that owns the tick
//! clock and finalizes input sets, a predicting / rolling-back [`client`] generic over
//! [`simcore::Simulation`], and transports behind one [`transport::Transport`] interface:
//! [`loopback`] (in-process), [`udp`], and [`netsim`] (seeded latency/jitter/loss/dup/reorder
//! wrapper around either one's datagrams). Threads + std channels + `std::net::UdpSocket`; no
//! async runtime.

pub mod client;
pub mod loopback;
pub mod netsim;
pub mod proto;
pub mod relay;
pub mod transport;
pub mod udp;
pub mod wire;

use std::time::Duration;

/// 60 Hz in microseconds.
pub const TICK_US: f64 = 1_000_000.0 / 60.0;
/// Idle sleep of the relay and client loops.
pub const LOOP_SLEEP: Duration = Duration::from_millis(1);
