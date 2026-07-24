//! QueryPerformanceCounter tick <-> microsecond conversion.
//!
//! Windows reports the input hardware timestamp (`POINTER_INFO.PerformanceCount`)
//! and wall-clock reads (`QueryPerformanceCounter`) in the SAME tick domain,
//! whose rate is `QueryPerformanceFrequency` (ticks/second, fixed for the boot).
//! This module is the pure, platform-independent conversion so the whole
//! ledger + stats + report layer is testable on ANY host (the Mac `cargo test`),
//! with the frequency supplied as data rather than read from the OS.

/// A fixed QPC tick rate (ticks per second). Cheap to copy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct QpcClock {
    freq: i64,
}

impl QpcClock {
    /// `freq` is `QueryPerformanceFrequency` (ticks/second). Must be > 0.
    ///
    /// Panics on a non-positive frequency: a zero or negative QPC frequency is
    /// not a value we can meaningfully divide by, and the OS never legitimately
    /// reports one, so it is a programmer/environment error, not a data case.
    pub fn from_frequency(freq: i64) -> Self {
        assert!(freq > 0, "QPC frequency must be positive, got {freq}");
        Self { freq }
    }

    /// The tick rate (ticks/second) this clock was built with.
    #[inline]
    pub fn frequency(&self) -> i64 {
        self.freq
    }

    /// Convert a tick delta to microseconds (f64, no rounding).
    #[inline]
    pub fn ticks_to_micros(&self, ticks: i64) -> f64 {
        ticks as f64 * 1_000_000.0 / self.freq as f64
    }

    /// Duration in microseconds between two QPC reads, from `start` to `end`.
    ///
    /// Returns `None` if `end < start` — a backwards reading. That can happen if
    /// the hardware timestamp and our `QueryPerformanceCounter` read sit in
    /// subtly different domains, or a driver reports a bogus `PerformanceCount`;
    /// we refuse to report a negative interval as a real latency.
    #[inline]
    pub fn duration_us(&self, start: i64, end: i64) -> Option<f64> {
        if end < start {
            return None;
        }
        Some(self.ticks_to_micros(end - start))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 10 MHz is the canonical modern-x86 QPC rate; the conversions are exact.
    const TEN_MHZ: i64 = 10_000_000;

    #[test]
    fn one_second_of_ticks_is_a_million_micros() {
        let c = QpcClock::from_frequency(TEN_MHZ);
        assert_eq!(c.ticks_to_micros(TEN_MHZ), 1_000_000.0);
    }

    #[test]
    fn eight_ms_at_ten_mhz() {
        // 80_000 ticks / 10 MHz = 8_000 us = 8 ms — the verdict's headline unit.
        let c = QpcClock::from_frequency(TEN_MHZ);
        assert_eq!(c.ticks_to_micros(80_000), 8_000.0);
    }

    #[test]
    fn non_ten_mhz_frequency_still_exact() {
        // ARM Windows commonly runs QPC at 19.2 MHz; 19_200 ticks = 1 ms.
        let c = QpcClock::from_frequency(19_200_000);
        assert_eq!(c.ticks_to_micros(19_200), 1_000.0);
    }

    #[test]
    fn duration_forward_is_some() {
        let c = QpcClock::from_frequency(TEN_MHZ);
        assert_eq!(c.duration_us(1_000, 1_000 + 80_000), Some(8_000.0));
    }

    #[test]
    fn duration_zero_span_is_zero() {
        let c = QpcClock::from_frequency(TEN_MHZ);
        assert_eq!(c.duration_us(500, 500), Some(0.0));
    }

    #[test]
    fn duration_backwards_is_none() {
        let c = QpcClock::from_frequency(TEN_MHZ);
        assert_eq!(c.duration_us(1_000, 900), None);
    }

    #[test]
    #[should_panic]
    fn zero_frequency_panics() {
        let _ = QpcClock::from_frequency(0);
    }
}
