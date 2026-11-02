//! Everything that talks to macOS directly: the Carbon hotkey, the panel's
//! NSWindow, NSWorkspace, and the memory counters the bench reports.

use futures::channel::mpsc::UnboundedSender;
use gpui::Window;
use objc2::MainThreadMarker;
use objc2::rc::Retained;
use objc2_app_kit::{NSApplication, NSApplicationActivationPolicy, NSView, NSWindow, NSWorkspace};
use objc2_foundation::{NSArray, NSString, NSURL};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::ffi::c_void;
use std::path::Path;
use std::sync::OnceLock;
use std::time::Instant;

// Carbon is the only public API that registers a system-wide hotkey without
// the accessibility permission a CGEventTap needs. It is deprecated but still
// what every launcher ships.
mod carbon {
    use std::ffi::c_void;

    pub type OSStatus = i32;
    pub type EventRef = *mut c_void;
    pub type EventTargetRef = *mut c_void;
    pub type EventHandlerCallRef = *mut c_void;
    pub type Handler = extern "C" fn(EventHandlerCallRef, EventRef, *mut c_void) -> OSStatus;

    #[repr(C)]
    pub struct EventTypeSpec {
        pub event_class: u32,
        pub event_kind: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct EventHotKeyID {
        pub signature: u32,
        pub id: u32,
    }

    const fn four_cc(s: &[u8; 4]) -> u32 {
        u32::from_be_bytes(*s)
    }

    pub const K_EVENT_CLASS_KEYBOARD: u32 = four_cc(b"keyb");
    pub const K_EVENT_HOT_KEY_PRESSED: u32 = 5;
    pub const K_EVENT_PARAM_DIRECT_OBJECT: u32 = four_cc(b"----");
    pub const TYPE_EVENT_HOT_KEY_ID: u32 = four_cc(b"hkid");
    pub const OPTION_KEY: u32 = 1 << 11;
    pub const KVK_SPACE: u32 = 49;
    pub const SIGNATURE: u32 = four_cc(b"FLgp");

    #[link(name = "Carbon", kind = "framework")]
    unsafe extern "C" {
        pub fn GetApplicationEventTarget() -> EventTargetRef;
        pub fn InstallEventHandler(
            target: EventTargetRef,
            handler: Handler,
            num_types: usize,
            list: *const EventTypeSpec,
            user_data: *mut c_void,
            out_ref: *mut *mut c_void,
        ) -> OSStatus;
        pub fn RegisterEventHotKey(
            key_code: u32,
            modifiers: u32,
            id: EventHotKeyID,
            target: EventTargetRef,
            options: u32,
            out_ref: *mut *mut c_void,
        ) -> OSStatus;
        pub fn GetEventParameter(
            event: EventRef,
            name: u32,
            desired_type: u32,
            actual_type: *mut u32,
            buffer_size: usize,
            actual_size: *mut usize,
            data: *mut c_void,
        ) -> OSStatus;
        pub fn CreateEvent(
            allocator: *const c_void,
            class: u32,
            kind: u32,
            when: f64,
            flags: u32,
            out: *mut EventRef,
        ) -> OSStatus;
        pub fn SetEventParameter(event: EventRef, name: u32, ty: u32, size: usize, data: *const c_void) -> OSStatus;
        pub fn SendEventToEventTarget(event: EventRef, target: EventTargetRef) -> OSStatus;
        pub fn ReleaseEvent(event: EventRef);
    }
}

static HOTKEY: OnceLock<UnboundedSender<Instant>> = OnceLock::new();
const HOTKEY_ID: carbon::EventHotKeyID = carbon::EventHotKeyID {
    signature: carbon::SIGNATURE,
    id: 1,
};

extern "C" fn on_hotkey(_: carbon::EventHandlerCallRef, event: carbon::EventRef, _: *mut c_void) -> carbon::OSStatus {
    // Stamped first, so the measured latency includes everything after the
    // event reaches this process.
    let pressed = Instant::now();
    let mut id = carbon::EventHotKeyID::default();
    // SAFETY: `id` is a valid buffer of the size passed.
    let status = unsafe {
        carbon::GetEventParameter(
            event,
            carbon::K_EVENT_PARAM_DIRECT_OBJECT,
            carbon::TYPE_EVENT_HOT_KEY_ID,
            std::ptr::null_mut(),
            size_of::<carbon::EventHotKeyID>(),
            std::ptr::null_mut(),
            (&raw mut id).cast(),
        )
    };
    if status == 0
        && id.signature == HOTKEY_ID.signature
        && id.id == HOTKEY_ID.id
        && let Some(tx) = HOTKEY.get()
    {
        let _ = tx.unbounded_send(pressed);
    }
    0
}

/// Registers ⌥Space. ⌘Space stays Spotlight's unless the user moves it.
pub fn register_hotkey(tx: UnboundedSender<Instant>) -> Result<(), i32> {
    if HOTKEY.set(tx).is_err() {
        return Err(-1);
    }
    let spec = carbon::EventTypeSpec {
        event_class: carbon::K_EVENT_CLASS_KEYBOARD,
        event_kind: carbon::K_EVENT_HOT_KEY_PRESSED,
    };
    // SAFETY: plain Carbon calls with valid out-pointers; the handler is a
    // static function and the spec outlives the call.
    unsafe {
        let target = carbon::GetApplicationEventTarget();
        let status =
            carbon::InstallEventHandler(target, on_hotkey, 1, &spec, std::ptr::null_mut(), std::ptr::null_mut());
        if status != 0 {
            return Err(status);
        }
        let mut hotkey = std::ptr::null_mut();
        let status =
            carbon::RegisterEventHotKey(carbon::KVK_SPACE, carbon::OPTION_KEY, HOTKEY_ID, target, 0, &mut hotkey);
        if status != 0 {
            return Err(status);
        }
    }
    Ok(())
}

/// Delivers a hotkey event through the same Carbon handler a key press
/// reaches. Posting a real key needs the accessibility permission, which a CI
/// runner does not have; this measures everything from the handler on.
pub fn post_synthetic_hotkey() -> Result<(), i32> {
    // SAFETY: the event is created, filled, sent and released here; `id`
    // outlives the SetEventParameter call, which copies it.
    unsafe {
        let mut event = std::ptr::null_mut();
        let status = carbon::CreateEvent(
            std::ptr::null(),
            carbon::K_EVENT_CLASS_KEYBOARD,
            carbon::K_EVENT_HOT_KEY_PRESSED,
            0.0,
            0,
            &mut event,
        );
        if status != 0 {
            return Err(status);
        }
        let id = HOTKEY_ID;
        carbon::SetEventParameter(
            event,
            carbon::K_EVENT_PARAM_DIRECT_OBJECT,
            carbon::TYPE_EVENT_HOT_KEY_ID,
            size_of::<carbon::EventHotKeyID>(),
            (&raw const id).cast(),
        );
        let status = carbon::SendEventToEventTarget(event, carbon::GetApplicationEventTarget());
        carbon::ReleaseEvent(event);
        if status != 0 { Err(status) } else { Ok(()) }
    }
}

/// No Dock icon and no menu bar, without needing a bundle's LSUIElement.
pub fn become_accessory() {
    if let Some(mtm) = MainThreadMarker::new() {
        NSApplication::sharedApplication(mtm).setActivationPolicy(NSApplicationActivationPolicy::Accessory);
    }
}

fn ns_window(window: &Window) -> Option<Retained<NSWindow>> {
    let handle = HasWindowHandle::window_handle(window).ok()?;
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
        return None;
    };
    // SAFETY: GPUI's AppKit handle points at its live NSView, and this runs on
    // the main thread, where GPUI calls every window method.
    let view: &NSView = unsafe { appkit.ns_view.cast().as_ref() };
    view.window()
}

