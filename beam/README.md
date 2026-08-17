# bowser_brain — the BEAM brain

Every mod is a supervised OTP process; code hot-swaps into the running
browser. See `brain/decisions/0002` and `0007`.

## Run (dev)

```sh
# 1. Start the browser (creates ~/.bowser/brain.sock)
shell/.build/debug/Bowser

# 2. Start the brain — order doesn't matter, it reconnects forever
cd beam && iex -S mix
```

## Mods

Live in `~/.bowser/mods/*.ex`. Drop a file in → running in <1s. Edit → the
process hot-swaps on its next event, state intact. Break it → compile error
logged, old code keeps running. Try `example_mods/hello.ex`:

```sh
cp example_mods/hello.ex ~/.bowser/mods/
```

From iex, drive the browser directly:

```elixir
BowserBrain.Browser.navigate("https://servo.org")
BowserBrain.Browser.eval_js("document.title")
```
