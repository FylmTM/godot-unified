//! Networked modes: `session` (in-process relay + N client threads), `relay` and `client`
//! (separate processes over UDP).

use crate::args::Args;
use crate::offline::Out;
use game::state::MAX_ENEMIES;
use game::{Game, PlayerScript, ScriptGen};
use netcode::client::{self, ClientConfig, ClientReport};
use netcode::loopback::LoopbackHub;
use netcode::netsim::{NetSim, Profile};
use netcode::relay::{self, RelayConfig, RelayReport};
use netcode::transport::{Datagram, Endpoint, Transport};
use netcode::udp::UdpDatagram;
use simcore::json::Json;
use std::net::{SocketAddr, ToSocketAddrs};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread;
use std::time::{Duration, Instant};

const TOLERANCE: u32 = 6;

fn profile(a: &Args) -> Result<Profile, String> {
    let name = a.str("profile").unwrap_or("ideal");
    Profile::parse(name).ok_or_else(|| format!("unknown --profile {name:?} (ideal|wan|bad)"))
}

/// Runs a client on any datagram socket, wrapped in the netsim unless the profile is ideal.
fn run_client<D: Datagram + 'static>(
    sock: D,
    relay: D::Addr,
    prof: Profile,
    net_seed: u64,
    seed: u64,
    cfg: ClientConfig,
) -> Result<ClientReport, String> {
    let mut ep: Box<dyn Transport> = if prof.is_ideal() {
        let mut ep = Endpoint::new(sock, false);
        let _ = ep.connect(relay);
        Box::new(ep)
    } else {
        let mut ep = Endpoint::new(NetSim::new(sock, prof, net_seed), false);
        let _ = ep.connect(relay);
        Box::new(ep)
    };
    let script = PlayerScript(ScriptGen::new(seed, cfg.player as usize));
    client::run(&mut *ep, 0, &cfg, |seed, mask| Game::new(seed, mask, MAX_ENEMIES as u32), script)
}

fn run_relay<D: Datagram>(sock: D, cfg: &RelayConfig, progress: Option<&AtomicU32>) -> Result<RelayReport, String> {
    let mut ep = Endpoint::new(sock, true);
    relay::run(&mut ep, cfg, progress)
}

fn parse_late_join(s: Option<&str>) -> Result<Option<(u8, u32)>, String> {
    let Some(s) = s else { return Ok(None) };
    let (p, t) = s.split_once('@').ok_or("--late-join wants P@T")?;
    Ok(Some((p.parse().map_err(|_| "--late-join: bad player")?, t.parse().map_err(|_| "--late-join: bad tick")?)))
}

