//! Clipboard history: what was copied, classified as the Swift board does,
//! kept in SQLite beside the file index.
pub const model = @import("clipboard/model.zig");
pub const store = @import("clipboard/store.zig");

pub const Kind = model.Kind;
pub const Content = model.Content;
pub const QueryScope = model.QueryScope;
pub const Entry = model.Entry;
pub const isSensitiveSource = model.isSensitiveSource;
pub const classify = model.classify;
pub const domain = model.domain;
pub const Rgba = model.Rgba;
pub const rgbDescription = model.rgbDescription;
pub const age = model.age;
pub const Filter = model.Filter;
pub const fileType = model.fileType;
pub const image_extensions = model.image_extensions;
pub const board_image_extensions = model.board_image_extensions;
pub const video_extensions = model.video_extensions;
pub const text_extensions = model.text_extensions;
pub const extension = model.extension;
pub const inSet = model.inSet;
pub const TextCounts = model.TextCounts;
pub const counts = model.counts;
pub const Capture = model.Capture;
pub const own_write_type = model.own_write_type;
pub const PastedImage = model.PastedImage;
pub const Pasteboard = model.Pasteboard;
pub const App = model.App;
pub const Facts = model.Facts;
pub const facts = model.facts;
pub const Payload = model.Payload;
pub const text_preview_bytes = model.text_preview_bytes;
pub const max_text_bytes = model.max_text_bytes;
pub const max_file_count = model.max_file_count;
pub const max_image_bytes = model.max_image_bytes;
pub const retention_days = model.retention_days;
pub const compact_after_days = model.compact_after_days;
pub const search_limit = model.search_limit;
pub const wallClock = model.wallClock;
pub const Clock = model.Clock;

pub const Budget = store.Budget;
pub const Compactor = store.Compactor;
pub const Compaction = store.Compaction;
pub const recompress = store.recompress;
pub const Store = store.Store;
