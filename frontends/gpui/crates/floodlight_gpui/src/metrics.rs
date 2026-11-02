//! Numbers the bench prints. Recorded from frame callbacks, read once at the
//! end, so a plain mutex is enough.

use std::sync::Mutex;
use std::time::Duration;

/// (frame built, next vsync) after each hotkey press that showed the panel.
static SHOWS: Mutex<Vec<(Duration, Duration)>> = Mutex::new(Vec::new());

pub fn record_show(built: Duration, presented: Duration) {
    SHOWS.lock().unwrap().push((built, presented));
}

pub fn take_shows() -> Vec<(Duration, Duration)> {
    std::mem::take(&mut SHOWS.lock().unwrap())
}

/// The value at quantile `q` (0..=1) of an unsorted sample, by nearest rank.
pub fn quantile(samples: &mut [Duration], q: f64) -> Duration {
    if samples.is_empty() {
        return Duration::ZERO;
    }
    samples.sort();
    let rank = ((samples.len() as f64 * q).ceil() as usize).clamp(1, samples.len());
    samples[rank - 1]
}

/// One `FLOODLIGHT_GPUI key=value` line, the shape CI greps into the job
/// summary, matching the Swift side's `FLOODLIGHT_BENCH` lines.
pub fn emit(key: &str, value: impl std::fmt::Display) {
    println!("FLOODLIGHT_GPUI {key}={value}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nearest_rank_quantiles() {
        let mut s: Vec<Duration> = [5, 1, 4, 2, 3].map(Duration::from_millis).to_vec();
        assert_eq!(quantile(&mut s, 0.5), Duration::from_millis(3));
        assert_eq!(quantile(&mut s, 0.95), Duration::from_millis(5));
        assert_eq!(quantile(&mut [], 0.5), Duration::ZERO);
    }
}
