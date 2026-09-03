defmodule Neume.Engine.DiffSingerPipeline do
  @moduledoc """
  Neume 的真实 DiffSinger Oi 图。

  `ScorePlan` 只做轻量、确定性的 score→秒域装配；`Inference` 是粗粒度
  worker 边界，整条 ONNX 管线的中间张量留在同一 Python 进程内，不跨
  Orchid step、进程邮箱或 ETS 搬运。
  """

  alias Neume.Engine.DiffSingerPipeline.Steps.{Inference, ScorePlan}
  alias Neume.Engine.DiffSingerWorker
  alias Neume.Voicebank.DiffSinger
  alias Oi.Flowgraph

  @spec compile(keyword()) :: {:ok, Oi.Compiled.t()} | {:error, term()}
  def compile(opts) when is_list(opts) do
    manifest = Keyword.fetch!(opts, :manifest)
    track_id = Keyword.fetch!(opts, :track_id)
    output_dir = Keyword.get(opts, :output_dir, Path.join(File.cwd!(), "tmp/neume-renders"))
    client = Keyword.get(opts, :client, DiffSingerWorker)

    worker_config =
      opts
      |> Keyword.get(:client_config, %{})
      |> Map.merge(%{
        voicebank_root: manifest.root,
        voicebank_digest: manifest.digest,
        python: Keyword.get(opts, :python, ["python"]),
        worker: Keyword.get(opts, :worker, default_worker())
      })

    globals = %{
      "speaker" => Keyword.get(opts, :speaker, default_speaker(manifest)),
      "gender" => Keyword.get(opts, :gender, 0.0),
      "velocity" => Keyword.get(opts, :velocity, 1.0),
      "depth" => Keyword.get(opts, :depth, 0.6),
      "steps" => Keyword.get(opts, :steps, 20)
    }

    graph =
      Flowgraph.new_flowchart()
      |> Flowgraph.add_step(ScorePlan, opts: [track_id: track_id])
      |> Flowgraph.add_step(Inference,
        opts: [
          client: client,
          worker_config: worker_config,
          output_dir: output_dir,
          globals: globals
        ]
      )
      |> Flowgraph.connect({:score_plan, :plan}, {:diffsinger, :plan})

    Oi.compile(graph)
  end

  @spec engine_config(Oi.Compiled.t(), term()) :: map()
  def engine_config(%Oi.Compiled{} = compiled, _track_id) do
    %{
      compiled: compiled,
      port_map: %{
        duration: {:input, :score_plan, :duration_pins},
        pitch: {:input, :score_plan, :pitch_pins}
      },
      base_data: fn snapshot ->
        %{score_plan: %{snapshot: snapshot, duration_pins: %{}, pitch_pins: %{}}}
      end
    }
  end

  @spec fetch_artifact(Oi.Result.t()) :: {:ok, Neume.RenderArtifact.t()} | {:error, term()}
  def fetch_artifact(%Oi.Result{} = result) do
    Oi.Result.reify(result, {:diffsinger, :artifact})
  end

  defp default_worker, do: Application.app_dir(:neume, "priv/diffsinger/worker.py")

  defp default_speaker(%DiffSinger{speakers: speakers}) do
    if Map.has_key?(speakers, "Normal"), do: "Normal", else: speakers |> Map.keys() |> hd()
  end
end
