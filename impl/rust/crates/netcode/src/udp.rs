//! Datagrams over `std::net::UdpSocket` (non-blocking, polled).

use crate::transport::Datagram;
use std::io::ErrorKind;
use std::net::{SocketAddr, ToSocketAddrs, UdpSocket};

pub struct UdpDatagram {
    sock: UdpSocket,
    buf: Vec<u8>,
}

impl UdpDatagram {
    pub fn bind(addr: impl ToSocketAddrs) -> std::io::Result<UdpDatagram> {
        let sock = UdpSocket::bind(addr)?;
        sock.set_nonblocking(true)?;
        Ok(UdpDatagram { sock, buf: vec![0; 65536] })
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.sock.local_addr().expect("local_addr")
    }
}

impl Datagram for UdpDatagram {
    type Addr = SocketAddr;

    fn send_to(&mut self, to: SocketAddr, bytes: &[u8]) {
        // Unreliable by contract: a full socket buffer (WouldBlock) is a dropped datagram.
        let _ = self.sock.send_to(bytes, to);
    }

    fn recv_from(&mut self) -> Option<(SocketAddr, Vec<u8>)> {
        loop {
            match self.sock.recv_from(&mut self.buf) {
                Ok((n, from)) => return Some((from, self.buf[..n].to_vec())),
                Err(e) if e.kind() == ErrorKind::WouldBlock => return None,
                // Windows reports an ICMP "port unreachable" for an earlier send as WSAECONNRESET
                // on the next recv (also seen as ConnectionRefused on some stacks); it says nothing
                // about this datagram, so skip it and keep reading.
                Err(e) if matches!(e.kind(), ErrorKind::ConnectionReset | ErrorKind::ConnectionRefused) => continue,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(_) => return None,
            }
        }
    }
}
