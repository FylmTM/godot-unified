//! In-process datagrams over std mpsc channels: one hub, one socket per thread.

use crate::transport::Datagram;
use std::collections::HashMap;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};

type Packet = (u32, Vec<u8>);
/// (last address handed out, address -> sender)
type Registry = (u32, HashMap<u32, Sender<Packet>>);

#[derive(Clone, Default)]
pub struct LoopbackHub {
    inner: Arc<Mutex<Registry>>,
}

impl LoopbackHub {
    pub fn new() -> LoopbackHub {
        LoopbackHub::default()
    }

    /// A new socket with a fresh address.
    pub fn socket(&self) -> LoopbackSocket {
        let (tx, rx) = channel();
        let mut g = self.inner.lock().unwrap();
        g.0 += 1;
        let id = g.0;
        g.1.insert(id, tx);
        LoopbackSocket { id, rx, hub: self.clone(), senders: HashMap::new() }
    }
}

pub struct LoopbackSocket {
    id: u32,
    rx: Receiver<Packet>,
    hub: LoopbackHub,
    senders: HashMap<u32, Sender<Packet>>,
}

impl LoopbackSocket {
    pub fn addr(&self) -> u32 {
        self.id
    }
}

impl Datagram for LoopbackSocket {
    type Addr = u32;

    fn send_to(&mut self, to: u32, bytes: &[u8]) {
        if !self.senders.contains_key(&to) {
            let Some(tx) = self.hub.inner.lock().unwrap().1.get(&to).cloned() else { return };
            self.senders.insert(to, tx);
        }
        let _ = self.senders[&to].send((self.id, bytes.to_vec()));
    }

    fn recv_from(&mut self) -> Option<(u32, Vec<u8>)> {
        self.rx.try_recv().ok()
    }
}
