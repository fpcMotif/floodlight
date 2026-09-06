import Darwin
import Foundation

/// The one place the suite's wall-clock numbers are tuned.
///
/// Every polling helper and every "this stayed fast enough" assertion in the
/// tests is a bet about how slow the machine underneath is allowed to get.
/// A sanitizer build loses that bet: ThreadSanitizer instruments every memory
/// access, so a loop budgeted at 2s measured 2.98s and a dozen coordinator
/// tests timed out waiting for work that does land, just later. Raising the
/// numbers for everyone would trade those false failures for a real hang
/// taking four times as long to report, so the ordinary budgets stay exactly
/// where they are and only a sanitized process gets the headroom.
///
/// Call sites keep writing the number they mean on an ordinary build — the
/// scaling happens here, so there is one factor to change rather than one per
/// test file.
package enum TestBudget {
    /// Whether this process was built with ThreadSanitizer or
    /// AddressSanitizer.
    ///
    /// Detected by looking for the sanitizer runtime rather than by reading
    /// an environment variable the test scripts would have to set: a bare
    /// `swift test --sanitize=thread` then gets the same budgets
    /// `make test-thread-sanitizer` does, and nothing can go stale.
    package static let isSanitizing: Bool = {
        // RTLD_DEFAULT — a #define'd cast that Swift cannot import.
        let anyLoadedImage = UnsafeMutableRawPointer(bitPattern: -2)
        let runtimes: [String] = ["__tsan_init", "__asan_init"]
        return runtimes.contains { symbol in dlsym(anyLoadedImage, symbol) != nil }
    }()

    /// What a sanitized run multiplies every budget by.
    ///
    /// Measured slowdowns are closer to 1.5×; the margin above that is
    /// deliberate, because a budget only costs time when it is *not* met and
    /// a test that passes returns as soon as its condition holds.
    package static let scale: Double = isSanitizing ? 4 : 1

    /// `seconds` on an ordinary build, proportionally more under a sanitizer.
    package static func seconds(_ seconds: TimeInterval) -> TimeInterval {
        seconds * scale
    }

    /// The `Duration` form, for elapsed-time assertions and for the scripted
    /// delays that hold a transient window open long enough to observe.
    package static func duration(_ duration: Duration) -> Duration {
        duration * scale
    }
}
