//! The macOS layer, or stand-ins that let the rest of the crate compile and
//! be checked on a Linux host. Only the macOS build is a product.

#[cfg(target_os = "macos")]
pub use crate::mac::*;

#[cfg(not(target_os = "macos"))]
mod stub {
    use futures::channel::mpsc::UnboundedSender;
    use gpui::Window;
    use std::path::Path;
    use std::time::Instant;

    pub struct Memory {
        pub resident: u64,
        pub footprint: u64,
    }

    pub fn register_hotkey(_: UnboundedSender<Instant>) -> Result<(), i32> {
        Err(-1)
    }
    pub fn post_synthetic_hotkey() -> Result<(), i32> {
        Err(-1)
    }
    pub fn become_accessory() {}
    pub fn show(_: &Window) {}
    pub fn fade_out(_: &Window) {}
    pub fn order_out(_: &Window) {}
    pub fn open(_: &Path) {}
    pub fn reveal(_: &Path) {}
    pub fn release_free_memory() {}
    pub fn memory() -> Option<Memory> {
        None
    }
}

#[cfg(not(target_os = "macos"))]
pub use stub::*;
