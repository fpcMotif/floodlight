//! Floodlight's GPUI frontend: a ⌥Space panel over app and file search.
//!
//! `floodlight-gpui` runs the panel. `--bench` runs it, drives it through the
//! real hotkey handler, prints `FLOODLIGHT_GPUI` lines, and quits.
//! `--bench-empty` does the same for a blank window: the floor GPUI itself
//! costs, before any of Floodlight is on top.

#[cfg(target_os = "macos")]
mod mac;
mod metrics;
mod panel;
mod platform;

use floodlight_search::{apps, core};
use futures::StreamExt;
use futures::channel::mpsc::{self, UnboundedReceiver};
use gpui::{
    App, AsyncApp, Bounds, Context, IntoElement, Render, Styled, Window, WindowBackgroundAppearance, WindowBounds,
    WindowHandle, WindowKind, WindowOptions, div, hsla, prelude::*, px, size,
};
use panel::Panel;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Run,
    Bench,
    BenchEmpty,
}

fn main() {
    let launched = Instant::now();
    let mode = match std::env::args().nth(1).as_deref() {
        Some("--bench") => Mode::Bench,
        Some("--bench-empty") => Mode::BenchEmpty,
        _ => Mode::Run,
    };
    gpui_platform::application().run(move |cx: &mut App| {
        platform::become_accessory();
        let (tx, rx) = mpsc::unbounded();
        let hotkey = platform::register_hotkey(tx);
        metrics::emit("hotkey_registered", hotkey.is_ok());
        if let Err(status) = hotkey {
            eprintln!("floodlight-gpui: ⌥Space registration failed ({status})");
        }
        if mode == Mode::BenchEmpty {
            bench_empty(rx, cx);
            return;
        }
        let handle = cx
            .open_window(window_options(cx), |_, cx| cx.new(Panel::new))
            .expect("open the panel window");
        load(handle, cx);
        listen(handle, rx, cx);
        if mode == Mode::Bench {
            bench(handle, launched, cx);
        }
    });
}

fn window_options(cx: &App) -> WindowOptions {
    let height = panel::QUERY_HEIGHT + panel::ROW_HEIGHT * panel::VISIBLE_ROWS as f32 + 8.;
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
            None,
            size(px(680.), px(height)),
            cx,
        ))),
        titlebar: None,
        focus: false,
        show: false,
        kind: WindowKind::PopUp,
        is_movable: false,
        is_resizable: false,
        is_minimizable: false,
        window_background: WindowBackgroundAppearance::Transparent,
        ..Default::default()
    }
}

/// Where the file index lives and what it covers. Both can be overridden so
/// the bench can point at a fixed tree.
fn file_index_location() -> (PathBuf, PathBuf) {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    let root = std::env::var_os("FLOODLIGHT_GPUI_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.clone());
    let index = std::env::var_os("FLOODLIGHT_GPUI_INDEX")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("Library/Caches/Floodlight/gpui-files.flix"));
    (root, index)
}

/// Apps first (a few hundred bundles, milliseconds), then the last index on
/// disk so search works at once, then a fresh scan that replaces it. There is
/// no FSEvents overlay yet (ADR 0010), so a launch is the refresh.
fn load(handle: WindowHandle<Panel>, cx: &mut App) {
    let (root, index_path) = file_index_location();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let bg = cx.background_executor().clone();
        let catalog = bg.spawn(async { apps::scan(&apps::default_roots()) }).await;
        metrics::emit("apps", catalog.len());
        let _ = handle.update(cx, |panel, _, _| panel.searcher.apps = Arc::new(catalog));

        if let Ok(stale) = core::Index::open(&index_path, &root) {
            let _ = handle.update(cx, |panel, _, _| panel.searcher.files = Some(Arc::new(stale)));
        }
        let started = Instant::now();
        let fresh = bg
            .spawn(async move {
                if let Some(dir) = index_path.parent() {
                    let _ = std::fs::create_dir_all(dir);
                }
                core::build(&root, &index_path).and_then(|_| core::Index::open(&index_path, &root))
            })
            .await;
        match fresh {
            Ok(index) => {
                metrics::emit("index_entries", index.len());
                metrics::emit("index_build_ms", started.elapsed().as_millis());
                let _ = handle.update(cx, |panel, _, _| panel.searcher.files = Some(Arc::new(index)));
            }
            Err(err) => eprintln!("floodlight-gpui: file index failed: {err}"),
        }
    })
    .detach();
}

fn listen(handle: WindowHandle<Panel>, mut presses: UnboundedReceiver<Instant>, cx: &mut App) {
    cx.spawn(async move |cx: &mut AsyncApp| {
        while let Some(pressed) = presses.next().await {
            if handle
                .update(cx, |panel, window, cx| panel.toggle(pressed, window, cx))
                .is_err()
            {
                break;
            }
        }
    })
    .detach();
}

async fn sleep(cx: &AsyncApp, duration: Duration) {
    cx.background_executor().timer(duration).await;
}

fn mib(bytes: u64) -> String {
    format!("{:.1}", bytes as f64 / (1024. * 1024.))
}

fn emit_memory(prefix: &str) {
    if let Some(memory) = platform::memory() {
        metrics::emit(&format!("{prefix}_rss_mb"), mib(memory.resident));
        metrics::emit(&format!("{prefix}_footprint_mb"), mib(memory.footprint));
    }
}

