defmodule GlacierRelay.MixProject do
  use Mix.Project

  def project do
    [
      app: :glacier_relay,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {GlacierRelay.Application, []}
    ]
  end

  # M3-A (docs/design/M3_LIVE_OBSERVABILITY.md, ADR 0007): the minimal Phoenix/LiveView set for a
  # loopback, read-only observability endpoint. No Node, esbuild, Tailwind, Ecto or database. The
  # web subtree starts only when `config :glacier_relay, :dashboard, enabled: true`.
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_pubsub, "~> 2.4"},
      {:bandit, "~> 1.12"},
      {:lazy_html, "~> 0.1", only: :test}
    ]
  end
end
