// Spike bowser-browser-4jh: Erlang port echo server.
// Speaks {packet, 4} framing on stdin/stdout: 4-byte big-endian length prefix,
// then payload. Echoes every frame back unchanged so the Elixir side can
// measure pure bridge round-trip cost.

use std::io::{self, BufReader, BufWriter, Read, Write};

fn main() -> io::Result<()> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = BufReader::with_capacity(1 << 20, stdin.lock());
    let mut writer = BufWriter::with_capacity(1 << 20, stdout.lock());
    let mut buf = Vec::with_capacity(1 << 16);

    loop {
        let mut len_bytes = [0u8; 4];
        match reader.read_exact(&mut len_bytes) {
            Ok(()) => {}
            // BEAM closed the port: clean shutdown.
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(e) => return Err(e),
        }
        let len = u32::from_be_bytes(len_bytes) as usize;
        buf.resize(len, 0);
        reader.read_exact(&mut buf)?;

        writer.write_all(&len_bytes)?;
        writer.write_all(&buf)?;
        writer.flush()?;
    }
}
