//! Socket bridge to the BEAM brain (bowser-browser-rv2, ADR 0007).
//!
//! The host listens on a Unix domain socket; the Elixir brain connects as a
//! client (and reconnects freely — a brain restart never touches the engine).
//! Framing is {packet,4}: 4-byte big-endian length + payload, which Erlang's
//! gen_tcp handles natively. Payload is JSON for now; the encoding decision
//! belongs to Mod API v1 (bowser-browser-ae2).
//!
//! Threading: the listener/reader runs on its own thread. Inbound messages
//! are queued and announced via a C callback (any thread!); the Swift side
//! bounces to the main queue and calls bowser_brain_pump, which drains the
//! queue where engine calls are legal. Outbound writes are safe from the
//! main thread (small frames, buffered socket).

use std::collections::VecDeque;
use std::ffi::c_void;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Mutex, OnceLock};

pub type EventCb = extern "C" fn(*mut c_void);

const MAX_FRAME: usize = 64 * 1024 * 1024;

struct Shared {
    queue: VecDeque<serde_json::Value>,
    writer: Option<UnixStream>,
    // ctx as usize: raw pointers aren't Send; Swift passes a process-lifetime
    // pointer (or null).
    cb: Option<(EventCb, usize)>,
}

static SHARED: OnceLock<Mutex<Shared>> = OnceLock::new();

fn shared() -> &'static Mutex<Shared> {
    SHARED.get_or_init(|| {
        Mutex::new(Shared {
            queue: VecDeque::new(),
            writer: None,
            cb: None,
        })
    })
}

/// Start listening. Returns false if the socket can't be bound.
pub fn start(path: String, cb: EventCb, ctx: usize) -> bool {
    let _ = std::fs::remove_file(&path);
    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(error) => {
            eprintln!("bowser-brain: bind {path} failed: {error}");
            return false;
        }
    };
    shared().lock().unwrap().cb = Some((cb, ctx));

    std::thread::Builder::new()
        .name("bowser-brain-io".into())
        .spawn(move || {
            for stream in listener.incoming() {
                match stream {
                    Ok(stream) => {
                        eprintln!("bowser-brain: brain connected");
                        if let Ok(writer) = stream.try_clone() {
                            shared().lock().unwrap().writer = Some(writer);
                        }
                        read_loop(stream);
                        shared().lock().unwrap().writer = None;
                        eprintln!("bowser-brain: brain disconnected");
                    }
                    Err(error) => {
                        eprintln!("bowser-brain: accept failed: {error}");
                        break;
                    }
                }
            }
        })
        .is_ok()
}

fn read_loop(mut stream: UnixStream) {
    let mut len_bytes = [0u8; 4];
    let mut buf = Vec::new();
    loop {
        if stream.read_exact(&mut len_bytes).is_err() {
            return;
        }
        let len = u32::from_be_bytes(len_bytes) as usize;
        if len > MAX_FRAME {
            eprintln!("bowser-brain: oversized frame ({len} bytes), dropping connection");
            return;
        }
        buf.resize(len, 0);
        if stream.read_exact(&mut buf).is_err() {
            return;
        }
        match serde_json::from_slice::<serde_json::Value>(&buf) {
            Ok(value) => {
                let cb = {
                    let mut shared = shared().lock().unwrap();
                    shared.queue.push_back(value);
                    shared.cb
                };
                if let Some((cb, ctx)) = cb {
                    cb(ctx as *mut c_void);
                }
            }
            Err(error) => eprintln!("bowser-brain: bad JSON from brain: {error}"),
        }
    }
}

/// Drain all pending brain messages. Main thread.
pub fn drain() -> Vec<serde_json::Value> {
    shared().lock().unwrap().queue.drain(..).collect()
}

/// Send a message to the brain; silently dropped when no brain is connected.
pub fn send(value: &serde_json::Value) {
    let bytes = match serde_json::to_vec(value) {
        Ok(b) => b,
        Err(_) => return,
    };
    let mut shared = shared().lock().unwrap();
    if let Some(writer) = shared.writer.as_mut() {
        let len = (bytes.len() as u32).to_be_bytes();
        if writer.write_all(&len).is_err()
            || writer.write_all(&bytes).is_err()
            || writer.flush().is_err()
        {
            shared.writer = None;
        }
    }
}
