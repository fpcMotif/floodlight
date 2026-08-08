/// The one decision every glass-vs-fallback seam reads: whether an element
/// should render Liquid Glass material or the frozen macOS 14/15 fallback.
///
/// `isSupported` is always the caller's own `#available(macOS 26.0, *)`
/// check — that part can't be unit tested, since it depends on the OS the
/// test happens to run on. Isolating it to a single boolean input means the
/// actual decision math (does Reduce Transparency override an available OS)
/// is pure and tested without needing two different real operating systems.
enum GlassAvailability {
    static func rendersGlass(isSupported: Bool, reduceTransparency: Bool) -> Bool {
        isSupported && !reduceTransparency
    }
}
