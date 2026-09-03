defmodule BowserBrain.MixProject do
  use Mix.Project

  def project do
    [
      app: :bowser_brain,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [],
      # bin/install builds this into a self-contained release under
      # ~/.bowser/app/brain — the installed brain never runs from the checkout.
      releases: [bowser_brain: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :runtime_tools],
      mod: {BowserBrain.Application, []}
    ]
  end
end
