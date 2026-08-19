# The app under test is the real brain: if a live engine is up, its Bridge
# connects and real events flow. Point session persistence away from
# ~/.bowser/session.json for the WHOLE test run — a test once clobbered the
# owner's real session with fixture URLs (bowser-browser-p7l).
Application.put_env(
  :bowser_brain,
  :session_path,
  Path.join(System.tmp_dir!(), "bowser-test-session.json")
)

Application.put_env(
  :bowser_brain,
  :modsmith_sessions_path,
  Path.join(System.tmp_dir!(), "bowser-test-modsmith-sessions.json")
)

ExUnit.start()
