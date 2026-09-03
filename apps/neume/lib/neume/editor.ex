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
  alias Coconut.Render.Channels.Pitch
  alias Coconut.Util.ID
  alias Neume.Engine.MockPipeline

  @default_track_id "vocal"
  @default_ticks_per_frame 10

  @enforce_keys [:session, :registry, :track_id]
  defstruct [:session, :registry, :track_id]

  @type t :: %__MODULE__{
          session: Coconut.Session.t(),
          registry: Coconut.Pickle.Registry.t(),
          track_id: Track.track_id()
        }

  @doc "新建一个带单条人声轨的工程，并打开编辑会话。"
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) when is_list(opts) do
    track_id = Keyword.get(opts, :track_id, @default_track_id)

    with {:ok, track} <- Track.new(%{id: track_id, module: Track.Vocal}),
         {:ok, workspace} <-
           Workspace.new(%{
             id: Keyword.get(opts, :workspace_id, ID.generate_id("WSpc_")),
             tracks: %{track_id => track}
           }),
         {:ok, project} <-
           Project.new(%{
             id: Keyword.get(opts, :project_id, ID.generate_id("Proj_")),
             workspace: workspace,
             voicebank: Keyword.get(opts, :voicebank),
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

    with :ok <- validate_ticks_per_frame(ticks_per_frame),
         {:ok, %Track{module: Track.Vocal}} <- Workspace.fetch_track(project.workspace, track_id),
         {:ok, compiled} <- MockPipeline.compile(ticks_per_frame: ticks_per_frame),
         engine_config <- MockPipeline.engine_config(compiled, track_id),
         {:ok, session} <-
           Coconut.new(project,
             channels: %{pitch: Pitch},
             engine: {CoconutOi.OrchidAdapter, engine_config}
           ) do
      {:ok, %__MODULE__{session: session, registry: registry, track_id: track_id}}
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

  @doc "撤销一步编辑。"
  @spec undo(t()) :: {:ok, t()} | {:error, term()}
  def undo(%__MODULE__{} = editor), do: move_history(editor, &Coconut.undo/1)

  @doc "重做一步编辑。"
  @spec redo(t()) :: {:ok, t()} | {:error, term()}
  def redo(%__MODULE__{} = editor), do: move_history(editor, &Coconut.redo/1)

  @doc "完成 resolve/check/render，并返回不暴露 Oi 内部内存的 mock 制品。"
  @spec render(t()) :: {:ok, t(), Neume.RenderArtifact.t()} | {:error, term()}
  def render(%__MODULE__{} = editor) do
    with {:ok, session, result} <- Coconut.render(editor.session),
         {:ok, artifact} <- MockPipeline.fetch_artifact(result) do
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
end
