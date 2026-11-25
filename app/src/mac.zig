//! Everything that talks to macOS past what nanoui covers: the global
//! hotkey, the glass slab behind the panel, NSWorkspace, the Full Disk
//! Access probe, System Settings' window, and a drag that carries a file.
const window = @import("mac/window.zig");
const pasteboard = @import("mac/pasteboard.zig");
const system = @import("mac/system.zig");

pub const setFrameOrigin = window.setFrameOrigin;
pub const frameOf = window.frameOf;
pub const orderFrontRegardless = window.orderFrontRegardless;
pub const signpostBegin = window.signpostBegin;
pub const signpostEnd = window.signpostEnd;
pub const keepLinkAtDisplayRate = window.keepLinkAtDisplayRate;
pub const setAlpha = window.setAlpha;
pub const installSlab = window.installSlab;
pub const mainScreenVisibleFrame = window.mainScreenVisibleFrame;
pub const pointerScreenVisibleFrame = window.pointerScreenVisibleFrame;
pub const systemSettingsWindow = window.systemSettingsWindow;
pub const releaseFreedMemory = window.releaseFreedMemory;
pub const releaseSurface = window.releaseSurface;
pub const forgetContextStorage = window.forgetContextStorage;
pub const drawBeforeOcclusionUpdate = window.drawBeforeOcclusionUpdate;

pub const writeClipboard = pasteboard.writeClipboard;
pub const pasteboardChangeCount = pasteboard.pasteboardChangeCount;
pub const PasteboardReader = pasteboard.PasteboardReader;
pub const pngBytes = pasteboard.pngBytes;
pub const compactImage = pasteboard.compactImage;
pub const previewVisible = pasteboard.previewVisible;
pub const togglePreview = pasteboard.togglePreview;
pub const previewFile = pasteboard.previewFile;
pub const relativeDate = pasteboard.relativeDate;
pub const detailedDate = pasteboard.detailedDate;

pub const HotKey = system.HotKey;
pub const registerHotKeys = system.registerHotKeys;
pub const handleReopen = system.handleReopen;
pub const becomeAccessory = system.becomeAccessory;
pub const open = system.open;
pub const copy = system.copy;
pub const reveal = system.reveal;
pub const RunningApp = system.RunningApp;
pub const frontmostApp = system.frontmostApp;
pub const ownPid = system.ownPid;
pub const canDeliverPaste = system.canDeliverPaste;
pub const promptAccessibility = system.promptAccessibility;
pub const deliverPaste = system.deliverPaste;
pub const MenuItem = system.MenuItem;
pub const command_modifier = system.command_modifier;
pub const popUpMenu = system.popUpMenu;
pub const full_disk_access_probe = system.full_disk_access_probe;
pub const fullDiskAccessGranted = system.fullDiskAccessGranted;
pub const openFullDiskAccessSettings = system.openFullDiskAccessSettings;
pub const bundlePath = system.bundlePath;
pub const iconPng = system.iconPng;
pub const retentionSeconds = system.retentionSeconds;
pub const FileDragSource = system.FileDragSource;
