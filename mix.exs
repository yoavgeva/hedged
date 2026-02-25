defmodule Hedged.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/yoavgeva/hedged"

  def project do
    [
      app: :hedged,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "Hedged",
      description:
        "Hedged requests for Elixir — fire a backup request after a delay, take whichever finishes first, with adaptive delay tuning."
    ]
  end

  def application do
    []
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "Hedged",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
