defmodule Equinox.Kernel.RecipeBundle do
  @moduledoc """
  编译输出的容器，包含静态 AST（Orchid Recipe）和动态参数。
  """

  alias Equinox.Kernel.Graph

  @type t :: %__MODULE__{
          id: atom() | String.t(),
          recipe: Orchid.Recipe.t(),
          requires: [Orchid.Step.io_key()],
          exports: [Orchid.Step.io_key()],
          node_ids: [Graph.Node.id()],
          interventions: %{
            Graph.PortRef.t() => OrchidIntervention.intervention_spec()
          }
        }

  defstruct [:id, :recipe, :requires, :exports, :node_ids, interventions: %{}]

  @type interventions_map :: %{
          Graph.PortRef.t() => OrchidIntervention.intervention_spec()
        }

  @spec bind_interventions([t()], interventions_map()) :: [t()]
  def bind_interventions(static_recipes, interventions_map) do
    do_bind_interventions(static_recipes, interventions_map)
  end

  @spec bind_interventions([t()], interventions_map(), interventions_map()) :: [t()]
  def bind_interventions(static_recipes, interventions_map, interventions_from_segment) do
    Map.merge(interventions_map, interventions_from_segment)
    |> then(&do_bind_interventions(static_recipes, &1))
  end

  defp do_bind_interventions(static_recipes, interventions_map) do
    Enum.map(static_recipes, fn %{node_ids: node_ids} = static_bundle ->
      filtered_interventions =
        Map.filter(interventions_map, fn {{:port, target_node, _}, _port_data} ->
          target_node in node_ids
        end)

      %{static_bundle | interventions: filtered_interventions}
    end)
  end
end
