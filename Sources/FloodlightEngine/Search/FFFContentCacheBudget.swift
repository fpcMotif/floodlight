/// How much file content FFF may keep mapped between content searches.
///
/// Every content search maps the files it reads, and FFF keeps each mapping
/// until this budget runs out. Files past the budget are still searched; they
/// are read for that search and released afterwards. So the budget trades
/// resident memory for re-read cost and never changes which matches come back.
package struct FFFContentCacheBudget: Equatable, Sendable {
    /// Zero keeps FFF's default for that one cap. All three at zero is a
    /// different signal: FFF then sizes the whole budget from the scan.
    package var maxFiles: UInt64
    package var maxBytes: UInt64
    package var maxFileSize: UInt64

    /// FFF's own sizing: 128 MB once a root passes 50,000 files, and up to
    /// 512 MB for a small one. Fine for a project root an editor greps all day.
    package static let automatic = FFFContentCacheBudget(maxFiles: 0, maxBytes: 0, maxFileSize: 0)

    /// The launcher's file index roots at the home folder, so `automatic`
    /// lands on 128 MB that stays resident for as long as the app runs, for a
    /// grep capped at 35 ms and 16 rows. The kernel's page cache already makes
    /// re-reading a recently searched file cheap, so 16 MB keeps the hot set
    /// warm without holding the long tail.
    package static let launcher = FFFContentCacheBudget(
        maxFiles: 512,
        maxBytes: 16 * 1_024 * 1_024,
        maxFileSize: 0
    )
}
