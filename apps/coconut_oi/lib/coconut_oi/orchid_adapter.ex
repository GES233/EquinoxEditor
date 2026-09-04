defmodule CoconutOi.OrchidAdapter do
  @moduledoc """
  `Coconut.Render.Engine` implementation backed by an oi pipeline
  (design doc §4, thin wrap).

  The adapter is a dispatch-boundary translator:

    * `check/2` — static validation: the request's interventions are
      aggregated by `CoconutOi.OrchidAdapter.Assemble` against the
      engine-side port map. Unknown channels veto the round
      (`passed: false`); the globals gate is not re-implemented here —
      `Coconut.Render.Engine.run_check/2` handles it before `check/2`
      is consulted, using the `:globals` declaration from `info/1`.
    * `render/3` — merges the assembled intervention data over the base
      inputs and executes the pre-compiled `Oi.Compiled` graph with the
      `orchid_intervention` hook adapter.

  ## Config

  The engine is used as `{CoconutOi.OrchidAdapter, config}` where config
  is a map with keys:

    * `:compiled` — a `Oi.Compiled` struct (compile once, reuse; required)
    * `:port_map` — `CoconutOi.OrchidAdapter.Assemble.port_map()` (required)
    * `:base_data` — oi nested data map, or a
      `(Coconut.Render.Engine.Snapshot.t() -> map())` function producing
      the external inputs for one round (default: `%{}`)
    * `:globals` — `%{atom() => Coconut.Render.Engine.global_spec()}`,
      declared via `info/1` and validated by the `run_check/2` gate
      (default: none accepted)
    * `:execute_opts` — extra keyword opts forwarded to `Oi.execute/2`
      (e.g. `:executor`, `:orchid_baggage`)

  Graph declaration, step implementation and per-channel port mapping are
  engine-side concerns (design doc §4.1); this module only knows the
  `Coconut.Render.Engine` contract and oi's execute boundary.
  """

  @behaviour Coconut.Render.Engine

  alias Coconut.Render.Engine.Request
  alias CoconutOi.OrchidAdapter.Assemble

  @impl true
  def info(config) do
    %{
      name: "orchid-adapter",
      info: "oi/orchid render backend: Oi.execute with intervention injection",
      version: "0.1.0",
      globals: config |> Map.get(:globals, %{}) |> Map.new()
    }
  end

  @impl true
  def check(%Request{} = request, config) do
    with {:ok, port_map} <- fetch_config(config, :port_map),
         {:ok, _compiled} <- fetch_config(config, :compiled) do
      case Assemble.assemble(request.interventions, port_map) do
        {:ok, data} ->
          {:ok, %{passed: true, entries: [], checked: %{data: data}}}

        {:error, {:unknown_channels, channels}} ->
          entries =
            Enum.map(channels, &%{kind: :intervention, channel: &1, reason: :unknown_channel})

          {:ok, %{passed: false, entries: entries, checked: nil}}

        {:error, {:invalid_port_ref, ref}} ->
          entries = [%{kind: :intervention, port_ref: ref, reason: :invalid_port_ref}]
          {:ok, %{passed: false, entries: entries, checked: nil}}
      end
    end
  end

  @impl true
  def render(%Request{} = request, %{data: data}, config) do
    with {:ok, compiled} <- fetch_config(config, :compiled) do
      base = base_data(config, request.snapshot)
      extra_opts = Map.get(config, :execute_opts, [])

      opts =
        extra_opts
        |> Keyword.drop([:data, :orchid_adapters])
        |> Keyword.put(:data, deep_merge(base, data))
        |> Keyword.put(:orchid_adapters, [
          (&Oi.Adapters.orchid_intervention/1) | Keyword.get(extra_opts, :orchid_adapters, [])
        ])

      Oi.execute(compiled, opts)
    end
  end

  defp fetch_config(config, key) when is_map(config) do
    case Map.fetch(config, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_config, key}}
    end
  end

  defp fetch_config(_config, key), do: {:error, {:missing_config, key}}

  defp base_data(config, snapshot) do
    case Map.get(config, :base_data, %{}) do
      fun when is_function(fun, 1) -> fun.(snapshot)
      data when is_map(data) -> data
    end
  end

  # One level of nesting is all oi's data format has: merge per node,
  # then per port, with assembled intervention data winning.
  defp deep_merge(base, overlay) do
    Map.merge(base, overlay, fn _node, base_ports, overlay_ports ->
      Map.merge(base_ports, overlay_ports)
    end)
  end
end
