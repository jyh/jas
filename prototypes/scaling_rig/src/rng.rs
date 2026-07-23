//! Deterministic, seeded pseudo-randomness and hashing.
//!
//! Scene content MUST be a pure function of the seed: no `Instant::now`, no OS
//! entropy, no thread-timing. This module provides a SplitMix64 generator (fast,
//! well-distributed, trivially reproducible) and an FNV-1a digest so the
//! determinism test can assert "same seed twice => identical scene".

/// SplitMix64 — a tiny, fully deterministic PRNG.
///
/// Reference algorithm (public domain, Vigna). Chosen over `rand` so the rig
/// carries no RNG dependency and the byte-for-byte sequence is pinned here.
#[derive(Clone)]
pub struct Rng {
    state: u64,
}

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    #[inline]
    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform f64 in [0, 1).
    #[inline]
    pub fn unit(&mut self) -> f64 {
        // Take the top 53 bits for a double with full mantissa precision.
        (self.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    }

    /// Uniform f64 in [lo, hi).
    #[inline]
    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.unit()
    }

    /// Uniform integer in [lo, hi) (hi exclusive). `hi` must be > `lo`.
    #[inline]
    pub fn range_u32(&mut self, lo: u32, hi: u32) -> u32 {
        lo + (self.next_u64() % (hi - lo) as u64) as u32
    }

    /// True with probability `p`.
    #[inline]
    pub fn chance(&mut self, p: f64) -> bool {
        self.unit() < p
    }

    /// A random opaque-ish RGBA in u8, alpha biased toward opaque.
    #[inline]
    pub fn rgba(&mut self) -> [u8; 4] {
        let r = self.range_u32(20, 240) as u8;
        let g = self.range_u32(20, 240) as u8;
        let b = self.range_u32(20, 240) as u8;
        // Mostly opaque, occasionally translucent (exercises the blend path).
        let a = if self.chance(0.2) {
            self.range_u32(60, 200) as u8
        } else {
            255
        };
        [r, g, b, a]
    }
}

/// FNV-1a 64-bit digest. Deterministic across processes and platforms (unlike
/// `DefaultHasher`, whose keys, while fixed today, are not a stability guarantee).
pub struct Fnv {
    hash: u64,
}

impl Default for Fnv {
    fn default() -> Self {
        Self {
            hash: 0xcbf2_9ce4_8422_2325,
        }
    }
}

impl Fnv {
    #[inline]
    pub fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.hash ^= b as u64;
            self.hash = self.hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }

    #[inline]
    pub fn write_f64(&mut self, v: f64) {
        // Hash the bit pattern; identical arithmetic yields identical bits.
        self.write(&v.to_bits().to_le_bytes());
    }

    #[inline]
    pub fn finish(&self) -> u64 {
        self.hash
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splitmix_is_reproducible() {
        let mut a = Rng::new(12345);
        let mut b = Rng::new(12345);
        for _ in 0..1000 {
            assert_eq!(a.next_u64(), b.next_u64());
        }
    }

    #[test]
    fn different_seeds_diverge() {
        let mut a = Rng::new(1);
        let mut b = Rng::new(2);
        // Vanishingly unlikely to collide across 100 draws if seeds differ.
        let mut same = 0;
        for _ in 0..100 {
            if a.next_u64() == b.next_u64() {
                same += 1;
            }
        }
        assert!(same < 5);
    }

    #[test]
    fn unit_in_range() {
        let mut r = Rng::new(7);
        for _ in 0..10_000 {
            let u = r.unit();
            assert!((0.0..1.0).contains(&u));
        }
    }
}
