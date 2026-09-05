defmodule Neume.MultiTrack do
  @moduledoc """
  Neume 多轨工程运行时。

  整个工程只有一个 `Coconut.Session`/History；每条 Vocal track 只保存独立
  `Neume.TrackRuntime`（声库 pipeline、worker 与乐句缓存）。逐轨 check/render
  临时把运行态绑定到根 Session 的同一当前快照，混音图只消费各轨 WAV。
  """

  alias Coconut.Edit.{Command, History, Track, Workspace}
  alias Coconut.Pickle.File
  alias Coconut.Pickle.Track, as: PickleTrack
  alias Neume.{Editor, MixPipeline, TrackConfig, TrackRuntime}
  alias Neume.Voicebank.{Entry, Registry}

  @enforce_keys [
    :session,
    :pickle_registry,
    :voicebank_registry,
    :tracks,
    :mix_pipeline,
    :output_dir,
    :open_opts
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          session: Coconut.Session.t(),
          pickle_registry: Coconut.Pickle.Registry.t(),
          voicebank_registry: Registry.t(),
          tracks: %{Track.track_id() => TrackRuntime.t()},
          mix_pipeline: Oi.Compiled.t(),
          output_dir: Path.t(),
          open_opts: keyword()
        }

  @spec open(Coconut.Project.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(%Coconut.Project{} = project, opts) when is_list(opts) do
    voicebank_registry = Keyword.fetch!(opts, :voicebank_registry)
    pickle_registry = Keyword.get(opts, :registry, PickleTrack.default_registry())
    output_dir = Keyword.get(opts, :output_dir, "tmp/renders")
    open_opts = Keyword.drop(opts, [:history, :voicebank_entry])

    with {:ok, session} <-
           Coconut.new(project,
             channels: track_channels(),
             history: Keyword.get(opts, :history, [])
           ),
         {:ok, tracks} <- open_tracks(project, voicebank_registry, open_opts),
         {:ok, mix_pipeline} <- MixPipeline.compile(output_dir: output_dir) do
      {:ok,
       %__MODULE__{
         session: session,
         pickle_registry: pickle_registry,
         voicebank_registry: voicebank_registry,
         tracks: tracks,
         mix_pipeline: mix_pipeline,
         output_dir: output_dir,
         open_opts: open_opts
       }}
    end
  end

  @doc "从工程文件恢复唯一 Session 及其完整 undo/redo History。"
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(path, opts) when is_list(opts) do
    registry = Keyword.get(opts, :registry, PickleTrack.default_registry())

    with {:ok, project, history} <- File.read_with_history(path, registry) do
      opts = opts |> Keyword.put(:registry, registry) |> Keyword.put(:history, history || [])
      open(project, opts)
    end
  end

  @doc "保存当前工程快照和唯一 History。逐轨 runtime 与渲染制品不入档。"
  @spec save(t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def save(%__MODULE__{} = runtime, path) do
    with {:ok, project} <- Coconut.project(runtime.session) do
      File.write(project, runtime.pickle_registry, path, history: runtime.session.history)
    end
  end

  @spec add_vocal_track(Coconut.Project.t(), Track.track_id(), Entry.t(), map()) ::
          {:ok, Coconut.Project.t()} | {:error, term()}
  def add_vocal_track(source, track_id, entry, attrs \\ %{})

  def add_vocal_track(%Coconut.Project{} = project, track_id, %Entry{} = entry, attrs) do
    with {:ok, track} <- build_vocal_track(track_id, entry, attrs),
         {:ok, workspace} <- Workspace.add_track(project.workspace, track) do
      Coconut.Project.new(%{
        id: project.id,
        workspace: workspace,
        voicebank: nil,
        metadata: project.metadata
      })
    end
  end

  @spec add_vocal_track(t(), Track.track_id(), Entry.t(), map()) ::
          {:ok, t()} | {:error, term()}
  def add_vocal_track(%__MODULE__{} = runtime, track_id, %Entry{} = entry, attrs) do
    with {:ok, track} <- build_vocal_track(track_id, entry, attrs),
         {:ok, session} <- Coconut.run(runtime.session, %Command{op: :add_track, payload: track}),
         {:ok, runtime} <- replace_session(runtime, session) do
      {:ok, runtime}
    end
  end

  @doc "删除一条轨道并记入工程唯一 History。"
  @spec remove_track(t(), Track.track_id()) :: {:ok, t()} | {:error, term()}
  def remove_track(%__MODULE__{} = runtime, track_id),
    do: run(runtime, Command.remove_track(track_id))

  @doc "重命名轨道（轻字段边，不动 edit_version；记入唯一 History）。"
  @spec rename_track(t(), Track.track_id(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def rename_track(%__MODULE__{} = runtime, track_id, name),
    do: run(runtime, Command.rename_track(track_id, name))

  @doc """
  整体替换拍号事件（轻字段边；render 不消费，不动 edit_version）。

  `events` 为 `[{bar, {num, den}}]`，首事件须在小节 1、小节号严格递增，
  非法输入返回 `{:error, {:invalid_time_sigs, events}}`。
  """
  @spec set_time_sigs(t(), [Coconut.Score.TimeSig.time_sig_event()]) ::
          {:ok, t()} | {:error, term()}
  def set_time_sigs(%__MODULE__{} = runtime, events),
    do: run(runtime, Command.set_time_sigs(events))

  # --- 阶梯式 tempo 事件（全局 tempo 轨，2026-09-05 第四批） ---

  # tempo 手势的语义决定（详见 docs/plan-2026-09-ui-facade-gestures.md
  # "第四批语义决定"）：台阶 span 端点名义化（消费侧只读起点）；同 tick
  # 台阶拒绝；首事件禁删沿用 Coconut 校验；tempo 不进 pin 输入底料。
  @tempo_track_id "global:tempo"
  # 与引擎空 tempo 轨回退一致（Coconut.Render.Engine.Snapshot：flat 120 BPM）。
  @default_bpm 120

  @doc "当前 tempo 阶梯（tick 升序）：`[%{id, tick, milli_bpm}]`；空轨为 `[]`。只读。"
  @spec tempo_steps(t()) :: [%{id: term(), tick: non_neg_integer(), milli_bpm: pos_integer()}]
  def tempo_steps(%__MODULE__{} = runtime) do
    case fetch_tempo_track(runtime) do
      {:ok, track} ->
        track
        |> Track.view()
        |> Enum.map(fn {id, element, {start, _end}} ->
          %{id: id, tick: start, milli_bpm: element.bpm}
        end)
        |> Enum.sort_by(fn %{tick: tick} -> tick end)

      :error ->
        []
    end
  end

  @doc """
  在 `tick` 处插入一个 tempo 台阶（`bpm` 为每四分音符拍数，cast 时归一为
  精确 milli-bpm；`{num, den}` 有理数形式也接受）。

  同 tick 已有台阶返回 `{:error, {:tempo_tick_occupied, tick}}`（阶梯语义
  下同 tick 两台阶无意义）。
  """
  @spec insert_tempo_step(
          t(),
          term(),
          non_neg_integer(),
          number() | {pos_integer(), pos_integer()}
        ) ::
          {:ok, t()} | {:error, term()}
  def insert_tempo_step(%__MODULE__{} = runtime, step_id, tick, bpm)
      when is_integer(tick) and tick >= 0 do
    with :ok <- check_tempo_tick_free(runtime, tick) do
      edit(runtime, %Coconut.Edit.Operations.InsertNote{
        track_id: @tempo_track_id,
        note_id: step_id,
        after_id: tempo_step_after(runtime, tick),
        span: {tick, tick + 1},
        attrs: %{bpm: bpm}
      })
    end
  end

  # 公开边界不落异常：非法 tick 返回 tagged error。
  def insert_tempo_step(%__MODULE__{}, _step_id, tick, _bpm),
    do: {:error, {:invalid_tick, tick}}

  @doc "改台阶 bpm（内容编辑，一条历史边）。"
  @spec edit_tempo_step(t(), term(), number() | {pos_integer(), pos_integer()}) ::
          {:ok, t()} | {:error, term()}
  def edit_tempo_step(%__MODULE__{} = runtime, step_id, bpm) do
    edit(runtime, %Coconut.Edit.Operations.EditNote{
      track_id: @tempo_track_id,
      note_id: step_id,
      changes: %{bpm: bpm}
    })
  end

  @doc "删台阶；首事件受 Coconut 保护（`{:error, {:tempo_first_protected, id}}`）。"
  @spec delete_tempo_step(t(), term()) :: {:ok, t()} | {:error, term()}
  def delete_tempo_step(%__MODULE__{} = runtime, step_id) do
    edit(runtime, %Coconut.Edit.Operations.DeleteNote{
      track_id: @tempo_track_id,
      note_id: step_id
    })
  end

  @doc """
  区间物理时长（秒）：当前 tempo 阶梯下 `[start_tick, end_tick)` 的换算
  （`Coconut.Edit.Workspace.region_duration_sec/3` 的包装）。空 tempo 轨
  回退到引擎同款 flat 120 BPM——查询总是可回答。
  """
  @spec region_duration_sec(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, float()} | {:error, term()}
  def region_duration_sec(%__MODULE__{} = runtime, start_tick, end_tick) do
    workspace = Coconut.workspace(runtime.session)

    case Workspace.region_duration_sec(workspace, start_tick, end_tick) do
      {:ok, sec} ->
        {:ok, sec}

      {:error, :missing_tempo_track} ->
        {:ok, (end_tick - start_tick) * 60 / (@default_bpm * workspace.tpqn)}

      {:error, _} = error ->
        error
    end
  end

  defp fetch_tempo_track(runtime) do
    case Workspace.fetch_track(Coconut.workspace(runtime.session), @tempo_track_id) do
      {:ok, track} -> {:ok, track}
      {:error, _} -> :error
    end
  end

  defp check_tempo_tick_free(runtime, tick) do
    if Enum.any?(tempo_steps(runtime), &(&1.tick == tick)) do
      {:error, {:tempo_tick_occupied, tick}}
    else
      :ok
    end
  end

  # 插入锚：space 序中起点严格小于 tick 的最后一个台阶，否则 :head。
  defp tempo_step_after(runtime, tick) do
    case fetch_tempo_track(runtime) do
      {:ok, track} ->
        track
        |> Track.view()
        |> Enum.filter(fn {_id, _element, {start, _end}} -> start < tick end)
        |> List.last(:head)
        |> case do
          :head -> :head
          {id, _element, _span} -> id
        end

      :error ->
        :head
    end
  end

  @doc "通过工程唯一 Session 提交 Coconut 编辑手势，包括原子跨轨手势。"
  @spec edit(t(), Coconut.Edit.Operation.request(), keyword()) :: {:ok, t()} | {:error, term()}
  def edit(%__MODULE__{} = runtime, request, opts \\ []) do
    with {:ok, session} <- Coconut.edit(runtime.session, request, opts),
         {:ok, runtime} <- replace_session(runtime, session) do
      {:ok, runtime}
    end
  end

  @doc "通过工程唯一 Session 提交已解析结构命令。"
  @spec run(t(), Command.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def run(%__MODULE__{} = runtime, %Command{} = command, opts \\ []) do
    with {:ok, session} <- Coconut.run(runtime.session, command, opts),
         {:ok, runtime} <- replace_session(runtime, session) do
      {:ok, runtime}
    end
  end

  @doc "撤销工程中的上一条历史边，无论它来自哪条轨道。"
  @spec undo(t()) :: {:ok, t()} | {:error, term()}
  def undo(%__MODULE__{} = runtime), do: move_history(runtime, &Coconut.undo/1)

  @doc "重做工程中的下一条历史边。"
  @spec redo(t()) :: {:ok, t()} | {:error, term()}
  def redo(%__MODULE__{} = runtime), do: move_history(runtime, &Coconut.redo/1)

  @spec notes(t(), Track.track_id()) :: {:ok, Track.view()} | {:error, term()}
  def notes(%__MODULE__{} = runtime, track_id) do
    with {:ok, editor} <- attach_editor(runtime, track_id), do: Editor.notes(editor)
  end

  @spec insert_note(t(), Track.track_id(), term(), term() | :head, Track.span(), map()) ::
          {:ok, t()} | {:error, term()}
  def insert_note(runtime, track_id, note_id, after_id, span, attrs) do
    invoke_track(runtime, track_id, fn editor ->
      Editor.insert_note(editor, note_id, after_id, span, attrs)
    end)
  end

  @spec edit_note(t(), Track.track_id(), term(), map()) :: {:ok, t()} | {:error, term()}
  def edit_note(runtime, track_id, note_id, changes),
    do: invoke_track(runtime, track_id, &Editor.edit_note(&1, note_id, changes))

  @spec drag_note(t(), Track.track_id(), term(), term() | :head, Track.span()) ::
          {:ok, t()} | {:error, term()}
  def drag_note(runtime, track_id, note_id, after_id, span),
    do: invoke_track(runtime, track_id, &Editor.drag_note(&1, note_id, after_id, span))

  @spec delete_note(t(), Track.track_id(), term()) :: {:ok, t()} | {:error, term()}
  def delete_note(runtime, track_id, note_id),
    do: invoke_track(runtime, track_id, &Editor.delete_note(&1, note_id))

  @spec split_note(t(), Track.track_id(), term(), integer(), term()) ::
          {:ok, t()} | {:error, term()}
  def split_note(runtime, track_id, note_id, at_tick, new_id),
    do: invoke_track(runtime, track_id, &Editor.split_note(&1, note_id, at_tick, new_id))

  @spec trim_note(t(), Track.track_id(), term(), Track.span()) :: {:ok, t()} | {:error, term()}
  def trim_note(runtime, track_id, note_id, new_span),
    do: invoke_track(runtime, track_id, &Editor.trim_note(&1, note_id, new_span))

  @doc """
  合并相邻音符：`note_ids` 首元素为存活者（into），其余被吸收进墓地；
  须按轨序相邻。into 保留自身内容原样。

  pin 语义按 Tamale transport：被吸收音符上的 ordinal 锚不死亡，而是
  重定签到 into。返回 `{:ok, runtime, report}`；`report.moved_pins`
  逐项 `%{id, channel, from_note_id, note_id}` 报告这些搬家的 pin。
  """
  @spec merge_notes(t(), Track.track_id(), [term(), ...]) ::
          {:ok, t(), map()} | {:error, term()}
  def merge_notes(runtime, track_id, note_ids),
    do: invoke_track(runtime, track_id, &Editor.merge_notes(&1, note_ids))

  @doc """
  跨轨拖拽音符：源轨删除 + 目标轨以 `new_id` 插入内容副本，一条历史边。

  内容全量复制（pitch/lyric/annotation/metadata），但显式清除 melisma
  旗标（跨轨后原组必然不成立，旗标留着是死信）；pin 不迁移——源音符
  上的锚在写时 transport 死进源轨墓地。
  """
  @spec drag_note_across_tracks(
          t(),
          Track.track_id(),
          term(),
          Track.track_id(),
          term(),
          term() | :head,
          Track.span()
        ) :: {:ok, t()} | {:error, term()}
  def drag_note_across_tracks(
        %__MODULE__{} = runtime,
        from_track,
        note_id,
        to_track,
        new_id,
        after_id,
        span
      ) do
    with {:ok, attrs} <- copied_note_attrs(runtime, from_track, note_id) do
      edit(runtime, %Coconut.Edit.Operations.DragNoteAcrossTracks{
        from_track: from_track,
        note_id: note_id,
        to_track: to_track,
        new_id: new_id,
        after_id: after_id,
        span: span,
        attrs: attrs
      })
    end
  end

  # 内容副本的 attrs：Note 字段原样（metadata 平铺进 attrs，与
  # `Note.from_element/2` 的约定一致），melisma 旗标清除。
  defp copied_note_attrs(runtime, track_id, note_id) do
    with {:ok, track} <- Workspace.fetch_track(Coconut.workspace(runtime.session), track_id),
         {:ok, note} <- fetch_note(track, note_id) do
      attrs =
        %{pitch: note.key, lyric: note.lyric, annotation: note.annotation}
        |> Map.merge(note.metadata || %{})
        |> Map.delete("melisma")

      {:ok, attrs}
    end
  end

  defp fetch_note(track, note_id) do
    case Map.fetch(track.elements_by_id, note_id) do
      {:ok, note} -> {:ok, note}
      :error -> {:error, {:unknown_note, note_id}}
    end
  end

  @spec mount_pitch(t(), Track.track_id(), term(), term(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def mount_pitch(runtime, track_id, note_id, points, opts \\ []),
    do: invoke_track(runtime, track_id, &Editor.mount_pitch(&1, note_id, points, opts))

  @spec mount_pitch_curve(t(), Track.track_id(), term(), term(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def mount_pitch_curve(runtime, track_id, note_id, curve, opts \\ []),
    do: invoke_track(runtime, track_id, &Editor.mount_pitch_curve(&1, note_id, curve, opts))

  @spec mount_phoneme_duration(t(), Track.track_id(), term(), term(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def mount_phoneme_duration(runtime, track_id, note_id, durations, opts \\ []),
    do:
      invoke_track(
        runtime,
        track_id,
        &Editor.mount_phoneme_duration(&1, note_id, durations, opts)
      )

  @doc """
  物化 `note_id` 的 pin 身份底料（输入事实签名，见 `Neume.Identity`）。
  纯派生、不跑 G2P、不调 worker；只读，不改工程值——调用方可在
  ProjectServer 之外执行，再携 `pin:` 校验走 mount（见
  `Neume.Editor.probe_base/2`）。
  """
  @spec probe_pin(t(), Track.track_id(), term()) ::
          {:ok, Neume.Identity.input_base()} | {:error, term()}
  def probe_pin(%__MODULE__{} = runtime, track_id, note_id) do
    with {:ok, editor} <- attach_editor(runtime, track_id) do
      Editor.probe_base(editor, note_id)
    end
  end

  @doc """
  物化历史 pin 处的工程值（供"按 pin 渲染试听"）；各轨运行态按该
  历史快照的声库签名重建/复用。被 squash 或不存在的 pin 返回
  `{:error, {:unknown_node, pin}}`。
  """
  @spec at_pin(t(), History.node_id()) :: {:ok, t()} | {:error, term()}
  def at_pin(%__MODULE__{} = runtime, pin) do
    with {:ok, workspace} <- History.state_at(runtime.session.history, pin) do
      history = %{runtime.session.history | present: workspace}
      sync_tracks(%{runtime | session: %{runtime.session | history: history}})
    end
  end

  @doc "按 `(track_id, note_id, channel)` 卸载存活 pin（记入唯一 History）。"
  @spec unmount_pin(t(), Track.track_id(), term(), atom()) :: {:ok, t()} | {:error, term()}
  def unmount_pin(runtime, track_id, note_id, channel),
    do: invoke_track(runtime, track_id, &Editor.unmount_pin(&1, note_id, channel))

  @spec update_globals(t(), Track.track_id(), map()) :: {:ok, t()} | {:error, term()}
  def update_globals(runtime, track_id, knobs),
    do: invoke_track(runtime, track_id, &Editor.update_globals(&1, knobs))

  @spec globals(t(), Track.track_id()) :: {:ok, map()} | {:error, term()}
  def globals(%__MODULE__{} = runtime, track_id) do
    with {:ok, editor} <- attach_editor(runtime, track_id), do: {:ok, Editor.globals(editor)}
  end

  @spec repatch(t(), Track.track_id(), [map() | Coconut.Util.ID.t()]) ::
          {:ok, t(), [map()]} | {:error, term()}
  def repatch(runtime, track_id, entries),
    do: invoke_track(runtime, track_id, &Editor.repatch(&1, entries))

  @spec export_debug(t(), Track.track_id(), Path.t(), keyword()) ::
          {:ok, t(), Path.t()} | {:error, term()}
  def export_debug(runtime, track_id, path, opts \\ []),
    do: invoke_track(runtime, track_id, &Editor.export_debug(&1, path, opts))

  @spec put_mix(t(), Track.track_id(), map()) :: {:ok, t()} | {:error, term()}
  def put_mix(%__MODULE__{} = runtime, track_id, attrs) do
    with {:ok, track} <- Workspace.fetch_track(Coconut.workspace(runtime.session), track_id),
         {:ok, track} <- TrackConfig.put_mix(track, attrs),
         {:ok, session} <-
           Coconut.run(runtime.session, Command.put_track_extras(track_id, track.extras)),
         {:ok, runtime} <- replace_session(runtime, session) do
      {:ok, runtime}
    end
  end

  @doc "重绑定轨道声库并重建该轨运行态；修改记入唯一 History。"
  @spec put_voicebank(t(), Track.track_id(), Entry.t()) :: {:ok, t()} | {:error, term()}
  def put_voicebank(%__MODULE__{} = runtime, track_id, %Entry{} = entry) do
    with {:ok, track} <- Workspace.fetch_track(Coconut.workspace(runtime.session), track_id),
         track <- TrackConfig.put_voicebank(track, entry.signature),
         {:ok, session} <-
           Coconut.run(runtime.session, Command.put_track_extras(track_id, track.extras)),
         {:ok, runtime} <- replace_session(runtime, session) do
      {:ok, runtime}
    end
  end

  @spec check(t()) :: {:ok, t(), map()} | {:error, {:check_failed, [map()]}}
  def check(%__MODULE__{} = runtime) do
    {tracks, reports, errors} =
      Enum.reduce(runtime.tracks, {%{}, %{}, []}, fn {track_id, track_runtime},
                                                     {tracks, reports, errors} ->
        with {:ok, editor} <- attach_editor(runtime, track_id),
             {:ok, editor, report} <- Editor.check(editor),
             {:ok, track_runtime} <- Editor.detach_runtime(editor) do
          {Map.put(tracks, track_id, track_runtime), Map.put(reports, track_id, report), errors}
        else
          {:error, {:check_failed, entries}} ->
            {Map.put(tracks, track_id, track_runtime), reports, errors ++ entries}

          {:error, reason} ->
            entry = %{kind: :track, track_id: track_id, reason: reason}
            {Map.put(tracks, track_id, track_runtime), reports, errors ++ [entry]}
        end
      end)

    runtime = %{runtime | tracks: tracks}
    if errors == [], do: {:ok, runtime, reports}, else: {:error, {:check_failed, errors}}
  end

  @spec render(t()) :: {:ok, t(), Neume.MixArtifact.t()} | {:error, term()}
  def render(%__MODULE__{} = runtime) do
    with {:ok, runtime, _reports} <- check(runtime),
         {:ok, tracks, artifacts} <- render_tracks(runtime),
         {:ok, artifact} <- MixPipeline.run(runtime.mix_pipeline, artifacts) do
      {:ok, %{runtime | tracks: tracks}, artifact}
    end
  end

  defp build_vocal_track(track_id, entry, attrs) do
    mix = Map.get(attrs, :mix, %{})

    with {:ok, track} <-
           Track.new(%{
             id: track_id,
             module: Track.Vocal,
             name: Map.get(attrs, :name),
             extras: %{}
           }),
         track <- TrackConfig.put_voicebank(track, entry.signature),
         {:ok, track} <- TrackConfig.put_mix(track, mix) do
      {:ok, track}
    end
  end

  defp track_channels do
    %{duration: Neume.Channels.DurationPin, pitch: Neume.Channels.PitchPin}
  end

  defp open_tracks(project, registry, opts) do
    project.workspace.tracks
    |> Enum.filter(fn {_id, track} -> track.module == Track.Vocal end)
    |> Enum.reduce_while({:ok, %{}}, fn {track_id, track}, {:ok, acc} ->
      case open_track(project, track_id, track, registry, opts) do
        {:ok, track_runtime} -> {:cont, {:ok, Map.put(acc, track_id, track_runtime)}}
        {:error, reason} -> {:halt, {:error, {:track_open_failed, track_id, reason}}}
      end
    end)
  end

  defp open_track(project, track_id, track, registry, opts) do
    case TrackConfig.voicebank(track) do
      nil ->
        {:error, :voicebank_required}

      signature ->
        with {:ok, entry} <- Registry.resolve(registry, signature),
             {:ok, editor} <-
               Editor.open(
                 project,
                 opts
                 |> Keyword.put(:track_id, track_id)
                 |> Keyword.put(:voicebank_entry, entry)
               ),
             {:ok, track_runtime} <- Editor.detach_runtime(editor) do
          {:ok, track_runtime}
        end
    end
  end

  defp attach_editor(runtime, track_id) do
    with {:ok, track_runtime} <- fetch_runtime(runtime, track_id) do
      Editor.attach_runtime(track_runtime, runtime.session, runtime.pickle_registry)
    end
  end

  defp fetch_runtime(runtime, track_id) do
    case Map.fetch(runtime.tracks, track_id) do
      {:ok, track_runtime} -> {:ok, track_runtime}
      :error -> {:error, {:unknown_track, track_id}}
    end
  end

  defp invoke_track(%__MODULE__{} = runtime, track_id, fun) when is_function(fun, 1) do
    with {:ok, editor} <- attach_editor(runtime, track_id) do
      case fun.(editor) do
        {:ok, %Editor{} = editor} ->
          adopt_editor(runtime, editor)

        {:ok, %Editor{} = editor, value} ->
          with {:ok, runtime} <- adopt_editor(runtime, editor) do
            {:ok, runtime, value}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp adopt_editor(runtime, editor) do
    with {:ok, track_runtime} <- Editor.detach_runtime(editor) do
      session = %{runtime.session | history: editor.session.history, last_round: nil}

      runtime = %{
        runtime
        | session: session,
          tracks: Map.put(runtime.tracks, editor.track_id, track_runtime)
      }

      sync_tracks(runtime)
    end
  end

  defp move_history(runtime, move) do
    with {:ok, session} <- move.(runtime.session),
         {:ok, runtime} <- replace_session(runtime, session) do
      {:ok, runtime}
    end
  end

  defp replace_session(runtime, session), do: sync_tracks(%{runtime | session: session})

  defp sync_tracks(runtime) do
    with {:ok, project} <- Coconut.project(runtime.session) do
      project.workspace.tracks
      |> Enum.filter(fn {_id, track} -> track.module == Track.Vocal end)
      |> Enum.reduce_while({:ok, %{}}, fn {track_id, track}, {:ok, acc} ->
        signature = TrackConfig.voicebank(track)

        case runtime.tracks do
          %{^track_id => %TrackRuntime{voicebank: ^signature} = track_runtime} ->
            {:cont, {:ok, Map.put(acc, track_id, track_runtime)}}

          _ ->
            case open_track(
                   project,
                   track_id,
                   track,
                   runtime.voicebank_registry,
                   runtime.open_opts
                 ) do
              {:ok, track_runtime} -> {:cont, {:ok, Map.put(acc, track_id, track_runtime)}}
              {:error, reason} -> {:halt, {:error, {:track_open_failed, track_id, reason}}}
            end
        end
      end)
      |> case do
        {:ok, tracks} -> {:ok, %{runtime | tracks: tracks}}
        {:error, _} = error -> error
      end
    end
  end

  defp render_tracks(runtime) do
    Enum.reduce_while(runtime.tracks, {:ok, %{}, []}, fn {track_id, _track_runtime},
                                                         {:ok, tracks, artifacts} ->
      with {:ok, editor} <- attach_editor(runtime, track_id),
           {:ok, editor, artifact} <- Editor.render(editor),
           {:ok, track_runtime} <- Editor.detach_runtime(editor),
           {:ok, track} <- Workspace.fetch_track(Coconut.workspace(runtime.session), track_id) do
        item = %{track_id: track_id, artifact: artifact, mix: TrackConfig.mix(track)}
        {:cont, {:ok, Map.put(tracks, track_id, track_runtime), [item | artifacts]}}
      else
        {:error, reason} -> {:halt, {:error, {:track_render_failed, track_id, reason}}}
      end
    end)
    |> case do
      {:ok, tracks, artifacts} -> {:ok, tracks, Enum.reverse(artifacts)}
      {:error, _} = error -> error
    end
  end
end
