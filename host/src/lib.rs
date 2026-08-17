//! C FFI for the Swift AppKit shell (bowser-browser-kid).
//!
//! Threading contract (servo 0.5.0 is Rc-based, !Send everywhere):
//! - Every `bowser_*` function MUST be called on the AppKit main thread,
//!   except none — the waker callback we *invoke* may fire on any thread,
//!   and Swift's waker must bounce to the main queue before calling
//!   `bowser_host_spin`.
//! - Swift callbacks fire *during* `spin_event_loop`; they must never call
//!   back into `bowser_*` synchronously (re-entrant spin) — always
//!   `DispatchQueue.main.async` first.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr::NonNull;
use std::rc::Rc;

use dpi::PhysicalSize;
use euclid::Scale;
use raw_window_handle::{
    AppKitDisplayHandle, AppKitWindowHandle, DisplayHandle, RawDisplayHandle, RawWindowHandle,
    WindowHandle,
};
use servo::{
    DevicePoint, InputEvent, Key, KeyState, KeyboardEvent, LoadStatus, MouseButton,
    MouseButtonAction, MouseButtonEvent, MouseMoveEvent, NamedKey, RenderingContext, Servo,
    ServoBuilder, WebView, WebViewBuilder, WebViewDelegate, WheelDelta, WheelEvent, WheelMode,
    WindowRenderingContext,
};
use url::Url;

pub type VoidCb = extern "C" fn(ctx: *mut c_void);
pub type StrCb = extern "C" fn(ctx: *mut c_void, value: *const c_char);
pub type U8Cb = extern "C" fn(ctx: *mut c_void, value: u8);

// ---------------------------------------------------------------------------
// Waker: the one legitimately cross-thread piece.

#[derive(Clone)]
struct CWaker {
    cb: VoidCb,
    ctx: *mut c_void,
}
// The Swift side guarantees ctx is either null or a process-lifetime pointer,
// and the callback only enqueues onto the main dispatch queue.
unsafe impl Send for CWaker {}
unsafe impl Sync for CWaker {}

impl embedder_traits::EventLoopWaker for CWaker {
    fn clone_box(&self) -> Box<dyn embedder_traits::EventLoopWaker> {
        Box::new(self.clone())
    }
    fn wake(&self) {
        (self.cb)(self.ctx);
    }
}

// ---------------------------------------------------------------------------
// Per-webview delegate forwarding to Swift.

struct SwiftDelegate {
    ctx: *mut c_void,
    on_frame_ready: VoidCb,
    on_url_change: StrCb,
    on_title_change: StrCb,
    on_load_status: U8Cb,
}

impl WebViewDelegate for SwiftDelegate {
    fn notify_new_frame_ready(&self, _webview: WebView) {
        (self.on_frame_ready)(self.ctx);
    }

    fn notify_url_changed(&self, _webview: WebView, url: Url) {
        if let Ok(s) = CString::new(url.to_string()) {
            (self.on_url_change)(self.ctx, s.as_ptr());
        }
    }

    fn notify_page_title_changed(&self, _webview: WebView, title: Option<String>) {
        if let Ok(s) = CString::new(title.unwrap_or_default()) {
            (self.on_title_change)(self.ctx, s.as_ptr());
        }
    }

    fn notify_load_status_changed(&self, _webview: WebView, status: LoadStatus) {
        let code = match status {
            LoadStatus::Started => 0,
            LoadStatus::HeadParsed => 1,
            LoadStatus::Complete => 2,
        };
        (self.on_load_status)(self.ctx, code);
    }
}

// ---------------------------------------------------------------------------
// Host state: main-thread only, hence thread_local.

struct Tab {
    webview: WebView,
    rendering_context: Rc<WindowRenderingContext>,
}

struct Host {
    servo: Servo,
    tabs: HashMap<u64, Tab>,
    next_id: u64,
}

thread_local! {
    static HOST: RefCell<Option<Host>> = const { RefCell::new(None) };
}

fn servo_handle() -> Option<Servo> {
    HOST.with(|h| h.borrow().as_ref().map(|host| host.servo.clone()))
}

/// Run `f` against the tab, drop all borrows, then spin the event loop
/// (every WebView call needs a spin to be processed).
fn with_tab<R>(id: u64, f: impl FnOnce(&Tab) -> R) -> Option<R> {
    let result = HOST.with(|h| {
        let borrow = h.borrow();
        borrow.as_ref().and_then(|host| host.tabs.get(&id)).map(f)
    });
    if result.is_some() {
        if let Some(servo) = servo_handle() {
            servo.spin_event_loop();
        }
    }
    result
}

