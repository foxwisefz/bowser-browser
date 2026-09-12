defmodule BowserBrain.SiteModsSecurityTest do
  use ExUnit.Case, async: true

  test "site CSS and JS carry native host restrictions and explicit worlds" do
    root = Path.join(System.tmp_dir!(), "site-guard-#{BowserBrain.ModRevision.id()}")
    dir = Path.join(root, "bank.example")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(root) end)
    js = Path.join(dir, "private.js")
    css = Path.join(dir, "private.css")
    page = Path.join(dir, "page.js")
    File.write!(js, "globalThis.ran += 1;")
    File.write!(css, "body { color: red; }")
    File.write!(page, "// bowser-profile: work\n// bowser-world: page\nwindow.siteAPI()")
    [page_script, css_script, js_script] = BowserBrain.SiteMods.build_scripts([js, css, page])
    assert Enum.all?([page_script, css_script, js_script], &(&1.host == "bank.example"))
    assert page_script.world == "page"
    assert css_script.world == "isolated"
    assert js_script == %{host: "bank.example", world: "isolated", source: "globalThis.ran += 1;"}
    assert css_script.source =~ "body { color: red; }"
  end
end
