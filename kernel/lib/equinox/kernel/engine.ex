defmodule Equinox.Kernel.Engine do
  @moduledoc """
  使用 Orchid 引擎运行编译后的 RecipeBundle。
  通过 PubSub 发出进度事件。
  """

  alias Equinox.Kernel.{RecipeBundle, Graph.PortRef, Blackboard, Configurator}
  alias Equinox.Editor.Segment

  @spec run(
          Segment.id(),
          RecipeBundle.t(),
          Blackboard.t(),
          Configurator.t()
        ) :: {:ok, Segment.id(), map()} | {:error, term()}
  def run(segment_id, %RecipeBundle{} = bundle, %Blackboard{} = blackboard, %Configurator{} = ctx) do
    intervention_by_orchid_key =
      Map.new(bundle.interventions, fn {k, v} -> {PortRef.to_orchid_key(k), v} end)

    dynamic_inputs =
      resolve_dependencies(segment_id, bundle, blackboard, intervention_by_orchid_key)

    baggage =
      ctx.orchid_baggage
      |> Map.merge(%{segment_id: segment_id, interventions: intervention_by_orchid_key})

    base_opts = Keyword.merge(ctx.orchid_opts, baggage: baggage)
    {recipe, final_opts} = Configurator.apply_plugins(ctx, {bundle.recipe, base_opts})

    case Orchid.run(recipe, dynamic_inputs, final_opts) do
      {:ok, results} -> {:ok, segment_id, results}
      {:error, reason} -> {:error, {:orchid_run_failed, segment_id, reason}}
    end
  end

  defp resolve_dependencies(
         segment_id,
         %RecipeBundle{requires: requires},
         %Blackboard{memory: mem},
         intervention_by_orchid_key
       ) do
    Enum.map(requires, fn orchid_key ->
      case Map.fetch(mem, {segment_id, orchid_key}) do
        {:ok, val} ->
          Orchid.Param.new(orchid_key, :any, val)

        :error ->
          resolve_from_intervention(orchid_key, intervention_by_orchid_key)
      end
    end)
  end

  defp resolve_from_intervention(orchid_key, interventions) do
    case Map.get(interventions, orchid_key) do
      %{input: %Orchid.Param{} = param} -> %{param | name: orchid_key}
      %{input: raw} when not is_nil(raw) -> Orchid.Param.new(orchid_key, :any, raw)
      _ -> Orchid.Param.new(orchid_key, :void, nil)
    end
  end
end
