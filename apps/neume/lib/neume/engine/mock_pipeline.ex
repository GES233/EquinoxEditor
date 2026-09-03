defmodule Neume.Engine.MockPipeline do
  @moduledoc """
  Neume 的固定 mock 合成图。

  图只承担闭环验收，不冒充声学模型：`ScorePlan` 把 Coconut snapshot
  规划成帧，`Pitch` 合并按音符挂载的稀疏控制点，`Acoustic` 产出稳定的
  `Neume.RenderArtifact`。将来替换真实 DiffSinger worker 时，Editor 和
  Coconut 的会话边界无需改变。
  """

  alias Coconut.Render.Engine.Snapshot
  alias Neume.Engine.MockPipeline.Steps.{Acoustic, Pitch, ScorePlan}
  alias Oi.Flowgraph

  @spec compile(keyword()) :: {:ok, Oi.Compiled.t()} | {:error, term()}
  def compile(opts) when is_list(opts) do
    with {:ok, ticks_per_frame} <- fetch_ticks_per_frame(opts) do
      graph =
        Flowgraph.new_flowchart()
        |> Flowgraph.add_step(ScorePlan, opts: [ticks_per_frame: ticks_per_frame])
        |> Flowgraph.add_step(Pitch)
        |> Flowgraph.add_step(Acoustic)
        |> Flowgraph.connect({:score_plan, :plan}, {:pitch, :plan})
        |> Flowgraph.connect({:score_plan, :plan}, {:acoustic, :plan})
        |> Flowgraph.connect({:pitch, :f0_midi}, {:acoustic, :f0_midi})

      Oi.compile(graph)
    end
  end

  @spec engine_config(Oi.Compiled.t(), term()) :: map()
  def engine_config(%Oi.Compiled{} = compiled, track_id) do
    %{
      compiled: compiled,
      port_map: %{pitch: {:input, :pitch, :pins}},
      base_data: fn snapshot -> base_data(snapshot, track_id) end
    }
  end

  @doc false
  @spec base_data(Snapshot.t(), term()) :: map()
  def base_data(%Snapshot{tracks: tracks}, track_id) do
    notes =
      case Map.fetch(tracks, track_id) do
        {:ok, %{elements: elements}} -> elements
        :error -> []
      end

    %{score_plan: %{notes: notes}, pitch: %{pins: %{}}}
  end

  @spec fetch_artifact(Oi.Result.t()) ::
          {:ok, Neume.RenderArtifact.t()} | {:error, term()}
  def fetch_artifact(%Oi.Result{} = result) do
    Oi.Result.reify(result, {:acoustic, :artifact})
  end

  defp fetch_ticks_per_frame(opts) do
    case Keyword.fetch(opts, :ticks_per_frame) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_ticks_per_frame, value}}
      :error -> {:error, :missing_ticks_per_frame}
    end
  end
end