// objc2-app-kit marks these setters and NSWorkspace calls `unsafe` only
// because Apple's headers are not yet audited for them; each takes plain
// values and is documented safe on the main thread, where all of this runs.

pub fn show(window: &Window) {
    if let Some(w) = ns_window(window) {
        // SAFETY: see the note above.
        unsafe { w.setAlphaValue(1.0) };
        w.makeKeyAndOrderFront(None);
    }
}

/// Invisible at once, still ordered in so GPUI keeps drawing into it.
pub fn fade_out(window: &Window) {
    if let Some(w) = ns_window(window) {
        // SAFETY: see the note above.
        unsafe { w.setAlphaValue(0.0) };
    }
}

pub fn order_out(window: &Window) {
    if let Some(w) = ns_window(window) {
        w.orderOut(None);
    }
}

fn file_url(path: &Path) -> Retained<NSURL> {
    NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()))
}

pub fn open(path: &Path) {
    // SAFETY: see the note above.
    unsafe { NSWorkspace::sharedWorkspace().openURL(&file_url(path)) };
}

pub fn reveal(path: &Path) {
    let urls = NSArray::from_retained_slice(&[file_url(path)]);
    // SAFETY: see the note above.
    unsafe { NSWorkspace::sharedWorkspace().activateFileViewerSelectingURLs(&urls) };
}

unsafe extern "C" {
    fn malloc_zone_pressure_relief(zone: *mut c_void, goal: usize) -> usize;
    fn task_info(task: u32, flavor: i32, info: *mut i32, count: *mut u32) -> i32;
    static mach_task_self_: u32;
}

/// Hands free malloc pages back to the kernel. Without it, the rows and
/// layouts dropped on hide stay counted against the process until the
/// allocator decides to scavenge.
pub fn release_free_memory() {
    // SAFETY: a null zone means every zone; goal 0 means as much as possible.
    unsafe { malloc_zone_pressure_relief(std::ptr::null_mut(), 0) };
}

/// The prefix of `task_vm_info_data_t` through `phys_footprint`. The kernel
/// fills as many fields as the count allows, so the tail can be left off.
#[repr(C, packed(4))]
#[derive(Default)]
struct TaskVmInfo {
    virtual_size: u64,
    region_count: i32,
    page_size: i32,
    resident_size: u64,
    resident_size_peak: u64,
    device: u64,
    device_peak: u64,
    internal: u64,
    internal_peak: u64,
    external: u64,
    external_peak: u64,
    reusable: u64,
    reusable_peak: u64,
    purgeable_volatile_pmap: u64,
    purgeable_volatile_resident: u64,
    purgeable_volatile_virtual: u64,
    compressed: u64,
    compressed_peak: u64,
    compressed_lifetime: u64,
    phys_footprint: u64,
}

const TASK_VM_INFO: i32 = 22;

pub struct Memory {
    pub resident: u64,
    pub footprint: u64,
}

pub fn memory() -> Option<Memory> {
    let mut info = TaskVmInfo::default();
    let mut count = (size_of::<TaskVmInfo>() / size_of::<i32>()) as u32;
    // SAFETY: `info` has room for `count` natural_t words.
    let rc = unsafe { task_info(mach_task_self_, TASK_VM_INFO, (&raw mut info).cast(), &mut count) };
    (rc == 0).then_some(Memory {
        resident: info.resident_size,
        footprint: info.phys_footprint,
    })
}
