defmodule CoconutOi.OrchidAdapter.Assemble do
  @moduledoc """
  Translates coconut's kernel-intermediate intervention shape into oi's
  nested `data:` map (design doc §3.2).

  coconut carries interventions per note:

      %{port_ref => %{input: payload}}     # port_ref = {:port, note_id, channel}

  oi wants per-stage values:

      %{node => %{port => {type, %{note_id => payload}}}}

  The aggregation rule: interventions of one channel (one pipeline stage)
  collapse into a single value keyed by `note_id`. Whether that value is
  wrapped as `{type, aggregated}` (intervention on a port with an incoming
  edge — oi remaps it onto the producer's output) or passed bare (external
  input on a dangling port) is decided by the engine-side port map.

  ## Port map

  Each entry maps a channel to its oi data target:

    * `{node, port}` — intervention, wrapped as `{:override, aggregated}`
    * `{node, port, type}` — intervention with an explicit type
      (`:override` or a custom `OrchidIntervention.Operate` module)
    * `{:input, node, port}` — external input, aggregated value passed bare

  This module is the only place in the package with standalone semantics;
  everything else is a thin wrap over oi.
  """

  @type port_ref :: {:port, note_id :: term(), channel :: atom()}
  @type interventions :: %{port_ref() => %{input: term()}}

  @type oi_node :: atom() | String.t()
  @type oi_port :: atom() | String.t()
  @type target ::
          {oi_node(), oi_port()} | {oi_node(), oi_port(), atom()} | {:input, oi_node(), oi_port()}
  @type port_map :: %{atom() => target()}

  @doc """
  Aggregate `interventions` into oi's nested `data:` shape per `port_map`.

  Returns `{:error, {:unknown_channels, [channel]}}` when a channel has no
  port map entry, or `{:error, {:invalid_port_ref, ref}}` for malformed keys.
  """
  @spec assemble(interventions(), port_map()) ::
          {:ok, map()}
          | {:error, {:unknown_channels, [atom()]}}
          | {:error, {:invalid_port_ref, term()}}
  def assemble(interventions, port_map) when is_map(interventions) and is_map(port_map) do
    with :ok <- validate_refs(interventions),
         {:ok, grouped} <- group_by_channel(interventions, port_map) do
      {:ok, nest(grouped, port_map)}
    end
  end

  defp validate_refs(interventions) do
    Enum.reduce_while(interventions, :ok, fn
      {{:port, _note_id, channel}, %{input: _}}, :ok when is_atom(channel) ->
        {:cont, :ok}

      {ref, _}, :ok ->
        {:halt, {:error, {:invalid_port_ref, ref}}}
    end)
  end

  defp group_by_channel(interventions, port_map) do
    Enum.reduce_while(interventions, {:ok, %{}}, fn {{:port, note_id, channel}, %{input: payload}},
                                                    {:ok, acc} ->
      if Map.has_key?(port_map, channel) do
        {:cont,
         {:ok, Map.update(acc, channel, %{note_id => payload}, &Map.put(&1, note_id, payload))}}
      else
        {:halt, {:error, {:unknown_channels, unknown_channels(interventions, port_map)}}}
      end
    end)
  end

  defp unknown_channels(interventions, port_map) do
    interventions
    |> Enum.map(fn {{:port, _note_id, channel}, _} -> channel end)
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(port_map, &1))
  end

  # Fold aggregated channels into oi's nested %{node => %{port => value}}.
  # Several channels may share a node; their ports live side by side.
  defp nest(grouped, port_map) do
    Enum.reduce(grouped, %{}, fn {channel, aggregated}, acc ->
      {node, port, value} = emit(aggregated, Map.fetch!(port_map, channel))
      Map.update(acc, node, %{port => value}, &Map.put(&1, port, value))
    end)
  end

  defp emit(aggregated, target) do
    case target do
      {:input, node, port} -> {node, port, aggregated}
      {node, port} -> {node, port, {:override, aggregated}}
      {node, port, type} when is_atom(type) -> {node, port, {type, aggregated}}
    end
  end
end
