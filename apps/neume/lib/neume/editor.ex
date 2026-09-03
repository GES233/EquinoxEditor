defmodule Neume.Editor do
  @moduledoc """
  Neume 的无界面编辑入口。

  编辑状态由 `Coconut.Session` 持有；Neume 只负责把具名编辑动作、工程
  存取和固定的合成图收束成一个宿主 API。历史与最近一次检查结果是会话
  状态，不写入工程文件。
  """

  alias Coconut.Edit.{Track, Workspace}
  alias Coconut.Edit.Operations.{DeleteNote, DragNote, EditNote, InsertNote}
  alias Coconut.Pickle.File
  alias Coconut.Pickle.Track, as: PickleTrack
  alias Coconut.Project
  alias Coconut.Render.Channels.{Duration, Pitch}
  alias Coconut.Util.ID
  alias Neume.Engine.DiffSingerPipeline
  alias Neume.Engine.MockPipeline
  alias Neume.Voicebank.DiffSinger

  @default_track_id "vocal"
  @default_ticks_per_frame 10

  @enforce_keys [:session, :registry, :track_id, :pipeline]
  defstruct [:session, :registry, :track_id, :pipeline]

  @type t :: %__MODULE__{
          session: Coconut.Session.t(),
          registry: Coconut.Pickle.Registry.t(),
          track_id: Track.track_id(),
          pipeline: module()
        }

  @doc "新建一个带单条人声轨的工程，并打开编辑会话。"
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) when is_list(opts) do
    track_id = Keyword.get(opts, :track_id, @default_track_id)

    with {:ok, voicebank, opts} <- prepare_new_voicebank(opts),
         {:ok, track} <- Track.new(%{id: track_id, module: Track.Vocal}),
         {:ok, workspace} <-
           Workspace.new(%{
             id: Keyword.get(opts, :workspace_id, ID.generate_id("WSpc_")),
             tracks: %{track_id => track}
           }),
         {:ok, project} <-
           Project.new(%{
             id: Keyword.get(opts, :project_id, ID.generate_id("Proj_")),
             workspace: workspace,
             voicebank: voicebank,
             metadata: Keyword.get(opts, :metadata, %{})
           }) do
      open(project, opts)
    end
  end

  @doc "从内存中的 Coconut 工程打开一个新会话。"
  @spec open(Project.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(%Project{} = project, opts \\ []) when is_list(opts) do
    track_id = Keyword.get(opts, :track_id, @default_track_id)
    ticks_per_frame = Keyword.get(opts, :ticks_per_frame, @default_ticks_per_frame)
    registry = Keyword.get(opts, :registry, PickleTrack.default_registry())

    with {:ok, project, manifest} <- prepare_open_voicebank(project, opts),
         :ok <- validate_ticks_per_frame(ticks_per_frame),
         {:ok, %Track{module: Track.Vocal}} <- Workspace.fetch_track(project.workspace, track_id),
         {:ok, pipeline, compiled} <- compile_pipeline(manifest, track_id, ticks_per_frame, opts),
         engine_config <- pipeline.engine_config(compiled, track_id),
         {:ok, session} <-
           Coconut.new(project,
             channels: %{duration: Duration, pitch: Pitch},
             engine: {CoconutOi.OrchidAdapter, engine_config}
           ) do
      {:ok,
       %__MODULE__{
         session: session,
         registry: registry,
         track_id: track_id,
         pipeline: pipeline
       }}
    else
      {:ok, %Track{module: module}} -> {:error, {:not_vocal_track, track_id, module}}
      {:error, _} = error -> error
    end
  end

  @doc "从工程文件打开会话；读档后的 undo/redo 历史从空树重新开始。"
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(path, opts \\ []) when is_list(opts) do
    registry = Keyword.get(opts, :registry, PickleTrack.default_registry())

    with {:ok, project} <- File.read(path, registry) do
      open(project, Keyword.put(opts, :registry, registry))
    end
  end

  @doc "保存当前工程快照，不持久化会话历史和 render check 状态。"
  @spec save(t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def save(%__MODULE__{} = editor, path) do
    with {:ok, project} <- Coconut.project(editor.session) do
      File.write(project, editor.registry, path)
    end
  end

  @doc "返回按时间排序的当前音符视图。"
  @spec notes(t()) :: {:ok, Track.view()} | {:error, term()}
  def notes(%__MODULE__{} = editor) do
    with {:ok, track} <- current_track(editor) do
      {:ok, Track.view(track)}
    end
  end

  @doc "插入一个音符。`span` 为半开 tick 区间。"
  @spec insert_note(t(), term(), term() | :head, Track.span(), map()) ::
          {:ok, t()} | {:error, term()}
  def insert_note(%__MODULE__{} = editor, note_id, after_id, span, attrs) do
    apply_edit(editor, %InsertNote{
      track_id: editor.track_id,
      note_id: note_id,
      after_id: after_id,
      span: span,
      attrs: attrs
    })
  end

  @doc "修改音符内容；时间位置请使用 `drag_note/4`。"
  @spec edit_note(t(), term(), map()) :: {:ok, t()} | {:error, term()}
  def edit_note(%__MODULE__{} = editor, note_id, changes) do
    apply_edit(editor, %EditNote{
      track_id: editor.track_id,
      note_id: note_id,
      changes: changes
    })
  end

  @doc "以同一批 Move + Retime 操作拖动音符。"
  @spec drag_note(t(), term(), term() | :head, Track.span()) ::
          {:ok, t()} | {:error, term()}
  def drag_note(%__MODULE__{} = editor, note_id, after_id, new_span) do
    with {:ok, track} <- current_track(editor),
         {:ok, old_span} <- fetch_span(track, note_id) do
      apply_edit(editor, %DragNote{
        track_id: editor.track_id,
        note_id: note_id,
        after_id: after_id,
        old_span: old_span,
        new_span: new_span
      })
    end
  end

  @doc "删除一个音符。"
  @spec delete_note(t(), term()) :: {:ok, t()} | {:error, term()}
  def delete_note(%__MODULE__{} = editor, note_id) do
    apply_edit(editor, %DeleteNote{track_id: editor.track_id, note_id: note_id})
  end

  @doc "在音符上挂载绝对 tick 到 MIDI 的稀疏 pitch 控制点。"
  @spec mount_pitch(t(), term(), [[number()]]) :: {:ok, t()} | {:error, term()}
  def mount_pitch(%__MODULE__{} = editor, note_id, points) do
    case Coconut.mount(editor.session, editor.track_id, note_id, :pitch, points) do
      {:ok, session, _patch} -> {:ok, %{editor | session: session}}
      {:error, _} = error -> error
    end
  end

  @doc "在音符上挂载逐音素的稀疏时长 pin：`[[音素下标, tick 时长], ...]`。"
  @spec mount_phoneme_duration(t(), term(), [[non_neg_integer()]]) ::
          {:ok, t()} | {:error, term()}
  def mount_phoneme_duration(%__MODULE__{} = editor, note_id, durations) do
    case Coconut.mount(editor.session, editor.track_id, note_id, :duration, durations) do
      {:ok, session, _patch} -> {:ok, %{editor | session: session}}
      {:error, _} = error -> error
    end
  end

  @doc "撤销一步编辑。"
  @spec undo(t()) :: {:ok, t()} | {:error, term()}
  def undo(%__MODULE__{} = editor), do: move_history(editor, &Coconut.undo/1)

  @doc "重做一步编辑。"
  @spec redo(t()) :: {:ok, t()} | {:error, term()}
  def redo(%__MODULE__{} = editor), do: move_history(editor, &Coconut.redo/1)

  @doc "完成 resolve/check/render，并返回不暴露 Oi 内部内存的渲染制品。"
  @spec render(t()) :: {:ok, t(), Neume.RenderArtifact.t()} | {:error, term()}
  def render(%__MODULE__{} = editor) do
    with {:ok, session, result} <- Coconut.render(editor.session),
         {:ok, artifact} <- editor.pipeline.fetch_artifact(result) do
      {:ok, %{editor | session: session}, artifact}
    end
  end

  defp current_track(editor) do
    editor.session
    |> Coconut.workspace()
    |> Workspace.fetch_track(editor.track_id)
  end

  defp fetch_span(track, note_id) do
    case Track.latest_span(track, note_id) do
      nil -> {:error, {:unknown_note, note_id}}
      span -> {:ok, span}
    end
  end

  defp apply_edit(editor, request) do
    case Coconut.edit(editor.session, request) do
      {:ok, session} -> {:ok, %{editor | session: session}}
      {:error, _} = error -> error
    end
  end

  defp move_history(editor, move) do
    case move.(editor.session) do
      {:ok, session} -> {:ok, %{editor | session: session}}
      {:error, _} = error -> error
    end
  end

  defp validate_ticks_per_frame(value) when is_integer(value) and value > 0, do: :ok
  defp validate_ticks_per_frame(value), do: {:error, {:invalid_ticks_per_frame, value}}

  defp prepare_new_voicebank(opts) do
    case Keyword.get(opts, :voicebank_path) do
      nil ->
        {:ok, Keyword.get(opts, :voicebank), opts}

      path ->
        with {:ok, manifest} <- DiffSinger.scan(path),
             signature = DiffSinger.signature(manifest),
             :ok <- compare_signature(Keyword.get(opts, :voicebank), signature) do
          {:ok, signature, Keyword.put(opts, :voicebank_manifest, manifest)}
        end
    end
  end

  defp prepare_open_voicebank(project, opts) do
    case Keyword.get(opts, :voicebank_manifest) do
      %DiffSinger{} = manifest ->
        with {:ok, project} <- bind_voicebank(project, DiffSinger.signature(manifest)) do
          {:ok, project, manifest}
        end

      nil ->
        scan_open_voicebank(project.voicebank, Keyword.get(opts, :voicebank_path), project)

      other ->
        {:error, {:invalid_voicebank_manifest, other}}
    end
  end

  defp scan_open_voicebank(nil, nil, project), do: {:ok, project, nil}

  defp scan_open_voicebank(signature, nil, _project),
    do: {:error, {:voicebank_path_required, signature}}

  defp scan_open_voicebank(_signature, path, project) do
    with {:ok, manifest} <- DiffSinger.scan(path),
         {:ok, project} <- bind_voicebank(project, DiffSinger.signature(manifest)) do
      {:ok, project, manifest}
    end
  end

  defp bind_voicebank(%Project{voicebank: nil} = project, signature) do
    Project.new(%{
      id: project.id,
      workspace: project.workspace,
      voicebank: signature,
      metadata: project.metadata
    })
  end

  defp bind_voicebank(%Project{voicebank: signature} = project, signature), do: {:ok, project}

  defp bind_voicebank(%Project{voicebank: expected}, actual),
    do: {:error, {:voicebank_mismatch, expected, actual}}

  defp compare_signature(nil, _actual), do: :ok
  defp compare_signature(signature, signature), do: :ok

  defp compare_signature(expected, actual),
    do: {:error, {:voicebank_mismatch, expected, actual}}

  defp compile_pipeline(nil, _track_id, ticks_per_frame, _opts) do
    with {:ok, compiled} <- MockPipeline.compile(ticks_per_frame: ticks_per_frame) do
      {:ok, MockPipeline, compiled}
    end
  end

  defp compile_pipeline(%DiffSinger{} = manifest, track_id, _ticks_per_frame, opts) do
    pipeline_opts =
      [manifest: manifest, track_id: track_id]
      |> put_option(:output_dir, opts, :output_dir)
      |> put_option(:python, opts, :python)
      |> put_option(:worker, opts, :diffsinger_worker)
      |> put_option(:client, opts, :diffsinger_client)
      |> put_option(:client_config, opts, :diffsinger_client_config)
      |> put_option(:speaker, opts, :speaker)
      |> put_option(:gender, opts, :gender)
      |> put_option(:velocity, opts, :velocity)
      |> put_option(:depth, opts, :depth)
      |> put_option(:steps, opts, :steps)

    with {:ok, compiled} <- DiffSingerPipeline.compile(pipeline_opts) do
      {:ok, DiffSingerPipeline, compiled}
    end
  end

  defp put_option(target, target_key, source, source_key) do
    case Keyword.fetch(source, source_key) do
      {:ok, value} -> Keyword.put(target, target_key, value)
      :error -> target
    end
  end
end
