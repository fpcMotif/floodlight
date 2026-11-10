//! The search panel: a query line over a result list.
//!
//! The panel owns what it shows and nothing else. Hiding it drops the query,
//! the rows, and (by drawing empty frames before the window leaves the screen)
//! GPUI's per-frame text layouts, so a hidden panel holds no per-query state.

use crate::{metrics, platform};
use floodlight_search::{Kind, Row, Searcher};
use gpui::{
    Context, FocusHandle, Hsla, IntoElement, KeyDownEvent, ParentElement, Render, SharedString, Styled, Window,
    WindowAppearance, div, hsla, prelude::*, px,
};
use std::time::Instant;

/// Rows on screen at once; the list scrolls to keep the selection in view.
pub const VISIBLE_ROWS: usize = 9;
pub const ROW_HEIGHT: f32 = 44.;
pub const QUERY_HEIGHT: f32 = 56.;

/// Frames drawn with an empty tree after hiding. GPUI's line-layout cache
/// keeps the current and the previous frame, so two empty frames clear both;
/// the third callback is the one that orders the window out.
const DRAIN_FRAMES: usize = 2;

pub struct Panel {
    focus: FocusHandle,
    pub searcher: Searcher,
    query: String,
    rows: Vec<Row>,
    selected: usize,
    visible: bool,
    shown_at: Option<Instant>,
}

impl Panel {
    pub fn new(cx: &mut Context<Self>) -> Self {
        Self {
            focus: cx.focus_handle(),
            searcher: Searcher::default(),
            query: String::new(),
            rows: Vec::new(),
            selected: 0,
            visible: false,
            shown_at: None,
        }
    }

    pub fn is_visible(&self) -> bool {
        self.visible
    }

    /// `pressed` is when the hotkey reached the process; the first frame
    /// after it is what the latency metric measures.
    pub fn toggle(&mut self, pressed: Instant, window: &mut Window, cx: &mut Context<Self>) {
        if self.visible {
            self.hide(window, cx);
        } else {
            self.show(pressed, window, cx);
        }
    }

    pub fn show(&mut self, pressed: Instant, window: &mut Window, cx: &mut Context<Self>) {
        self.visible = true;
        self.shown_at = Some(pressed);
        platform::show(window);
        window.focus(&self.focus, cx);
        cx.notify();
    }

    pub fn hide(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.visible {
            return;
        }
        self.visible = false;
        self.shown_at = None;
        // Fresh values, not `clear()`: clearing keeps the capacity.
        self.query = String::new();
        self.rows = Vec::new();
        self.selected = 0;
        platform::fade_out(window);
        cx.notify();
        drain_then_order_out(window, DRAIN_FRAMES);
    }

    pub fn set_query(&mut self, query: String, cx: &mut Context<Self>) {
        self.query = query;
        self.rows = self.searcher.search(&self.query);
        self.selected = 0;
        cx.notify();
    }

    fn key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;
        let command = keystroke.modifiers.platform;
        match keystroke.key.as_str() {
            "escape" => self.hide(window, cx),
            "up" => self.move_selection(-1, cx),
            "down" => self.move_selection(1, cx),
            "enter" => {
                if let Some(row) = self.rows.get(self.selected) {
                    if command {
                        platform::reveal(&row.path);
                    } else {
                        platform::open(&row.path);
                    }
                    self.hide(window, cx);
                }
            }
            "backspace" => {
                let mut query = std::mem::take(&mut self.query);
                if command {
                    query.clear();
                } else {
                    query.pop();
                }
                self.set_query(query, cx);
            }
            _ => {
                if command || keystroke.modifiers.control {
                    return;
                }
                if let Some(text) = &keystroke.key_char {
                    let query = format!("{}{text}", self.query);
                    self.set_query(query, cx);
                }
            }
        }
    }

    fn move_selection(&mut self, delta: isize, cx: &mut Context<Self>) {
        if self.rows.is_empty() {
            return;
        }
        let last = self.rows.len() - 1;
        self.selected = self.selected.saturating_add_signed(delta).min(last);
        cx.notify();
    }
}

