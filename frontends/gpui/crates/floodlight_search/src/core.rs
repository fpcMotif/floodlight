//! The Zig file index, through `core/include/floodlight_core.h`.
//!
//! The extern block is written by hand rather than generated: the header is
//! seven functions, and bindgen would add libclang to every build for them.
//! The layout test at the bottom is what keeps the two in step.

use std::ffi::{CStr, CString, c_char, c_int};
use std::path::{Path, PathBuf};
use std::ptr::NonNull;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Hit {
    pub id: u32,
    pub score: i32,
}

#[repr(C)]
struct RawIndex {
    _opaque: [u8; 0],
}

unsafe extern "C" {
    fn fl_index_build(root: *const c_char, out_path: *const c_char) -> c_int;
    fn fl_index_open(path: *const c_char, out: *mut *mut RawIndex) -> c_int;
    fn fl_index_close(index: *mut RawIndex);
    fn fl_index_count(index: *const RawIndex) -> u32;
    fn fl_search(index: *const RawIndex, query: *const c_char, out: *mut Hit, cap: u32) -> u32;
    fn fl_relative_path(index: *const RawIndex, id: u32, buf: *mut c_char, cap: u32) -> u32;
    fn fl_is_dir(index: *const RawIndex, id: u32) -> bool;
}

/// The most hits `fl_search` writes in one call.
pub const MAX_HITS: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoreError(pub i32);

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "floodlight-core error {}", self.0)
    }
}

impl std::error::Error for CoreError {}

fn c_path(path: &Path) -> Result<CString, CoreError> {
    use std::os::unix::ffi::OsStrExt;
    CString::new(path.as_os_str().as_bytes()).map_err(|_| CoreError(-22))
}

/// Scans `root` into an index file at `out`. Returns the entry count.
pub fn build(root: &Path, out: &Path) -> Result<u32, CoreError> {
    let (root, out) = (c_path(root)?, c_path(out)?);
    // SAFETY: both are valid NUL-terminated strings for the call's duration.
    let n = unsafe { fl_index_build(root.as_ptr(), out.as_ptr()) };
    if n < 0 { Err(CoreError(n)) } else { Ok(n as u32) }
}

/// An open, memory-mapped index. The header promises a handle is immutable
/// and safe to search from any number of threads, which is what makes the
/// `Send`/`Sync` impls sound.
pub struct Index {
    raw: NonNull<RawIndex>,
    root: PathBuf,
}

// SAFETY: see the type's doc comment and the header's threading contract.
unsafe impl Send for Index {}
// SAFETY: as above.
unsafe impl Sync for Index {}

impl Index {
    /// `root` is the folder the index was built from; hits are joined onto it.
    pub fn open(path: &Path, root: &Path) -> Result<Self, CoreError> {
        let path = c_path(path)?;
        let mut raw = std::ptr::null_mut();
        // SAFETY: `path` is NUL-terminated; `raw` is a valid out-pointer.
        let rc = unsafe { fl_index_open(path.as_ptr(), &mut raw) };
        match NonNull::new(raw) {
            Some(raw) if rc == 0 => Ok(Self {
                raw,
                root: root.to_path_buf(),
            }),
            _ => Err(CoreError(rc)),
        }
    }

    pub fn len(&self) -> u32 {
        // SAFETY: `raw` is a live handle until drop.
        unsafe { fl_index_count(self.raw.as_ptr()) }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Fills `out` best first and returns how many hits it wrote.
    pub fn search(&self, query: &str, out: &mut [Hit]) -> usize {
        let Ok(query) = CString::new(query) else { return 0 };
        let cap = out.len().min(MAX_HITS) as u32;
        // SAFETY: `out` has room for `cap` hits; the query is NUL-terminated.
        unsafe { fl_search(self.raw.as_ptr(), query.as_ptr(), out.as_mut_ptr(), cap) as usize }
    }

    pub fn path(&self, id: u32) -> Option<PathBuf> {
        let mut buf = [0 as c_char; 4096];
        // SAFETY: `buf` holds `buf.len()` bytes and the call NUL-terminates.
        let n = unsafe { fl_relative_path(self.raw.as_ptr(), id, buf.as_mut_ptr(), buf.len() as u32) };
        if n == 0 {
            return None;
        }
        // SAFETY: a non-zero return means `buf` holds a NUL-terminated string.
        let rel = unsafe { CStr::from_ptr(buf.as_ptr()) };
        Some(self.root.join(rel.to_str().ok()?))
    }

    pub fn is_dir(&self, id: u32) -> bool {
        // SAFETY: `raw` is live; out-of-range ids return false by contract.
        unsafe { fl_is_dir(self.raw.as_ptr(), id) }
    }
}

impl Drop for Index {
    fn drop(&mut self) {
        // SAFETY: the handle is closed exactly once, here.
        unsafe { fl_index_close(self.raw.as_ptr()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hit_layout_matches_the_header() {
        assert_eq!(std::mem::size_of::<Hit>(), 8);
        assert_eq!(std::mem::align_of::<Hit>(), 4);
    }

    #[test]
    fn build_open_search_round_trip() {
        let dir = std::env::temp_dir().join(format!("fl-gpui-core-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("Music/Albums")).unwrap();
        std::fs::write(dir.join("Music/Albums/kind-of-blue.flac"), b"").unwrap();
        let idx_path = std::env::temp_dir().join(format!("fl-gpui-core-{}.flix", std::process::id()));

        assert_eq!(build(&dir, &idx_path), Ok(3));
        let index = Index::open(&idx_path, &dir).unwrap();
        assert_eq!(index.len(), 3);
        let mut hits = [Hit::default(); 8];
        let n = index.search("blue", &mut hits);
        assert!(n >= 1);
        assert_eq!(
            index.path(hits[0].id).unwrap(),
            dir.join("Music/Albums/kind-of-blue.flac")
        );
        assert!(!index.is_dir(hits[0].id));

        drop(index);
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_file(&idx_path);
    }
}
