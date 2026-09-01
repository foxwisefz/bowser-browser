defmodule BowserBrain.ModCatalogTest do
  use ExUnit.Case, async: true

  alias BowserBrain.ModCatalog

  setup do
    root = Path.join(System.tmp_dir!(), "modcatalog-#{System.unique_integer([:positive])}")
    mods = Path.join(root, "mods")
    sites = Path.join(root, "sites/x.com")
    File.mkdir_p!(mods)
    File.mkdir_p!(sites)

    File.write!(Path.join(mods, "dock.ex"), """
    defmodule Dock do
      @moduledoc \"\"\"
      Edge dock of tab icons.
      \"\"\"
      use BowserBrain.Mod
    end
    """)

    File.write!(Path.join(mods, "nav.ex.off"), """
    # Keyboard nav for tweets.
    defmodule Nav do
      use BowserBrain.Mod, host: "x.com"
    end
    """)

    File.write!(Path.join(sites, "font.css"), "/* Bigger tweet font */\nbody{font-size:18px}")
    File.write!(Path.join(sites, "hide.js.off"), "// hide media\ndocument.body.hidden=true")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, mods: mods, sites: Path.join(root, "sites")}
  end

  test "catalog lists mods and payloads with state, scope and about", %{mods: m, sites: s} do
    paths = ModCatalog.catalog(m, s) |> Enum.map(& &1.path)
    assert paths == ["mods/dock.ex", "mods/nav.ex.off", "sites/x.com/font.css", "sites/x.com/hide.js.off"]

    by = Map.new(ModCatalog.catalog(m, s), &{&1.path, &1})
    assert %{enabled: true, host: nil, about: "Edge dock of tab icons."} = by["mods/dock.ex"]
    assert %{enabled: false, host: "x.com", about: "Keyboard nav for tweets."} = by["mods/nav.ex.off"]
    assert %{enabled: true, host: "x.com", about: "Bigger tweet font"} = by["sites/x.com/font.css"]
    assert %{enabled: false, host: "x.com", about: "hide media"} = by["sites/x.com/hide.js.off"]
  end

  test "summary renders one prompt line per file", %{mods: m, sites: s} do
    text = ModCatalog.summary(m, s)
    assert text =~ "- mods/dock.ex [on ] (global) — Edge dock of tab icons."
    assert text =~ "- mods/nav.ex.off [OFF] (x.com) — Keyboard nav for tweets."
    assert ModCatalog.summary(Path.join(m, "nope"), Path.join(s, "nope")) == "None."
  end

  test "read returns full source and finds the .off twin", %{mods: m, sites: s} do
    assert {:ok, src} = ModCatalog.read("mods/dock.ex", m, s)
    assert src =~ "defmodule Dock"
    assert {:ok, src} = ModCatalog.read("mods/nav.ex", m, s)
    assert src =~ "defmodule Nav"
    assert {:ok, _} = ModCatalog.read("sites/x.com/font.css", m, s)
    assert {:error, :enoent} = ModCatalog.read("mods/missing.ex", m, s)
  end

  test "read refuses traversal and paths outside mods//sites/", %{mods: m, sites: s} do
    assert {:error, :traversal} = ModCatalog.read("mods/../secret", m, s)
    assert {:error, :outside} = ModCatalog.read("etc/passwd", m, s)
  end

  test "about falls back to first non-blank line" do
    assert ModCatalog.about("\n\nbody{color:red}") == "body{color:red}"
  end
end
