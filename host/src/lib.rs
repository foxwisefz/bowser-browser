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

mod brain;

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
use embedder_traits::user_contents::UserStyleSheet;
use servo::{
    ConsoleLogLevel, DevicePoint, InputEvent, JSValue, Key, KeyState, KeyboardEvent, LoadStatus,
    MouseButton, MouseButtonAction, MouseButtonEvent, MouseMoveEvent, NamedKey, RenderingContext,
    Servo, ServoBuilder, UserContentManager, UserScript, WebView, WebViewBuilder, WebViewDelegate,
    WheelDelta, WheelEvent, WheelMode, WindowRenderingContext,
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
    id: u64,
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
        brain::send(&serde_json::json!({
            "op": "event", "event": "url_changed",
            "webview": self.id, "url": url.to_string(),
        }));
    }

    fn notify_page_title_changed(&self, _webview: WebView, title: Option<String>) {
        let title = title.unwrap_or_default();
        if let Ok(s) = CString::new(title.clone()) {
            (self.on_title_change)(self.ctx, s.as_ptr());
        }
        brain::send(&serde_json::json!({
            "op": "event", "event": "title_changed",
            "webview": self.id, "title": title,
        }));
    }

    fn notify_load_status_changed(&self, _webview: WebView, status: LoadStatus) {
        let code = match status {
            LoadStatus::Started => 0,
            LoadStatus::HeadParsed => 1,
            LoadStatus::Complete => 2,
        };
        (self.on_load_status)(self.ctx, code);
        brain::send(&serde_json::json!({
            "op": "event", "event": "load_status",
            "webview": self.id, "status": code,
        }));
    }

    fn show_console_message(&self, _webview: WebView, level: ConsoleLogLevel, message: String) {
        brain::send(&serde_json::json!({
            "op": "event", "event": "console",
            "webview": self.id,
            "level": format!("{level:?}").to_lowercase(),
            "message": message,
        }));
    }
}

// ---------------------------------------------------------------------------
// Host state: main-thread only, hence thread_local.

struct Tab {
    webview: WebView,
    rendering_context: Rc<WindowRenderingContext>,
    user_content: Rc<UserContentManager>,
    // Kept so mod-installed content can be removed on replace.
    mod_scripts: RefCell<Vec<Rc<UserScript>>>,
    mod_styles: RefCell<Vec<Rc<UserStyleSheet>>>,
}

struct Host {
    servo: Servo,
    tabs: HashMap<u64, Tab>,
    next_id: u64,
}

thread_local! {
    static HOST: RefCell<Option<Host>> = const { RefCell::new(None) };
    // Waker registered at init; Servo itself is built lazily on first webview
    // creation, AFTER a rendering context exists and is current — upstream's
    // winit example follows this order and Servo panics without it.
    static WAKER: RefCell<Option<CWaker>> = const { RefCell::new(None) };
}

