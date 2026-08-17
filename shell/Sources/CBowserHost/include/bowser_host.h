// C interface to libbowser_host (Rust, embeds Servo).
// Threading: every function must be called on the AppKit main thread.
// The wake callback may fire on ANY thread and must only enqueue
// bowser_host_spin onto the main queue. Callbacks passed to
// bowser_webview_create fire during bowser_host_spin — never call back
// into bowser_* synchronously from inside them.
#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef void (*bowser_void_cb)(void *ctx);
typedef void (*bowser_str_cb)(void *ctx, const char *value);
typedef void (*bowser_u8_cb)(void *ctx, uint8_t value);

bool bowser_host_init(bowser_void_cb wake_cb, void *wake_ctx);
void bowser_host_spin(void);
void bowser_host_shutdown(void);

// Returns webview id, 0 on failure. url may be NULL.
uint64_t bowser_webview_create(void *ns_view, uint32_t width, uint32_t height,
                               float hidpi, const char *url, void *cb_ctx,
                               bowser_void_cb on_frame_ready,
                               bowser_str_cb on_url_change,
                               bowser_str_cb on_title_change,
                               bowser_u8_cb on_load_status);
void bowser_webview_destroy(uint64_t id);

void bowser_webview_load(uint64_t id, const char *url);
void bowser_webview_reload(uint64_t id);
void bowser_webview_go_back(uint64_t id);
void bowser_webview_go_forward(uint64_t id);
void bowser_webview_paint(uint64_t id);
void bowser_webview_resize(uint64_t id, uint32_t width, uint32_t height);

// Coordinates: device pixels, origin top-left of the view.
void bowser_webview_mouse_move(uint64_t id, float x, float y);
// button: 0 left, 1 middle, 2 right.
void bowser_webview_mouse_button(uint64_t id, uint8_t button, bool down,
                                 float x, float y);
// mode: 0 pixel deltas (precise scrolling), 1 line deltas.
void bowser_webview_wheel(uint64_t id, double dx, double dy, uint8_t mode,
                          float x, float y);
void bowser_webview_key(uint64_t id, bool down, const char *characters,
                        uint16_t keycode);

// BEAM brain bridge. on_message fires on the socket thread: only enqueue a
// main-queue bowser_brain_pump call from it, nothing else.
bool bowser_brain_start(const char *socket_path, bowser_void_cb on_message,
                        void *ctx);
void bowser_brain_pump(void);

// Chrome surface ops ("chrome" messages from the brain) are forwarded to this
// handler as a JSON C string, valid only for the duration of the call. Fires
// during bowser_brain_pump (main thread).
void bowser_set_chrome_handler(bowser_str_cb handler, void *ctx);
// Shell -> brain: send a complete JSON message (e.g. chrome_click events).
void bowser_emit_event(const char *json);