// ---------------------------------------------------------------------------
// Lifecycle

#[no_mangle]
pub extern "C" fn bowser_host_init(wake_cb: VoidCb, wake_ctx: *mut c_void) -> bool {
    // Idempotent-ish: refuse double init.
    if HOST.with(|h| h.borrow().is_some()) {
        return false;
    }

    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

    let servo = ServoBuilder::default()
        .event_loop_waker(Box::new(CWaker {
            cb: wake_cb,
            ctx: wake_ctx,
        }))
        .build();
    servo.setup_logging();

    HOST.with(|h| {
        *h.borrow_mut() = Some(Host {
            servo,
            tabs: HashMap::new(),
            next_id: 1,
        })
    });
    true
}

#[no_mangle]
pub extern "C" fn bowser_host_spin() {
    if let Some(servo) = servo_handle() {
        servo.spin_event_loop();
    }
}

/// Blocks until servo shuts down. Call once, at app termination, after which
/// no other bowser_* call is valid.
#[no_mangle]
pub extern "C" fn bowser_host_shutdown() {
    let host = HOST.with(|h| h.borrow_mut().take());
    if let Some(host) = host {
        drop(host.tabs); // close all webviews first
        drop(host.servo); // blocks spinning until engine exit
    }
}

// ---------------------------------------------------------------------------
// WebView lifecycle

/// Returns a webview id, or 0 on failure. `url` may be null (blank view).
/// `ns_view` must be a live, layer-backed NSView on the main thread.
#[no_mangle]
pub extern "C" fn bowser_webview_create(
    ns_view: *mut c_void,
    width: u32,
    height: u32,
    hidpi: f32,
    url: *const c_char,
    cb_ctx: *mut c_void,
    on_frame_ready: VoidCb,
    on_url_change: StrCb,
    on_title_change: StrCb,
    on_load_status: U8Cb,
) -> u64 {
    let Some(ns_view) = NonNull::new(ns_view) else {
        return 0;
    };
    let Some(servo) = servo_handle() else {
        return 0;
    };

    let window_handle = unsafe {
        WindowHandle::borrow_raw(RawWindowHandle::AppKit(AppKitWindowHandle::new(ns_view)))
    };
    let display_handle = unsafe {
        DisplayHandle::borrow_raw(RawDisplayHandle::AppKit(AppKitDisplayHandle::new()))
    };

    let size = PhysicalSize::new(width.max(1), height.max(1));
    let rendering_context = match WindowRenderingContext::new(display_handle, window_handle, size) {
        Ok(context) => Rc::new(context),
        Err(error) => {
            eprintln!("bowser: WindowRenderingContext failed: {error:?}");
            return 0;
        }
    };
    let _ = rendering_context.make_current();

    let delegate = Rc::new(SwiftDelegate {
        ctx: cb_ctx,
        on_frame_ready,
        on_url_change,
        on_title_change,
        on_load_status,
    });

    let mut builder = WebViewBuilder::new(&servo, rendering_context.clone())
        .hidpi_scale_factor(Scale::new(hidpi))
        .delegate(delegate);
    if let Some(parsed) = parse_url(url) {
        builder = builder.url(parsed);
    }
    let webview = builder.build();
    webview.focus();
    webview.show();

    let id = HOST.with(|h| {
        let mut borrow = h.borrow_mut();
        let host = borrow.as_mut().expect("checked above");
        let id = host.next_id;
        host.next_id += 1;
        host.tabs.insert(
            id,
            Tab {
                webview,
                rendering_context,
            },
        );
        id
    });
    servo.spin_event_loop();
    id
}

#[no_mangle]
pub extern "C" fn bowser_webview_destroy(id: u64) {
    let tab = HOST.with(|h| {
        h.borrow_mut()
            .as_mut()
            .and_then(|host| host.tabs.remove(&id))
    });
    drop(tab); // WebView drop sends CloseWebView
    bowser_host_spin();
}

// ---------------------------------------------------------------------------
// Navigation / paint / geometry

#[no_mangle]
pub extern "C" fn bowser_webview_load(id: u64, url: *const c_char) {
    let Some(parsed) = parse_url(url) else { return };
    with_tab(id, |tab| tab.webview.load(parsed));
}

#[no_mangle]
pub extern "C" fn bowser_webview_reload(id: u64) {
    with_tab(id, |tab| tab.webview.reload());
}

#[no_mangle]
pub extern "C" fn bowser_webview_go_back(id: u64) {
    with_tab(id, |tab| {
        if tab.webview.can_go_back() {
            tab.webview.go_back(1);
        }
    });
}

