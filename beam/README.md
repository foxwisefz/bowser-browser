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

## ModSmith credentials (`:do`)

`:do <request>` in the omnibar has an LLM write site mods for you. It
shells out to the [claude CLI](https://claude.com/claude-code), so you
need one of:

- **Your own Claude login** — install the CLI, run `claude` once in a
  terminal and sign in. Nothing to configure in Bowser.
- **A router** (e.g. DodoRouter) — in the browser, `:settings` (or
  `:set`) both keys:

  ```
  :set dodorouter_endpoint https://your-router.example
  :set dodorouter_api_key <token>
  ```

  The token is sent as `CLAUDE_CODE_OAUTH_TOKEN`; routers that serve
  their own model ids may also need `:set modsmith_model <id>`.

Settings live in `~/.bowser/settings.json` (hand-editable); secrets are
masked in the palette and never leave the machine except toward the
endpoint you configured.

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