pub fn session(a: &Args) -> Out {
    let n: u8 = a.req("clients")?;
    let ticks: u32 = a.req("ticks")?;
    let seed: u64 = a.get("seed", 1)?;
    let prof = profile(a)?;
    let transport = a.str("transport").unwrap_or("loopback").to_string();
    let late = parse_late_join(a.str("late-join"))?;
    if !(1..=4).contains(&n) {
        return Err("--clients must be 1..4".into());
    }
    if let Some((p, _)) = late
        && p >= n
    {
        return Err("--late-join player must be < --clients".into());
    }
    let mut initial_mask = ((1u32 << n) - 1) as u8;
    if let Some((p, _)) = late {
        initial_mask &= !(1 << p);
    }
    let rcfg = RelayConfig {
        slots: n,
        initial_mask,
        ticks,
        seed,
        tolerance: TOLERANCE,
        start_timeout: Duration::from_secs(30),
    };
    let progress = Arc::new(AtomicU32::new(0));
    let t0 = Instant::now();

    // One socket per participant, created here and moved into its thread.
    enum Sock {
        Loop(netcode::loopback::LoopbackSocket),
        Udp(UdpDatagram),
    }
    let (relay_sock, relay_addr_loop, relay_addr_udp, mut client_socks) = match transport.as_str() {
        "loopback" => {
            let hub = LoopbackHub::new();
            let r = hub.socket();
            let addr = r.addr();
            let cs: Vec<Sock> = (0..n).map(|_| Sock::Loop(hub.socket())).collect();
            (Sock::Loop(r), addr, None, cs)
        }
        "udp" => {
            let r = UdpDatagram::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
            let addr = r.local_addr();
            let mut cs = Vec::new();
            for _ in 0..n {
                cs.push(Sock::Udp(UdpDatagram::bind("127.0.0.1:0").map_err(|e| e.to_string())?));
            }
            (Sock::Udp(r), 0, Some(addr), cs)
        }
        t => return Err(format!("unknown --transport {t:?} (loopback|udp)")),
    };

    let relay_thread = {
        let progress = progress.clone();
        let rcfg = rcfg.clone();
        thread::Builder::new()
            .name("relay".into())
            .spawn(move || match relay_sock {
                Sock::Loop(s) => run_relay(s, &rcfg, Some(&progress)),
                Sock::Udp(s) => run_relay(s, &rcfg, Some(&progress)),
            })
            .map_err(|e| e.to_string())?
    };

    let mut threads = Vec::new();
    for p in (0..n).rev() {
        let sock = client_socks.pop().unwrap();
        let progress = progress.clone();
        let join_tick = late.filter(|&(lp, _)| lp == p).map(|(_, t)| t);
        let mut cfg = ClientConfig::new(p);
        cfg.join_tick = join_tick.unwrap_or(0);
        let net_seed = seed.wrapping_mul(1_000_003).wrapping_add(p as u64 * 7919 + 17);
        let h = thread::Builder::new()
            .name(format!("client{p}"))
            .spawn(move || {
                if let Some(jt) = join_tick {
                    // Test harness only: connect about 1.5 s before the requested join tick.
                    while progress.load(Ordering::Relaxed) + 90 < jt {
                        thread::sleep(Duration::from_millis(5));
                    }
                }
                match sock {
                    Sock::Loop(s) => run_client(s, relay_addr_loop, prof, net_seed, seed, cfg),
                    Sock::Udp(s) => run_client(s, relay_addr_udp.unwrap(), prof, net_seed, seed, cfg),
                }
            })
            .map_err(|e| e.to_string())?;
        threads.push((p, h));
    }
    threads.sort_by_key(|(p, _)| *p);
    let mut clients = Vec::new();
    let mut errors = Vec::new();
    for (p, h) in threads {
        match h.join() {
            Ok(Ok(r)) => clients.push(r),
            Ok(Err(e)) => errors.push(format!("client {p}: {e}")),
            Err(_) => errors.push(format!("client {p} panicked")),
        }
    }
    let rep = match relay_thread.join() {
        Ok(Ok(r)) => r,
        Ok(Err(e)) => return Err(format!("{e}; {}", errors.join("; "))),
        Err(_) => return Err("relay panicked".into()),
    };
    if let Some(p) = a.str("log") {
        rep.log.write(Path::new(p)).map_err(|e| format!("{p}: {e}"))?;
    }
    if !errors.is_empty() {
        return Err(errors.join("; "));
    }
    // Cross-check: every client's verified checksums agree where they overlap.
    let mut agree = true;
    let reference: std::collections::HashMap<u32, u64> = clients
        .iter()
        .find(|c| c.join_tick.is_none())
        .map(|c| c.checksums.iter().copied().collect())
        .unwrap_or_default();
    for c in &clients {
        for (t, h) in &c.checksums {
            if reference.get(t).is_some_and(|r| r != h) {
                agree = false;
            }
        }
    }
    let ok = rep.desyncs == 0 && agree && clients.iter().all(|c| c.final_tick == ticks);
    Ok((
        Json::obj()
            .with("mode", "session")
            .with("transport", transport.as_str())
            .with("profile", a.str("profile").unwrap_or("ideal"))
            .with("ticks", ticks)
            .with("seed", seed)
            .with("desyncs", rep.desyncs)
            .with("checksums_agree", agree)
            .with("elapsed_ms", t0.elapsed().as_secs_f64() * 1e3)
            .with("relay", rep.json())
            .with("clients", Json::Arr(clients.iter().map(ClientReport::json).collect())),
        ok,
    ))
}

pub fn relay(a: &Args) -> Out {
    let port: u16 = a.req("port")?;
    let players: u8 = a.req("players")?;
    let ticks: u32 = a.req("ticks")?;
    let bind = a.str("bind").unwrap_or("127.0.0.1");
    let sock = UdpDatagram::bind((bind, port)).map_err(|e| format!("bind {bind}:{port}: {e}"))?;
    let cfg = RelayConfig {
        slots: players,
        initial_mask: ((1u32 << players.min(4)) - 1) as u8,
        ticks,
        seed: 1,
        tolerance: TOLERANCE,
        start_timeout: Duration::from_secs(120),
    };
    let t0 = Instant::now();
    let rep = run_relay(sock, &cfg, None)?;
    if let Some(p) = a.str("log") {
        rep.log.write(Path::new(p)).map_err(|e| format!("{p}: {e}"))?;
    }
    let ok = rep.desyncs == 0;
    Ok((rep.json().with("mode", "relay").with("elapsed_ms", t0.elapsed().as_secs_f64() * 1e3), ok))
}

pub fn client(a: &Args) -> Out {
    let connect: String = a.req("connect")?;
    let player: u8 = a.req("player")?;
    let ticks: u32 = a.req("ticks")?;
    let prof = profile(a)?;
    let addr: SocketAddr = connect
        .to_socket_addrs()
        .map_err(|e| format!("--connect {connect}: {e}"))?
        .next()
        .ok_or("--connect: no address")?;
    let bind = if addr.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
    let sock = UdpDatagram::bind(bind).map_err(|e| e.to_string())?;
    let cfg = ClientConfig::new(player);
    let rep = run_client(sock, addr, prof, 31 + player as u64, 1, cfg)?;
    let ok = rep.final_tick == ticks;
    Ok((rep.json(), ok))
}
