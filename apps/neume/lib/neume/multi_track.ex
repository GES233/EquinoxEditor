defmodule Neume.MultiTrack do
  @moduledoc """
  Neume 多轨运行时。

  每条 Vocal track 独立打开 `Neume.Editor`，因而拥有独立声库 pipeline、worker
  与乐句缓存；混音图只消费各轨 WAV，不理解音素或 intervention。
  """

  alias Coconut.Edit.{Track, Workspace}
  alias Neume.{Editor, MixPipeline, TrackConfig}
  alias Neume.Voicebank.Registry

  @enforce_keys [:project, :voicebank_registry, :tracks, :mix_pipeline, :output_dir]
  defstruct [:project, :voicebank_registry, :tracks, :mix_pipeline, :output_dir]

  @type t :: %__MODULE__{
          project: Coconut.Project.t(),
          voicebank_registry: Registry.t(),
          tracks: %{Track.track_id() => Editor.t()},
          mix_pipeline: Oi.Compiled.t(),
          output_dir: Path.t()
        }

  @spec open(Coconut.Project.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(%Coconut.Project{} = project, opts) do
    registry = Keyword.fetch!(opts, :voicebank_registry)
    output_dir = Keyword.get(opts, :output_dir, "tmp/renders")

    with {:ok, tracks} <- open_tracks(project, registry, opts),
         {:ok, mix_pipeline} <- MixPipeline.compile(output_dir: output_dir) do
      {:ok,
       %__MODULE__{
         project: project,
         voicebank_registry: registry,
         tracks: tracks,
         mix_pipeline: mix_pipeline,
         output_dir: output_dir
       }}
    end
  end

  @spec add_vocal_track(Coconut.Project.t(), Track.track_id(), Neume.Voicebank.Entry.t(), map()) ::
          {:ok, Coconut.Project.t()} | {:error, term()}
  def add_vocal_track(%Coconut.Project{} = project, track_id, entry, attrs \\ %{}) do
    mix = Map.get(attrs, :mix, %{})

    with {:ok, track} <-
           Track.new(%{
             id: track_id,
             module: Track.Vocal,
             name: Map.get(attrs, :name),
             extras: %{}
           }),
         track <- TrackConfig.put_voicebank(track, entry.signature),
         {:ok, track} <- TrackConfig.put_mix(track, mix),
         {:ok, workspace} <- Workspace.add_track(project.workspace, track) do
      Coconut.Project.new(%{
        id: project.id,
        workspace: workspace,
        voicebank: nil,
        metadata: project.metadata
      })
    end
  end

  @spec check(t()) :: {:ok, t(), map()} | {:error, {:check_failed, [map()]}}
  def check(%__MODULE__{} = runtime) do
    {tracks, reports, errors} =
      Enum.reduce(runtime.tracks, {%{}, %{}, []}, fn {track_id, editor},
                                                     {tracks, reports, errors} ->
        case Editor.check(editor) do
          {:ok, editor, report} ->
            {Map.put(tracks, track_id, editor), Map.put(reports, track_id, report), errors}

          {:error, {:check_failed, entries}} ->
            {Map.put(tracks, track_id, editor), reports, errors ++ entries}
        end
      end)

    runtime = %{runtime | tracks: tracks}
    if errors == [], do: {:ok, runtime, reports}, else: {:error, {:check_failed, errors}}
  end

  @spec put_mix(t(), Track.track_id(), map()) :: {:ok, t()} | {:error, term()}
  def put_mix(%__MODULE__{} = runtime, track_id, attrs) do
    with {:ok, editor} <- Map.fetch(runtime.tracks, track_id),
         {:ok, track} <- editor.session |> Coconut.workspace() |> Workspace.fetch_track(track_id),
         {:ok, track} <- TrackConfig.put_mix(track, attrs),
         command <- Coconut.Edit.Command.put_track_extras(track_id, track.extras),
         {:ok, session} <- Coconut.run(editor.session, command) do
      editor = %{editor | session: session}
      {:ok, %{runtime | tracks: Map.put(runtime.tracks, track_id, editor)}}
    else
      :error -> {:error, {:unknown_track, track_id}}
      {:error, _} = error -> error
    end
  end

  @spec render(t()) :: {:ok, t(), Neume.MixArtifact.t()} | {:error, term()}
  def render(%__MODULE__{} = runtime) do
    with {:ok, runtime, _reports} <- check(runtime),
         {:ok, tracks, artifacts} <- render_tracks(runtime),
         {:ok, artifact} <- MixPipeline.run(runtime.mix_pipeline, artifacts) do
      {:ok, %{runtime | tracks: tracks}, artifact}
    end
  end

  defp open_tracks(project, registry, opts) do
    project.workspace.tracks
    |> Enum.filter(fn {_id, track} -> track.module == Track.Vocal end)
    |> Enum.reduce_while({:ok, %{}}, fn {track_id, track}, {:ok, acc} ->
      case TrackConfig.voicebank(track) do
        nil ->
          {:halt, {:error, {:track_voicebank_required, track_id}}}

        signature ->
          with {:ok, entry} <- Registry.resolve(registry, signature),
               {:ok, editor} <-
                 Editor.open(
                   project,
                   opts
                   |> Keyword.put(:track_id, track_id)
                   |> Keyword.put(:voicebank_entry, entry)
                 ) do
            {:cont, {:ok, Map.put(acc, track_id, editor)}}
          else
            {:error, reason} -> {:halt, {:error, {:track_open_failed, track_id, reason}}}
          end
      end
    end)
  end

  defp render_tracks(runtime) do
    Enum.reduce_while(runtime.tracks, {:ok, %{}, []}, fn {track_id, editor},
                                                         {:ok, tracks, artifacts} ->
      case Editor.render(editor) do
        {:ok, editor, artifact} ->
          case editor.session |> Coconut.workspace() |> Workspace.fetch_track(track_id) do
            {:ok, track} ->
              item = %{track_id: track_id, artifact: artifact, mix: TrackConfig.mix(track)}
              {:cont, {:ok, Map.put(tracks, track_id, editor), [item | artifacts]}}

            {:error, reason} ->
              {:halt, {:error, {:track_missing_after_render, track_id, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:track_render_failed, track_id, reason}}}
      end
    end)
    |> case do
      {:ok, tracks, artifacts} -> {:ok, tracks, Enum.reverse(artifacts)}
      {:error, _} = error -> error
    end
  end
end
