//! Links `libfloodlight_core.a`, which `make gpui-core` builds with the pinned
//! Zig. Cargo does not build it: the Zig toolchain is pinned and verified by
//! scripts/install-zig.sh, and a second, unverified path to it would defeat
//! that.

use std::{env, path::PathBuf};

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let lib_dir = env::var_os("FLOODLIGHT_CORE_LIB_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest.join("../../../../.build/core/lib"));
    let archive = lib_dir.join("libfloodlight_core.a");
    if !archive.exists() {
        panic!(
            "{} is missing. Run `make gpui-core` from the repo root first.",
            archive.display()
        );
    }
    println!("cargo:rerun-if-changed={}", archive.display());
    println!("cargo:rerun-if-env-changed=FLOODLIGHT_CORE_LIB_DIR");
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=floodlight_core");
}
