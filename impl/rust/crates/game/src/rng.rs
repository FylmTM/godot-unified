/// xorshift32 (13, 17, 5). A zero seed becomes 1.
#[inline]
pub fn xorshift32(state: &mut u32) -> u32 {
    let mut x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    x
}

pub fn seed32(seed: u64) -> u32 {
    let s = seed as u32;
    if s == 0 { 1 } else { s }
}