#[no_mangle]
pub extern "C" fn bowser_webview_go_forward(id: u64) {
    with_tab(id, |tab| {
        if tab.webview.can_go_forward() {
            tab.webview.go_forward(1);
        }
    });
}

/// Paint the current frame and present it. Never call from inside a
/// Swift-side delegate callback without bouncing through the main queue.
#[no_mangle]
pub extern "C" fn bowser_webview_paint(id: u64) {
    with_tab(id, |tab| {
        tab.webview.paint();
        tab.rendering_context.present();
    });
}

#[no_mangle]
pub extern "C" fn bowser_webview_resize(id: u64, width: u32, height: u32) {
    with_tab(id, |tab| {
        tab.webview
            .resize(PhysicalSize::new(width.max(1), height.max(1)));
    });
}

// ---------------------------------------------------------------------------
// Input. Coordinates are device pixels, origin top-left of the view.

#[no_mangle]
pub extern "C" fn bowser_webview_mouse_move(id: u64, x: f32, y: f32) {
    with_tab(id, |tab| {
        tab.webview
            .notify_input_event(InputEvent::MouseMove(MouseMoveEvent::new(
                DevicePoint::new(x, y).into(),
            )));
    });
}

/// button: 0 left, 1 middle, 2 right. down: press vs release.
#[no_mangle]
pub extern "C" fn bowser_webview_mouse_button(id: u64, button: u8, down: bool, x: f32, y: f32) {
    let button = match button {
        0 => MouseButton::Left,
        1 => MouseButton::Middle,
        2 => MouseButton::Right,
        other => MouseButton::Other(other as u16),
    };
    let action = if down {
        MouseButtonAction::Down
    } else {
        MouseButtonAction::Up
    };
    with_tab(id, |tab| {
        tab.webview
            .notify_input_event(InputEvent::MouseButton(MouseButtonEvent::new(
                action,
                button,
                DevicePoint::new(x, y).into(),
            )));
    });
}

/// mode: 0 pixel deltas (precise/trackpad), 1 line deltas.
#[no_mangle]
pub extern "C" fn bowser_webview_wheel(id: u64, dx: f64, dy: f64, mode: u8, x: f32, y: f32) {
    let mode = if mode == 0 {
        WheelMode::DeltaPixel
    } else {
        WheelMode::DeltaLine
    };
    with_tab(id, |tab| {
        tab.webview
            .notify_input_event(InputEvent::Wheel(WheelEvent::new(
                WheelDelta {
                    x: dx,
                    y: dy,
                    z: 0.0,
                    mode,
                },
                DevicePoint::new(x, y).into(),
            )));
    });
}

/// `characters`: the NSEvent characters for printable input (may be null).
/// `keycode`: macOS virtual keycode, used for named keys.
#[no_mangle]
pub extern "C" fn bowser_webview_key(id: u64, down: bool, characters: *const c_char, keycode: u16) {
    let Some(key) = map_key(characters, keycode) else {
        return;
    };
    let state = if down { KeyState::Down } else { KeyState::Up };
    with_tab(id, |tab| {
        tab.webview
            .notify_input_event(InputEvent::Keyboard(KeyboardEvent::from_state_and_key(
                state, key,
            )));
    });
}

// ---------------------------------------------------------------------------
// Helpers

fn parse_url(url: *const c_char) -> Option<Url> {
    if url.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(url) }.to_str().ok()?;
    Url::parse(s).ok()
}

fn map_key(characters: *const c_char, keycode: u16) -> Option<Key> {
    // macOS virtual keycodes for keys whose NSEvent characters are control
    // chars or absent. Printable input falls through to Key::Character.
    let named = match keycode {
        36 | 76 => Some(NamedKey::Enter),
        48 => Some(NamedKey::Tab),
        51 => Some(NamedKey::Backspace),
        53 => Some(NamedKey::Escape),
        115 => Some(NamedKey::Home),
        116 => Some(NamedKey::PageUp),
        117 => Some(NamedKey::Delete),
        119 => Some(NamedKey::End),
        121 => Some(NamedKey::PageDown),
        123 => Some(NamedKey::ArrowLeft),
        124 => Some(NamedKey::ArrowRight),
        125 => Some(NamedKey::ArrowDown),
        126 => Some(NamedKey::ArrowUp),
        _ => None,
    };
    if let Some(named) = named {
        return Some(Key::Named(named));
    }

    if characters.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(characters) }.to_str().ok()?;
    if s.is_empty() || s.chars().any(|c| c.is_control()) {
        return None;
    }
    Some(Key::Character(s.to_string()))
}
