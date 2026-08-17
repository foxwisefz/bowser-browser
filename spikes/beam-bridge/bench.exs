# Spike bowser-browser-4jh: measure BEAM<->Rust port round-trip latency.
# Run AFTER the machine is idle (a concurrent servo build skews numbers):
#   elixir spikes/beam-bridge/bench.exs
# Expects portecho built at spikes/beam-bridge/portecho/target/release/portecho

defmodule BridgeBench do
  @iterations 10_000
  @warmup 1_000
  @sizes [32, 1_024, 16_384]

  def run do
    exe =
      [
        Path.join(__DIR__, "portecho/target/aarch64-apple-darwin/release/portecho"),
        Path.join(__DIR__, "portecho/target/release/portecho")
      ]
      |> Enum.find(&File.exists?/1) || raise("build portecho first: cargo build --release")

    port = Port.open({:spawn_executable, exe}, [:binary, {:packet, 4}])

    for size <- @sizes do
      payload = :crypto.strong_rand_bytes(size)
      for _ <- 1..@warmup, do: roundtrip(port, payload)

      times =
        for _ <- 1..@iterations do
          t0 = System.monotonic_time(:nanosecond)
          roundtrip(port, payload)
          System.monotonic_time(:nanosecond) - t0
        end
        |> Enum.sort()

      p = fn q -> Enum.at(times, min(@iterations - 1, floor(q * @iterations))) / 1_000 end
      mean = Enum.sum(times) / @iterations / 1_000

      :io.format(
        "payload ~6wB  mean ~8.1fus  p50 ~8.1fus  p99 ~8.1fus  p999 ~8.1fus  (~w msg/s serial)~n",
        [size, mean, p.(0.5), p.(0.99), p.(0.999), trunc(1_000_000 / mean)]
      )
    end

    Port.close(port)
  end

  defp roundtrip(port, payload) do
    send(port, {self(), {:command, payload}})

    receive do
      {^port, {:data, _echoed}} -> :ok
    after
      5_000 -> raise "port round-trip timed out"
    end
  end
end

BridgeBench.run()