/// Each hop waits one frame; the last orders the window out and hands freed
/// pages back. Until then the window is transparent but still drawing.
fn drain_then_order_out(window: &mut Window, frames: usize) {
    window.on_next_frame(move |window, cx| {
        if frames == 0 {
            platform::order_out(window);
            platform::release_free_memory();
        } else {
            window.refresh();
            drain_then_order_out(window, frames - 1);
        }
        let _ = cx;
    });
}

struct Palette {
    background: Hsla,
    primary: Hsla,
    secondary: Hsla,
    placeholder: Hsla,
    selection: Hsla,
    separator: Hsla,
}

fn palette(appearance: WindowAppearance) -> Palette {
    match appearance {
        WindowAppearance::Dark | WindowAppearance::VibrantDark => Palette {
            background: hsla(0., 0., 0.13, 0.98),
            primary: hsla(0., 0., 0.95, 1.),
            secondary: hsla(0., 0., 0.65, 1.),
            placeholder: hsla(0., 0., 0.45, 1.),
            selection: hsla(0.6, 0.8, 0.5, 0.35),
            separator: hsla(0., 0., 1., 0.08),
        },
        _ => Palette {
            background: hsla(0., 0., 0.98, 0.98),
            primary: hsla(0., 0., 0.08, 1.),
            secondary: hsla(0., 0., 0.4, 1.),
            placeholder: hsla(0., 0., 0.6, 1.),
            selection: hsla(0.6, 0.8, 0.55, 0.25),
            separator: hsla(0., 0., 0., 0.08),
        },
    }
}

fn kind_label(kind: Kind) -> &'static str {
    match kind {
        Kind::App => "App",
        Kind::File => "File",
        Kind::Folder => "Folder",
    }
}

impl Render for Panel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if !self.visible {
            return div().into_any_element();
        }
        if let Some(pressed) = self.shown_at.take() {
            let built = pressed.elapsed();
            // Next-frame callbacks run at the following vsync, after this
            // frame was handed to the compositor: an upper bound on "on
            // screen".
            window.on_next_frame(move |_, _| metrics::record_show(built, pressed.elapsed()));
        }

        let colors = palette(window.appearance());
        let first = self.selected.saturating_sub(VISIBLE_ROWS - 1);
        let rows = self
            .rows
            .iter()
            .enumerate()
            .skip(first)
            .take(VISIBLE_ROWS)
            .map(|(i, row)| {
                let selected = i == self.selected;
                div()
                    .h(px(ROW_HEIGHT))
                    .px_4()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .when(selected, |d| d.bg(colors.selection).rounded_md())
                    .child(
                        div()
                            .w(px(44.))
                            .text_xs()
                            .text_color(colors.secondary)
                            .child(kind_label(row.kind)),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .overflow_hidden()
                            .child(
                                div()
                                    .text_color(colors.primary)
                                    .child(SharedString::from(row.title.clone())),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(colors.secondary)
                                    .child(SharedString::from(row.subtitle.clone())),
                            ),
                    )
            });

        let query = if self.query.is_empty() {
            div().text_color(colors.placeholder).child("Search apps and files")
        } else {
            div()
                .text_color(colors.primary)
                .child(SharedString::from(self.query.clone()))
        };

        div()
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::key_down))
            .size_full()
            .flex()
            .flex_col()
            .bg(colors.background)
            .rounded_xl()
            .overflow_hidden()
            .child(
                div()
                    .h(px(QUERY_HEIGHT))
                    .px_5()
                    .flex()
                    .items_center()
                    .text_xl()
                    .border_b_1()
                    .border_color(colors.separator)
                    .child(query),
            )
            .child(div().p_1().flex().flex_col().children(rows))
            .into_any_element()
    }
}
