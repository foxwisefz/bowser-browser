defmodule BowserMobileExperiment.MixProject do
  use Mix.Project
  def project do
    [app: :bowser_mobile_experiment, version: "0.0.1", elixir: "~> 1.18",
     deps: [{:bowser_brain, path: "../../../beam"}]]
  end
  def application do
    [extra_applications: [:logger], mod: {BowserMobileExperiment.Application, []}]
  end
end
