//! Spatial grid scratch (not part of the state): 2 m cells over the arena, counting sort of the
//! alive enemies, items within a cell in increasing index order.

use crate::consts::{ARENA, GRID};
use crate::state::{Enemies, MAX_ENEMIES};

const CELLS: usize = (GRID * GRID) as usize;

pub struct Grid {
    count: [u32; CELLS],
    start: [u32; CELLS],
    fill: [u32; CELLS],
    items: [u16; MAX_ENEMIES],
    cell_of: [u16; MAX_ENEMIES],
}

#[inline]
pub fn cell_coord(p: f32) -> i32 {
    let c = ((p + ARENA) * 0.5) as i32; // truncation toward zero (saturating)
    c.clamp(0, GRID - 1)
}

impl Grid {
    pub fn new_boxed() -> Box<Grid> {
        Box::new(Grid {
            count: [0; CELLS],
            start: [0; CELLS],
            fill: [0; CELLS],
            items: [0; MAX_ENEMIES],
            cell_of: [0; MAX_ENEMIES],
        })
    }

    pub fn build(&mut self, e: &Enemies) {
        self.count.fill(0);
        self.fill.fill(0);
        for i in 0..MAX_ENEMIES {
            if e.alive[i] != 0 {
                let c = (cell_coord(e.pz[i]) * GRID + cell_coord(e.px[i])) as usize;
                self.cell_of[i] = c as u16;
                self.count[c] += 1;
            }
        }
        let mut acc = 0;
        for c in 0..CELLS {
            self.start[c] = acc;
            acc += self.count[c];
        }
        for i in 0..MAX_ENEMIES {
            if e.alive[i] != 0 {
                let c = self.cell_of[i] as usize;
                self.items[(self.start[c] + self.fill[c]) as usize] = i as u16;
                self.fill[c] += 1;
            }
        }
    }

    /// Calls `f(j)` for every enemy in the 3x3 cells around (x, z): rows outer, columns inner,
    /// increasing index within a cell.
    #[inline]
    pub fn for_each_near(&self, x: f32, z: f32, mut f: impl FnMut(usize)) {
        let cx = cell_coord(x);
        let cz = cell_coord(z);
        for nz in (cz - 1).max(0)..=(cz + 1).min(GRID - 1) {
            for nx in (cx - 1).max(0)..=(cx + 1).min(GRID - 1) {
                let c = (nz * GRID + nx) as usize;
                let from = self.start[c] as usize;
                for &j in &self.items[from..from + self.count[c] as usize] {
                    f(j as usize);
                }
            }
        }
    }
}
