defmodule BowserServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :bowser_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: [
        "assets.copy": &copy_assets/1,
        test: ["assets.copy", "test"],
        release: ["assets.copy", "release"],
        "phx.server": ["assets.copy", "phx.server"]
      ],
      deps: [
        {:phoenix, "~> 1.8.0"},
        {:bandit, "~> 1.0"},
        {:jason, "~> 1.4"},
        {:exqlite, "~> 0.40.0"}
      ],
      releases: [bowser_server: [include_executables_for: [:unix]]]
    ]
  end

  defp copy_assets(_) do
    File.mkdir_p!("priv/static")

    for file <- ~w(index.html terms.html styles.css legal.css script.js app-icon.webp),
        do: File.cp!("../website/" <> file, "priv/static/" <> file)
  end

  def application,
    do: [extra_applications: [:logger, :crypto], mod: {BowserServer.Application, []}]
end
