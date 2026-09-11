import Config

# Hermetic tests (bowser-browser-is4): mix test boots the WHOLE brain, and an
# un-fenced test VM has twice connected to the live engine and driven the
# owner's real tabs to fixture URLs. Config loads BEFORE the app boots —
# unlike test_helper.exs put_env, there is no gap.
if config_env() == :test do
  config :bowser_brain,
    connect_bridge: false,
    spawn_engine: false,
    load_user_mods: false,
    watch_lib: false,
    watch_sites: false,
    settings_path: Path.join(System.tmp_dir!(), "bowser-test-settings.json"),
    session_path: Path.join(System.tmp_dir!(), "bowser-test-session.json"),
    data_dir: Path.join(System.tmp_dir!(), "bowser-test-data"),
    profiles_path: Path.join(System.tmp_dir!(), "bowser-test-profiles.json"),
    modsmith_workspace_path: Path.join(System.tmp_dir!(), "bowser-test-modsmith-workspace.json"),
    modsmith_sessions_path: Path.join(System.tmp_dir!(), "bowser-test-modsmith-sessions.json")
end