/// Build Servo on first use. Caller must have made a rendering context
/// current on this thread.
fn ensure_servo() -> Option<Servo> {
    if let Some(servo) = servo_handle() {
        return Some(servo);
    }
    let waker = WAKER.with(|w| w.borrow().clone())?;

    // Persist cookies/storage across engine deaths (bowser-browser-dyr) —
    // without a config_dir servo keeps everything in RAM and resurrection
    // logs the user out of every site.
    let mut opts = servo::Opts::default();
    if let Ok(home) = std::env::var("HOME") {
        let dir = std::path::PathBuf::from(home).join(".bowser/engine");
        let _ = std::fs::create_dir_all(&dir);
        opts.config_dir = Some(dir);
    }

    let servo = ServoBuilder::default()
        .opts(opts)
        .event_loop_waker(Box::new(waker))
        .build();
    servo.setup_logging();
    HOST.with(|h| {
        *h.borrow_mut() = Some(Host {
            servo: servo.clone(),
            tabs: HashMap::new(),
            next_id: 1,
        })
    });
    Some(servo)
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
    if WAKER.with(|w| w.borrow().is_some()) {
        return false;
    }
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    WAKER.with(|w| {
        *w.borrow_mut() = Some(CWaker {
            cb: wake_cb,
            ctx: wake_ctx,
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
    WAKER.with(|w| w.borrow_mut().take());
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

    // Servo is created here, after the first context is current.
    let Some(servo) = ensure_servo() else {
        return 0;
    };

    // Allocate the id up front so the delegate can tag brain events with it.
    let id = HOST.with(|h| {
        let mut borrow = h.borrow_mut();
        let host = borrow.as_mut().expect("ensure_servo succeeded");
        let id = host.next_id;
        host.next_id += 1;
        id
    });

    let delegate = Rc::new(SwiftDelegate {
        id,
        ctx: cb_ctx,
        on_frame_ready,
        on_url_change,
        on_title_change,
        on_load_status,
    });

    let user_content = Rc::new(UserContentManager::new(&servo));
    let mut builder = WebViewBuilder::new(&servo, rendering_context.clone())
        .hidpi_scale_factor(Scale::new(hidpi))
        .user_content_manager(user_content.clone())
        .delegate(delegate);
    if let Some(parsed) = parse_url(url) {
        builder = builder.url(parsed);
    }
    let webview = builder.build();
    webview.focus();
    webview.show();

    HOST.with(|h| {
        let mut borrow = h.borrow_mut();
        let host = borrow.as_mut().expect("ensure_servo succeeded");
        host.tabs.insert(
            id,
            Tab {
                webview,
                rendering_context,
                user_content,
                mod_scripts: RefCell::new(Vec::new()),
                mod_styles: RefCell::new(Vec::new()),
            },
        );
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
    if tab.is_some() {
        brain::send(&serde_json::json!({
            "op": "event", "event": "webview_closed", "webview": id,
        }));
    }
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
// Brain bridge (BEAM sidecar; see brain.rs and ADR 0007)

/// Start the brain socket listener. `on_message` fires on the socket thread —
/// Swift must only enqueue a main-queue bowser_brain_pump call from it.
#[no_mangle]
pub extern "C" fn bowser_brain_start(
    socket_path: *const c_char,
    on_message: brain::EventCb,
    ctx: *mut c_void,
) -> bool {
    if socket_path.is_null() {
        return false;
    }
    let Ok(path) = unsafe { CStr::from_ptr(socket_path) }.to_str() else {
        return false;
    };
    brain::start(path.to_string(), on_message, ctx as usize)
}

/// Drain and execute pending brain messages. Main thread only.
#[no_mangle]
pub extern "C" fn bowser_brain_pump() {
    for message in brain::drain() {
        handle_brain_message(&message);
    }
}

thread_local! {
    // Shell-registered handler for "chrome" ops (toolbar buttons etc.).
    // Called during pump, i.e. on the main thread, with a JSON C string
    // that is only valid for the duration of the call.
    static CHROME_CB: std::cell::Cell<Option<(StrCb, usize)>> =
        const { std::cell::Cell::new(None) };
}

#[no_mangle]
pub extern "C" fn bowser_set_chrome_handler(cb: StrCb, ctx: *mut c_void) {
    CHROME_CB.with(|c| c.set(Some((cb, ctx as usize))));
}

/// Shell → brain: forward a complete JSON message (e.g. chrome_click events).
#[no_mangle]
pub extern "C" fn bowser_emit_event(json: *const c_char) {
    if json.is_null() {
        return;
    }
    let Ok(s) = unsafe { CStr::from_ptr(json) }.to_str() else {
        return;
    };
    match serde_json::from_str::<serde_json::Value>(s) {
        Ok(value) => brain::send(&value),
        Err(error) => eprintln!("bowser: bowser_emit_event bad JSON: {error}"),
    }
}

/// webview 0 = "whichever" (lowest live id) so simple mods needn't track ids.
fn resolve_webview(requested: u64) -> Option<u64> {
    HOST.with(|h| {
        let borrow = h.borrow();
        let host = borrow.as_ref()?;
        if requested != 0 && host.tabs.contains_key(&requested) {
            return Some(requested);
        }
        host.tabs.keys().min().copied()
    })
}

fn handle_brain_message(message: &serde_json::Value) {
    let op = message.get("op").and_then(|v| v.as_str()).unwrap_or("");
    let requested = message.get("webview").and_then(|v| v.as_u64()).unwrap_or(0);

    match op {
        // Synthetic marker queued by brain.rs when a brain connects.
        "_connected" => {
            let (webviews, tabs) = HOST.with(|h| {
                let borrow = h.borrow();
                let Some(host) = borrow.as_ref() else {
                    return (Vec::new(), Vec::new());
                };
                let mut ids: Vec<u64> = host.tabs.keys().copied().collect();
                ids.sort_unstable();
                let tabs: Vec<serde_json::Value> = ids
                    .iter()
                    .map(|id| {
                        let url = host.tabs[id].webview.url().map(|u| u.to_string());
                        serde_json::json!({"id": id, "url": url})
                    })
                    .collect();
                (ids, tabs)
            });
            brain::send(&serde_json::json!({
                "op": "hello", "v": 1, "webviews": webviews, "tabs": tabs,
            }));
        }
        // Engine-injected user scripts/styles (the content-script mechanism).
        // Absent field = leave alone; [] = clear. Takes effect on reload,
        // so we reload by default.
        "set_user_content" => {
            let Some(id) = resolve_webview(requested) else {
                return;
            };
            let styles = message.get("styles").and_then(|v| v.as_array()).cloned();
            let scripts = message.get("scripts").and_then(|v| v.as_array()).cloned();
            let reload = message
                .get("reload")
                .and_then(|v| v.as_bool())
                .unwrap_or(true);
            with_tab(id, move |tab| {
                if let Some(styles) = styles {
                    for old in tab.mod_styles.borrow_mut().drain(..) {
                        tab.user_content.remove_stylesheet(old);
                    }
                    let base = Url::parse("bowser://mod/style").expect("static url");
                    for css in styles.iter().filter_map(|v| v.as_str()) {
                        let sheet = Rc::new(UserStyleSheet::new(css.to_string(), base.clone()));
                        tab.user_content.add_stylesheet(sheet.clone());
                        tab.mod_styles.borrow_mut().push(sheet);
                    }
                }
                if let Some(scripts) = scripts {
                    for old in tab.mod_scripts.borrow_mut().drain(..) {
                        tab.user_content.remove_script(old);
                    }
                    for js in scripts.iter().filter_map(|v| v.as_str()) {
                        let script = Rc::new(UserScript::new(js.to_string(), None));
                        tab.user_content.add_script(script.clone());
                        tab.mod_scripts.borrow_mut().push(script);
                    }
                }
                if reload {
                    tab.webview.reload();
                }
            });
        }
        // Cookie snapshot/replay (session resurrection includes logins).
        // Engine-level via SiteDataManager — bypasses document.cookie
        // entirely, includes HttpOnly cookies.
        "get_cookies" => {
            let Some(request_id) = message.get("id").and_then(|v| v.as_u64()) else {
                return;
            };
            let Some(url) = message
                .get("url")
                .and_then(|v| v.as_str())
                .and_then(|s| Url::parse(s).ok())
            else {
                return;
            };
            let cookies: Vec<serde_json::Value> = servo_handle()
                .map(|servo| {
                    servo
                        .site_data_manager()
                        .cookies_for_url(url, servo::CookieSource::HTTP)
                        .iter()
                        .map(|c| {
                            serde_json::json!({
                                "name": c.name(), "value": c.value(),
                                "domain": c.domain(), "path": c.path(),
                                "secure": c.secure(), "http_only": c.http_only(),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            brain::send(&serde_json::json!({
                "op": "cookies_result", "id": request_id, "cookies": cookies,
            }));
        }
        "set_cookie" => {
            let Some(url) = message
                .get("url")
                .and_then(|v| v.as_str())
                .and_then(|s| Url::parse(s).ok())
            else {
                return;
            };
            let Some(spec) = message.get("cookie") else {
                return;
            };
            let (Some(name), Some(value)) = (
                spec.get("name").and_then(|v| v.as_str()),
                spec.get("value").and_then(|v| v.as_str()),
            ) else {
                return;
            };
            let mut builder = cookie::Cookie::build((name.to_string(), value.to_string()));
            if let Some(domain) = spec.get("domain").and_then(|v| v.as_str()) {
                builder = builder.domain(domain.to_string());
            }
            if let Some(path) = spec.get("path").and_then(|v| v.as_str()) {
                builder = builder.path(path.to_string());
            }
            if let Some(secure) = spec.get("secure").and_then(|v| v.as_bool()) {
                builder = builder.secure(secure);
            }
            if let Some(http_only) = spec.get("http_only").and_then(|v| v.as_bool()) {
                builder = builder.http_only(http_only);
            }
            if let Some(servo) = servo_handle() {
                servo
                    .site_data_manager()
                    .set_cookie_for_url(url, builder.build(), None);
                servo.spin_event_loop();
            }
        }
        // Chrome surface ops are the shell's business — pass through verbatim.
        "chrome" => {
            let Some((cb, ctx)) = CHROME_CB.with(|c| c.get()) else {
                return;
            };
            if let Ok(s) = CString::new(message.to_string()) {
                cb(ctx as *mut c_void, s.as_ptr());
            }
        }
        "navigate" => {
            let Some(url) = message
                .get("url")
                .and_then(|v| v.as_str())
                .and_then(|s| Url::parse(s).ok())
            else {
                return;
            };
            if let Some(id) = resolve_webview(requested) {
                with_tab(id, |tab| tab.webview.load(url));
            }
        }
        "eval_js" => {
            let Some(request_id) = message.get("id").and_then(|v| v.as_u64()) else {
                return;
            };
            let Some(code) = message.get("code").and_then(|v| v.as_str()) else {
                return;
            };
            let Some(id) = resolve_webview(requested) else {
                brain::send(&serde_json::json!({
                    "op": "js_result", "id": request_id,
                    "ok": false, "value": "no webview",
                }));
                return;
            };
            let code = code.to_string();
            with_tab(id, move |tab| {
                tab.webview.evaluate_javascript(code, move |result| {
                    let reply = match result {
                        Ok(value) => serde_json::json!({
                            "op": "js_result", "id": request_id, "webview": id,
                            "ok": true, "value": js_value_to_json(&value),
                        }),
                        Err(error) => serde_json::json!({
                            "op": "js_result", "id": request_id, "webview": id,
                            "ok": false, "value": format!("{error:?}"),
                        }),
                    };
                    brain::send(&reply);
                });
            });
        }
        other => eprintln!("bowser-brain: unknown op {other:?}"),
    }
}

fn js_value_to_json(value: &JSValue) -> serde_json::Value {
    use serde_json::Value as J;
    match value {
        JSValue::Undefined | JSValue::Null => J::Null,
        JSValue::Boolean(b) => J::Bool(*b),
        JSValue::Number(n) => serde_json::Number::from_f64(*n).map_or(J::Null, J::Number),
        JSValue::String(s) => J::String(s.clone()),
        JSValue::Element(s) | JSValue::ShadowRoot(s) | JSValue::Frame(s) | JSValue::Window(s) => {
            J::String(s.clone())
        }
        JSValue::Array(items) => J::Array(items.iter().map(js_value_to_json).collect()),
        JSValue::Object(map) => J::Object(
            map.iter()
                .map(|(k, v)| (k.clone(), js_value_to_json(v)))
                .collect(),
        ),
    }
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
