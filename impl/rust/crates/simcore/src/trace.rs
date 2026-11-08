//! Per-tick checksum traces: one `"%06d %016x"` line per tick.

use std::fmt::Write as _;
use std::path::Path;

#[derive(Default)]
pub struct Trace {
    text: String,
}

impl Trace {
    pub fn push(&mut self, tick: u32, checksum: u64) {
        let _ = writeln!(self.text, "{tick:06} {checksum:016x}");
    }

    pub fn write(&self, path: &Path) -> std::io::Result<()> {
        std::fs::write(path, self.text.as_bytes())
    }
}

pub fn hex(checksum: u64) -> String {
    format!("{checksum:016x}")
}
