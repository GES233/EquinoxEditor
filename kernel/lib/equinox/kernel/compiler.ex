defmodule Equinox.Kernel.Compiler do
  @moduledoc """
  纯函数管线的最终阶段。
  将轨级合成 DAG 翻译为 `Oi.Compiled`（Oi 编译产物：bundles + 执行计划）。
  """

  alias Equinox.Kernel.Graph
  alias EquinoxDomain.Command.RenderRequest

  @typedoc "执行单元 id：`{track_id, window_start_tick}`。"
  @type unit_id :: {term(), non_neg_integer()}

  @typedoc "PortRef → 干预规格（`%{input: ...}`）。"
  @type interventions_map :: %{
          Graph.PortRef.t() => OrchidIntervention.intervention_spec()
        }

  @typedoc "单个窗口的执行单元：unit id、生效图、窗口渲染请求（含存活干预）与 Oi 编译结果。"
  @type compiled_unit ::
          {unit_id(), Graph.t(), RenderRequest.t(), Oi.Compiled.t()}

  @typedoc "轨级编译缓存：`track_id => {graph, compiled}`。"
  @type compile_cache :: %{optional(term()) => {Graph.t(), Oi.Compiled.t()}}

  @doc """
  编译一轨的合成图为可执行的 `Oi.Compiled`。

  cache 命中条件：`cache[track_id]` 中的 graph 与传入 graph 结构相等，
  命中则复用编译产物；否则重新 `Oi.compile/2` 并把结果写回缓存。

  cluster 支持已取消，恒用默认 `%Oi.Topology.Cluster{}`。
  """
  @spec compile_track(term(), Graph.t(), compile_cache()) ::
          {:ok, {Graph.t(), Oi.Compiled.t()}, compile_cache()} | {:error, term()}
  def compile_track(track_id, %Graph{} = graph, cache \\ %{}) do
    case Map.fetch(cache, track_id) do
      {:ok, {cached_graph, cached_compiled}} ->
        if Graph.same?(cached_graph, graph) do
          {:ok, {cached_graph, cached_compiled}, cache}
        else
          do_compile(track_id, graph, cache)
        end

      :error ->
        do_compile(track_id, graph, cache)
    end
  end

  defp do_compile(track_id, %Graph{} = graph, cache) do
    case graph |> Graph.to_oi_graph() |> Oi.compile(%Oi.Topology.Cluster{}) do
      {:ok, compiled} ->
        {:ok, {graph, compiled}, Map.put(cache, track_id, {graph, compiled})}

      {:error, _reason} = err ->
        err
    end
  end
end