fn emit_binary_size() {
    if let Some(len) = std::env::current_exe()
        .ok()
        .and_then(|p| std::fs::metadata(p).ok())
        .map(|m| m.len())
    {
        metrics::emit("binary_mb", mib(len));
    }
}

/// How long the panel sits hidden before memory is sampled, per the issue.
const IDLE: Duration = Duration::from_secs(10);

struct Blank;

impl Render for Blank {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().bg(hsla(0., 0., 0.13, 1.))
    }
}

/// Step 0 of the plan: a blank borderless window, shown and hidden through
/// the hotkey handler, then left idle.
fn bench_empty(mut presses: UnboundedReceiver<Instant>, cx: &mut App) {
    let handle = cx
        .open_window(window_options(cx), |_, cx| cx.new(|_| Blank))
        .expect("open the blank window");
    cx.spawn(async move |cx: &mut AsyncApp| {
        let mut visible = false;
        for _ in 0..2 {
            sleep(cx, Duration::from_millis(500)).await;
            let posted = platform::post_synthetic_hotkey();
            metrics::emit("synthetic_hotkey_posted", posted.is_ok());
            let Some(pressed) = presses.next().await else { break };
            visible = !visible;
            let _ = handle.update(cx, |_, window, _| {
                if visible {
                    platform::show(window);
                    window.refresh();
                    window.on_next_frame(move |_, _| {
                        metrics::emit("empty_first_frame_us", pressed.elapsed().as_micros())
                    });
                } else {
                    platform::order_out(window);
                }
            });
            sleep(cx, Duration::from_millis(500)).await;
        }
        sleep(cx, IDLE).await;
        emit_memory("empty_idle");
        emit_binary_size();
        cx.update(|cx| cx.quit());
    })
    .detach();
}

const QUERIES: &[&str] = &[
    "s",
    "sa",
    "saf",
    "safari",
    "te",
    "term",
    "read",
    "readme",
    "mak",
    "makefile",
    "pack swift",
    "doc",
    "notes",
    "xc",
    "xcode",
    "conf",
    "json",
    "png",
    "lib/x",
    "zz",
];
const WARMUP: usize = 3;
const SHOWS: usize = 20;

/// The full panel, driven the way a person drives it: hotkey, type, Esc.
fn bench(handle: WindowHandle<Panel>, launched: Instant, cx: &mut App) {
    cx.spawn(async move |cx: &mut AsyncApp| {
        loop {
            let ready = handle
                .update(cx, |panel, _, _| {
                    !panel.searcher.apps.is_empty() && panel.searcher.files.is_some()
                })
                .unwrap_or(false);
            if ready {
                break;
            }
            sleep(cx, Duration::from_millis(20)).await;
        }
        // The bench needs the fresh index, not a stale one from a last run.
        sleep(cx, Duration::from_millis(200)).await;
        metrics::emit("launch_to_searchable_ms", launched.elapsed().as_millis());

        for _ in 0..WARMUP + SHOWS {
            let _ = platform::post_synthetic_hotkey();
            sleep(cx, Duration::from_millis(250)).await;
            for query in ["r", "re", "rea", "read"] {
                let _ = handle.update(cx, |panel, _, cx| panel.set_query(query.to_owned(), cx));
                sleep(cx, Duration::from_millis(30)).await;
            }
            let _ = handle.update(cx, |panel, window, cx| panel.hide(window, cx));
            sleep(cx, Duration::from_millis(250)).await;
        }
        let shows = metrics::take_shows();
        metrics::emit("shows_recorded", shows.len());
        let shows = &shows[shows.len().min(WARMUP)..];
        let mut built: Vec<Duration> = shows.iter().map(|s| s.0).collect();
        let mut presented: Vec<Duration> = shows.iter().map(|s| s.1).collect();
        metrics::emit(
            "hotkey_to_frame_built_p50_us",
            metrics::quantile(&mut built, 0.5).as_micros(),
        );
        metrics::emit(
            "hotkey_to_frame_built_p95_us",
            metrics::quantile(&mut built, 0.95).as_micros(),
        );
        metrics::emit(
            "hotkey_to_next_vsync_p50_us",
            metrics::quantile(&mut presented, 0.5).as_micros(),
        );
        metrics::emit(
            "hotkey_to_next_vsync_p95_us",
            metrics::quantile(&mut presented, 0.95).as_micros(),
        );

        let mut times = handle
            .update(cx, |panel, _, _| {
                let mut times = Vec::with_capacity(QUERIES.len() * 10);
                for _ in 0..10 {
                    for query in QUERIES {
                        let started = Instant::now();
                        std::hint::black_box(panel.searcher.search(query));
                        times.push(started.elapsed());
                    }
                }
                times
            })
            .unwrap_or_default();
        metrics::emit("query_p50_us", metrics::quantile(&mut times, 0.5).as_micros());
        metrics::emit("query_p95_us", metrics::quantile(&mut times, 0.95).as_micros());

        let visible = handle.update(cx, |panel, _, _| panel.is_visible()).unwrap_or(false);
        metrics::emit("hidden_before_idle", !visible);
        sleep(cx, IDLE).await;
        emit_memory("idle");
        emit_binary_size();
        cx.update(|cx| cx.quit());
    })
    .detach();
}
