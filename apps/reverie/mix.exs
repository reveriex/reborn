defmodule Reverie.Mixfile do
  use Mix.Project

  def project do
    [app: :reverie,
     version: "0.1.0",
     build_path: "../../_build",
     config_path: "../../config/config.exs",
     deps_path: "../../deps",
     lockfile: "../../mix.lock",
     elixir: "~> 1.4",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps()]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    # Specify extra applications you'll use from Erlang/Elixir
    [extra_applications: [:logger, :timex, :dirk, :huo, :azor, :caravan,
                          :machine],
     mod: {Reverie.Application, []}]
  end

  # Dependencies can be Hex packages:
  #
  #   {:my_dep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:my_dep, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
  #
  # To depend on another app inside the umbrella:
  #
  #   {:my_app, in_umbrella: true}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [{:timex, "~> 3.0"},
     {:amnesia, "~> 0.2.5"},
     {:dirk, in_umbrella: true},
     {:huo, in_umbrella: true},
     {:azor, in_umbrella: true},
     {:caravan, in_umbrella: true},
     {:machine, in_umbrella: true}]
  end
end
