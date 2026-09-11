defmodule Neume.Editor do
  @moduledoc """
  Neume 的无界面编辑入口。

  编辑状态由 `Coconut.Session` 持有；Neume 只负责把具名编辑动作、工程
  存取和固定的合成图收束成一个宿主 API。undo/redo 历史随工程存档（v2
  信封，`Coconut.Pickle.File`）保存与恢复；最近一次检查结果是会话状态，
  不写入工程文件。
  """

  alias Coconut.Edit.{Command, Patch, Track, Workspace}
  alias Coconut.Edit.Operations.{DeleteNote, DragNote, EditNote, InsertNote, MergeNotes, TrimNote}
  alias Coconut.Pickle.File
  alias Coconut.Pickle.Track, as: PickleTrack
  alias Coconut.Project
  alias Coconut.Util.ID
  alias Neume.Channels.{DurationPin, PitchPin}
  alias Neume.{Identity, PitchCurve, TrackConfig, TrackRuntime}
  alias Neume.Pin.{Context, Resolved, Schema, Semantics}
  alias Neume.Engine.{MockPipeline, OrchidError}
  alias Neume.Voicebank.Entry
  alias Neume.Voicebank.Registry, as: VoicebankRegistry

  # 后面可以用 Coconut.Util.ID.generate_id("Track_") 来代替
  @default_track_id "vocal"
  @default_ticks_per_frame 10

  @enforce_keys [:session, :registry, :track_id, :pipeline, :pipeline_state]
  defstruct [:session, :registry, :track_id, :pipeline, :pipeline_state]

  @type t :: %__MODULE__{
          session: Coconut.Session.t(),
          registry: Coconut.Pickle.Registry.t(),
          track_id: Track.track_id(),
          pipeline: module(),
          pipeline_state: term()
        }

  @doc "新建一个带单条人声轨的工程，并打开编辑会话。"
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) when is_list(opts) do
    track_id = Keyword.get(opts, :track_id, @default_track_id)

    with {:ok, voicebank, opts} <- prepare_new_voicebank(opts),
         {:ok, track} <- Track.new(%{id: track_id, module: Track.Vocal}),
         track <- TrackConfig.put_voicebank(track, voicebank),
         {:ok, workspace} <-
           Workspace.new(%{
             id: Keyword.get(opts, :workspace_id, ID.generate_id("WSpc_")),
             tracks: %{track_id => track}
           }),
         {:ok, project} <-
           Project.new(%{
             id: Keyword.get(opts, :project_id, ID.generate_id("Proj_")),
             workspace: workspace,
             voicebank: nil,
             metadata: Keyword.get(opts, :metadata, %{})
           }) do
      open(project, opts)
    end
  end

  @doc """
  从内存中的 Coconut 工程打开一个新会话。

  `opts[:history]` 给出恢复的 `Coconut.Edit.History`（如
  `Coconut.Pickle.File.read_with_history/2` 的产物）时挂载它，否则从
  空树开始。
  """
  @spec open(Project.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(%Project{} = project, opts \\ []) when is_list(opts) do
    track_id = Keyword.get(opts, :track_id, @default_track_id)
    ticks_per_frame = Keyword.get(opts, :ticks_per_frame, @default_ticks_per_frame)
    registry = Keyword.get(opts, :registry, PickleTrack.default_registry())

    with {:ok, %Track{module: Track.Vocal} = selected_track} <-
           Workspace.fetch_track(project.workspace, track_id),
         expected_signature <- TrackConfig.voicebank(selected_track),
         {:ok, opts} <- prepare_selected_open_opts(expected_signature, opts),
         {:ok, voicebank_entry} <- prepare_open_voicebank(expected_signature, opts),
         :ok <- validate_ticks_per_frame(ticks_per_frame),
         {:ok, %Track{module: Track.Vocal} = track} <-
           Workspace.fetch_track(project.workspace, track_id),
         {:ok, mounted} <- mounted_globals(track),
         {:ok, pipeline, pipeline_state} <-
           compile_pipeline(voicebank_entry, track_id, ticks_per_frame, opts),
         engine_config <- pipeline.engine_config(pipeline_state, track_id),
         {:ok, session} <-
           Coconut.new(project,
             channels: %{duration: DurationPin, pitch: PitchPin},
             engine: {CoconutOi.OrchidAdapter, engine_config},
             globals: mounted,
             history: Keyword.get(opts, :history, [])
           ) do
      {:ok,
       %__MODULE__{
         session: session,
         registry: registry,
         track_id: track_id,
         pipeline: pipeline,
         pipeline_state: pipeline_state
       }}
    else
      {:ok, %Track{module: module}} -> {:error, {:not_vocal_track, track_id, module}}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec detach_runtime(t()) :: {:ok, TrackRuntime.t()} | {:error, term()}
  def detach_runtime(%__MODULE__{} = editor) do
    with {:ok, track} <- current_track(editor) do
      {:ok,
       %TrackRuntime{
         track_id: editor.track_id,
         voicebank: TrackConfig.voicebank(track),
         pipeline: editor.pipeline,
         pipeline_state: editor.pipeline_state,
         engine: editor.session.engine,
         channels: editor.session.channels,
         interventions: editor.session.interventions
       }}
    end
  end

  @doc false
  @spec attach_runtime(TrackRuntime.t(), Coconut.Session.t(), Coconut.Pickle.Registry.t()) ::
          {:ok, t()} | {:error, term()}
  def attach_runtime(
        %TrackRuntime{} = runtime,
        %Coconut.Session{} = canonical_session,
        %Coconut.Pickle.Registry{} = registry
      ) do
    session = %{
      canonical_session
      | engine: runtime.engine,
        channels: runtime.channels,
        interventions: runtime.interventions,
        globals: %{},
        last_round: nil
    }

    sync_mounted_globals(%__MODULE__{
      session: session,
      registry: registry,
      track_id: runtime.track_id,
      pipeline: runtime.pipeline,
      pipeline_state: runtime.pipeline_state
    })
  end

  @doc """
  从工程文件打开会话；v2 档恢复存档的 undo/redo 历史，v1 旧档（无
  `history` 字段）从空树开始。
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(path, opts \\ []) when is_list(opts) do
    registry = Keyword.get(opts, :registry, PickleTrack.default_registry())

    with {:ok, project, history} <- File.read_with_history(path, registry) do
      opts = opts |> Keyword.put(:registry, registry) |> Keyword.put(:history, history || [])
      open(project, opts)
    end
  end

  @doc "保存当前工程快照（含 undo/redo 历史）；最近一次 render check 状态不持久化。"
  @spec save(t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def save(%__MODULE__{} = editor, path) do
    with {:ok, project} <- Coconut.project(editor.session) do
      File.write(project, editor.registry, path, history: editor.session.history)
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

  @doc """
  修剪音符时值（span 边缘拖拽）。

  melisma 组成员关系按旗标 + 贴接自动派生：trim 拖出缝隙即自然断组，
  不做手势期特殊处理；duration pin 超预算不在手势期拒绝，走
  `check/1` 的裁决界面。
  """
  @spec trim_note(t(), term(), Track.span()) :: {:ok, t()} | {:error, term()}
  def trim_note(%__MODULE__{} = editor, note_id, new_span) do
    with {:ok, track} <- current_track(editor),
         {:ok, old_span} <- fetch_span(track, note_id) do
      apply_edit(editor, %TrimNote{
        track_id: editor.track_id,
        note_id: note_id,
        old_span: old_span,
        new_span: new_span
      })
    end
  end

  @doc """
  合并相邻音符：`note_ids` 首元素为存活者（into），其余被吸收进墓地；
  须按轨序相邻。into 保留自身内容原样（歌词/音素不拼接）。

  pin 语义按 Tamale transport：被吸收音符上的 ordinal 锚**不死亡**，而是
  重定签到 into——"合并后这个 pin 是否还有意义"由 `check/1` /
  `repatch/2` 的裁决界面判定。返回 `{:ok, editor, report}`，
  `report.moved_pins` 逐项 `%{id, channel, from_note_id, note_id}` 显式
  报告这些搬家的 pin（不许静默）。
  """
  @spec merge_notes(t(), [term(), ...]) :: {:ok, t(), map()} | {:error, term()}
  def merge_notes(%__MODULE__{} = editor, note_ids) do
    with {:ok, track_before} <- current_track(editor),
         {:ok, editor} <-
           apply_edit(editor, %MergeNotes{track_id: editor.track_id, note_ids: note_ids}),
         {:ok, track_after} <- current_track(editor) do
      {:ok, editor, %{moved_pins: moved_pins_since(track_before, track_after, hd(note_ids))}}
    end
  end

  # 本手势中锚被重定签的 pin：合并前锚在非 into 音符上、合并后仍在册但
  # 锚指向了别处（Tamale Merge 把被吸收者的 ordinal 锚重映射到 into）。
  defp moved_pins_since(%Track{} = before, %Track{} = after_, into) do
    after_by_id = Map.new(after_.patches, &{&1.id, &1})

    Enum.flat_map(before.patches, fn patch ->
      from = anchor_note_id(patch)

      with true <- from != nil and from != into,
           %Patch{} = moved when is_struct(moved) <- Map.get(after_by_id, patch.id),
           to when to != from <- anchor_note_id(moved) do
        [%{id: patch.id, channel: patch.channel, from_note_id: from, note_id: to}]
      else
        _other -> []
      end
    end)
  end

  defp anchor_note_id(%Patch{anchor: %Tamale.Anchor.Ordinal{refs: [note_id | _]}}), do: note_id
  defp anchor_note_id(_patch), do: nil

  @doc """
  在 `at_tick` 拆分音符：左子继承原 id，右子 `new_id` 自动获得 melisma
  续音旗标（拆分 = 同音节延续）。整手势是一条历史边，undo 一次即还原。
  """
  @spec split_note(t(), term(), non_neg_integer(), term()) :: {:ok, t()} | {:error, term()}
  def split_note(%__MODULE__{} = editor, note_id, at_tick, new_id) do
    apply_edit(editor, %Neume.Operations.SplitNote{
      track_id: editor.track_id,
      note_id: note_id,
      at_tick: at_tick,
      new_id: new_id
    })
  end

  @doc """
  在音符上挂载 pitch 控制点（批次 B 起默认产出 `score_pitch_v2`）。

  入参 `points` 仍是绝对 tick → MIDI 的稀疏折线（`[[tick, midi], ...]`）；
  挂载时按当前 span 起点换算为音符内相对 tick（`note_tick` transport，
  拖动自然跟随），payload 为自描述 envelope
  `%{schema: "score_pitch_v2", coordinates: "note_tick", values: ...}`。
  v2 身份底料是 `score_region_v1`（只钉 track/note 与坐标系；改词、换
  声库、改音高不炸）；旧 `pitch_points_v1` / `pitch_curve_v1` payload
  继续签 `pin_input_v1` 输入事实底料（见 `Neume.Identity`），可读可渲染。

  选项（两阶段挂载用）：

  - `:base` — 显式签名底料（兼容入口；缺省时经 channel 语义按 payload
    schema 现场推导）；
  - `:pin` — History cursor 版本钉；与当前 cursor 不符时返回
    `{:error, {:stale_pin, _}}`，不落历史边。
  """
  @spec mount_pitch(t(), term(), [[number()]], keyword()) :: {:ok, t()} | {:error, term()}
  def mount_pitch(%__MODULE__{} = editor, note_id, points, opts \\ []) do
    with {:ok, normalized} <- PitchCurve.normalize(points),
         {:ok, payload} <- pitch_mount_payload(editor, note_id, normalized),
         {:ok, editor, _patch} <- mount_pin(editor, note_id, :pitch, payload, opts) do
      {:ok, editor}
    end
  end

  # 批次 B：点列 mount 默认产出 `score_pitch_v2`（note_tick transport）；
  # 绝对 tick 输入按当前 span 起点换算为相对 tick。Bezier envelope 本批
  # 保持 legacy `pitch_curve_v1` 不变。
  defp pitch_mount_payload(_editor, _note_id, %{format: :pitch_curve_v1} = curve),
    do: {:ok, curve}

  defp pitch_mount_payload(%__MODULE__{} = editor, note_id, points) when is_list(points) do
    with {:ok, track} <- current_track(editor),
         {:ok, {start_tick, _end_tick}} <- fetch_span(track, note_id) do
      {:ok,
       Schema.score_pitch_v2_payload(
         Enum.map(points, fn [tick, midi] -> [tick - start_tick, midi] end)
       )}
    end
  end

  @doc """
  在音符上挂载 identity-base Bezier pitch intervention。

  控制点使用绝对 tick + 绝对 MIDI；handle 是相对 anchor 的 tick/value 偏移。
  payload 降为可 Pickle 的版本化 plain map，宿主按真实声学帧网格调用 Coconut
  Bezier adapter 栅格化，worker 不重复实现曲线数学。

  `curve` 可以是 `Coconut.Curve.Adapter.Bezier` struct 或同语义的 plain-map
  payload（facade 边界只传后者）。选项同 `mount_pitch/4`。
  """
  @spec mount_pitch_curve(t(), term(), Coconut.Curve.Adapter.Bezier.t() | map(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def mount_pitch_curve(%__MODULE__{} = editor, note_id, curve, opts \\ []) do
    with {:ok, payload} <- curve_payload(curve),
         {:ok, editor, _patch} <- mount_pin(editor, note_id, :pitch, payload, opts) do
      {:ok, editor}
    end
  end

  # Bezier struct 在 Editor 内降为 payload；facade 边界来的 plain map 直接
  # 走版本化校验。
  defp curve_payload(%Coconut.Curve.Adapter.Bezier{} = curve),
    do: PitchCurve.from_bezier(curve)

  defp curve_payload(payload), do: PitchCurve.normalize(payload)

  @doc """
  在音符上挂载逐音素的稀疏时长 pin：`[[音素下标, tick 时长], ...]`。

  底料与裁决同 `mount_pitch/4`；下标指向 probe 物化序列中的音素。
  选项同 `mount_pitch/4`。
  """
  @spec mount_phoneme_duration(t(), term(), [[non_neg_integer()]], keyword()) ::
          {:ok, t()} | {:error, term()}
  def mount_phoneme_duration(%__MODULE__{} = editor, note_id, durations, opts \\ []) do
    case mount_pin(editor, note_id, :duration, durations, opts) do
      {:ok, editor, _patch} -> {:ok, editor}
      {:error, _} = error -> error
    end
  end

  @doc """
  物化 `note_id` 的 legacy 输入事实底料（§6.6，见 `Neume.Identity`）。

  纯派生：只读当前会话的乐谱事实与声库摘要，不跑 G2P、不调 worker。
  只读，不改会话。挂载路径的底料自批次 B 起由 channel 语义按 payload
  schema 现场推导（`mount_pin` 的 `base/4` 分派），本函数只作只读
  probe/校验入口（legacy 底料的显式签名仍可经 `opts[:base]` 传入）。
  """
  @spec probe_base(t(), term()) :: {:ok, Identity.input_base()} | {:error, term()}
  def probe_base(%__MODULE__{} = editor, note_id) do
    with {:ok, track} <- current_track(editor) do
      Identity.base_for(track, note_id, voicebank_digest(editor))
    end
  end

  # pin 输入底料的声音库事实分量（mock 无声库，为 nil）。
  defp voicebank_digest(%__MODULE__{} = editor),
    do: editor.pipeline.voicebank_digest(editor.pipeline_state)

  # 字典级 phonology 摘要分量（批次 C）：runtime 未实现回调时为 nil——
  # legacy 路径不消费本分量；v2 Ph/Co 语义（批次 D）在缺失时给 tagged
  # error，不在此回退全量摘要。
  defp phonology_digest(%__MODULE__{} = editor) do
    if function_exported?(editor.pipeline, :phonology_digest, 1),
      do: editor.pipeline.phonology_digest(editor.pipeline_state),
      else: nil
  end

  @doc """
  按 `(note_id, channel)` 卸载 pin：存活 patch 移入墓地，记一条历史边
  （undo 一次还原）。该音符该 channel 无存活 pin 时返回
  `{:error, {:pin_not_found, note_id, channel}}`，状态不变。
  """
  @spec unmount_pin(t(), term(), atom()) :: {:ok, t()} | {:error, term()}
  def unmount_pin(%__MODULE__{} = editor, note_id, channel) do
    with {:ok, track} <- current_track(editor) do
      patches =
        Enum.filter(track.patches, fn
          %Patch{anchor: %Tamale.Anchor.Ordinal{refs: [ref | _]}, channel: ^channel} ->
            ref == note_id

          _other ->
            false
        end)

      case patches do
        [] ->
          {:error, {:pin_not_found, note_id, channel}}

        _patches ->
          with {:ok, session} <-
                 Coconut.discard_patches(editor.session, patches, :unmounted) do
            {:ok, %{editor | session: session}}
          end
      end
    end
  end

  @doc """
  更新轨道级全局旋钮（key 合并，nil 删除该键）。

  旋钮是轨道挂载的工程事实：存于 `track.extras[:neume][:globals]`，经
  `Command.put_track_extras` 落一条历史边（undo/redo 生效），随工程
  保存/加载往返；写入后同步派生到会话 render 配置，直进 render，不经
  tamale patch。当前声明白名单是 `:energy` / `:breathiness` / `:voicing`
  （variance 预测曲线的乘性系数，`1.0` 中立，合法范围 0.0–2.0）；未知键
  或越界值在 `check/1` 的门禁聚合为 `%{kind: :global, ...}` entry。
  无变化的调用不落历史边。
  """
  @spec update_globals(t(), map()) :: {:ok, t()} | {:error, term()}
  def update_globals(%__MODULE__{} = editor, knobs) when is_map(knobs) do
    with {:ok, track} <- current_track(editor),
         {:ok, current} <- mounted_globals(track),
         merged <- merge_knobs(current, knobs),
         {:ok, session} <- put_globals(editor.session, track, merged) do
      {:ok, %{editor | session: session}}
    end
  end

  @doc "当前轨道挂载的全局旋钮（不含管线编译期默认值）。"
  @spec globals(t()) :: map()
  def globals(%__MODULE__{} = editor), do: editor.session.globals

  @doc """
  导出调试 JSON（`Neume.DebugExport`，`tools/plot_render.py` 可画）。

  Track 维度（当前 editor 的轨）+ 可选 `span: {start_tick, end_tick}` 裁剪；
  `raw?: true` 时附带一次无 pin 的对照 probe（`frames_raw`/`phonemes_raw`）。
  导出前跑完整 check + probe（与 render 同一裁决路径），冲突即失败。
  返回写出的路径。
  """
  @spec export_debug(t(), Path.t(), keyword()) :: {:ok, t(), Path.t()} | {:error, term()}
  def export_debug(%__MODULE__{} = editor, path, opts \\ []) do
    with {:ok, editor, request, analysis, _checked, _pins} <- checked_probe(editor),
         {:ok, raw} <- maybe_raw_probe(editor, request, Keyword.get(opts, :raw?, false)),
         {:ok, data} <-
           Neume.DebugExport.build(
             request.snapshot,
             editor.track_id,
             analysis,
             alive_patches(editor),
             span: opts[:span],
             raw: raw
           ) do
      {:ok, editor, Neume.DebugExport.write!(data, path)}
    end
  end

  # 无干预对照 probe：pins 传空，同一 globals——raw 与 effective 的唯一
  # 差异就是干预本身。
  defp maybe_raw_probe(_editor, _request, raw?) when raw? in [nil, false], do: {:ok, nil}

  defp maybe_raw_probe(editor, request, true) do
    editor.pipeline.analyze(
      editor.pipeline_state,
      request.snapshot,
      %{},
      request.globals,
      editor.track_id
    )
  end

  defp alive_patches(editor) do
    workspace = Coconut.Edit.History.current(editor.session.history).workspace

    case Map.fetch(workspace.tracks, editor.track_id) do
      {:ok, track} -> track.patches
      :error -> []
    end
  end

  @doc """
  批量重挂手势（§6.6 re-patch）：把 check 冲突 entry 里的 pin 在新底料上
  重签。payload 仍可表达（下标在界内等）则保留重签；否则降级报告为
  `:degraded`（旧 patch 原样保留，由调用方修改后重新挂载）。

  整批重挂是一条历史边（undo 一次全还原），与死 patch、adopt 失败共用
  同一个冲突裁决界面。entry 的 patch 必须仍在册；已进墓地的 patch 请用
  `mount_pitch/4` / `mount_phoneme_duration/4` 重新挂载。

  entry 可以是 check 冲突 entry（`%{patch: %Coconut.Edit.Patch{}}`），
  也可以是纯 plain-data 引用——patch id 或 `%{patch_id: id}`（facade
  边界只传后者）。

  返回 `{:ok, editor, results}`，`results` 逐项为
  `%{patch_id, status: :repatched}` 或 `%{patch_id, status: :degraded,
  reason}`。
  """
  @spec repatch(t(), [map() | Coconut.Util.ID.t()]) :: {:ok, t(), [map()]} | {:error, term()}
  def repatch(%__MODULE__{} = editor, []), do: {:ok, editor, []}

  def repatch(%__MODULE__{} = editor, entries) when is_list(entries) do
    with {:ok, patches} <- fetch_alive_patches(editor, entries),
         {:ok, request} <- Coconut.request(editor.session),
         {:ok, sequences} <- probe_sequences(editor, request, patches),
         {:ok, track} <- current_track(editor),
         {:ok, discards, attaches, results} <-
           plan_repatch(
             patches,
             sequences,
             track,
             voicebank_digest(editor),
             phonology_digest(editor),
             editor.session.channels
           ),
         {:ok, session} <- run_repatch(editor.session, discards, attaches) do
      {:ok, %{editor | session: session}, results}
    end
  end

  # 只有声明需要 probe 的 payload（如旧 duration 的裸 ph_index）才调
  # pipeline.phonemes/3；纯 Pin<S>（pitch）批次不强迫引擎实现音素展开。
  # 无法判定时保守按需要 probe 处理，后续校验会给出 tagged error。
  defp probe_sequences(editor, request, patches) do
    if Enum.any?(patches, &requires_probe?(&1, editor.session.channels)) do
      editor.pipeline.phonemes(editor.pipeline_state, request.snapshot, editor.track_id)
    else
      {:ok, nil}
    end
  end

  defp requires_probe?(patch, channels) do
    with {:ok, semantics} <- Map.fetch(channels, patch.channel),
         true <- Semantics.implemented?(semantics),
         true <- function_exported?(semantics, :requires_probe?, 2),
         {:ok, descriptor} <- semantics.describe(patch.patch.payload) do
      semantics.requires_probe?(descriptor, patch.patch.payload)
    else
      _other -> true
    end
  end

  # 全部降级 = 无写入，不落历史边。
  defp run_repatch(session, [], []), do: {:ok, session}

  defp run_repatch(session, discards, attaches),
    do: Coconut.run(session, Command.repatch_patches(discards, attaches))

  @doc "撤销一步编辑。"
  @spec undo(t()) :: {:ok, t()} | {:error, term()}
  def undo(%__MODULE__{} = editor), do: move_history(editor, &Coconut.undo/1)

  @doc "重做一步编辑。"
  @spec redo(t()) :: {:ok, t()} | {:error, term()}
  def redo(%__MODULE__{} = editor), do: move_history(editor, &Coconut.redo/1)

  @doc """
  完成全部裁决后渲染：DiffSinger 走分窗增量路径，mock 走整轨图。

  渲染前先跑与 `check/1` 相同的静态 check + probe + 身份裁决；任何失败
  聚合为 `{:error, {:check_failed, entries}}`（与死 patch、adopt 失败
  共用冲突裁决界面）。管线自身的执行错误原样返回。
  """
  @spec render(t()) :: {:ok, t(), Neume.RenderArtifact.t()} | {:error, term()}
  def render(%__MODULE__{} = editor) do
    with {:ok, editor, request, _analysis, checked_phrases, pins} <- checked_probe(editor),
         {:ok, artifact} <- render_checked(editor, request, checked_phrases, pins) do
      {:ok, editor, artifact}
    end
  end

  defp render_checked(editor, request, checked, pins) do
    if function_exported?(editor.pipeline, :render_checked, 5) do
      editor.pipeline.render_checked(
        editor.pipeline_state,
        request.snapshot,
        checked,
        request.globals,
        editor.track_id
      )
    else
      editor.pipeline.render(
        editor.pipeline_state,
        request.snapshot,
        pins,
        request.globals,
        editor.track_id
      )
    end
  end

  @doc """
  analyze/align 闭环：不运行 acoustic/vocoder，返回 G2P 结果、duration
  预测和元音锚定后的音素边界（`Neume.Analysis`）。失败形状同 `render/1`。
  """
  @spec analyze(t()) :: {:ok, t(), Neume.Analysis.t()} | {:error, term()}
  def analyze(%__MODULE__{} = editor) do
    with {:ok, editor, _request, analysis, _checked, _pins} <- checked_probe(editor) do
      {:ok, editor, analysis}
    end
  end

  @doc """
  稳定的检查 API：静态 check（锚 transport + port 装配 + globals 门禁）
  → 模型级 probe（analyze 同款）→ pin 身份裁决（`Neume.Identity`，
  probe 期 `Tamale.Patch.resolve/2`）。所有失败聚合为
  `{:error, {:check_failed, entries}}`；模型侧 entry 形如
  `%{kind: :model, reason: term()}`，probe 期身份冲突形如
  `%{kind: :conflict, stage: :probe, patch: ..., reason: ...}`。
  """
  @spec check(t()) :: {:ok, t(), map()} | {:error, {:check_failed, [term()]}}
  def check(%__MODULE__{} = editor) do
    with {:ok, editor, _request, analysis, _checked, _pins} <- checked_probe(editor) do
      {:ok, editor, %{analysis: analysis}}
    end
  end

  # 三条公开路径（render/analyze/check）共用的裁决管线：
  # 静态 check → 模型 probe → 身份裁决；一切失败归一为 check_failed。
  defp checked_probe(%__MODULE__{} = editor) do
    case Coconut.check(editor.session) do
      {:ok, session} -> probe_and_adjudicate(%{editor | session: session})
      {:error, {:resolve_vetoed, entries}} -> {:error, {:check_failed, entries}}
      {:error, {:check_vetoed, entries}} -> {:error, {:check_failed, entries}}
      {:error, reason} -> {:error, {:check_failed, [%{kind: :static, reason: reason}]}}
    end
  end

  defp probe_and_adjudicate(%__MODULE__{} = editor) do
    %{request: request} = editor.session.last_round

    with {:ok, pins} <- lowered_pins(editor, request),
         {:ok, phrase_results, model_errors} <-
           editor.pipeline.analyze_phrases(
             editor.pipeline_state,
             request.snapshot,
             pins,
             request.globals,
             editor.track_id
           ),
         {:ok, analysis} <- merge_phrase_results(phrase_results, model_errors),
         {:ok, identity_errors} <- adjudicate_identity_errors(editor, analysis),
         [] <- model_errors ++ identity_errors do
      {:ok, editor, request, analysis, phrase_results, pins}
    else
      [_ | _] = entries ->
        {:error, {:check_failed, entries}}

      {:error, {:check_failed, _entries}} = error ->
        error

      {:error, reason} ->
        {:error, {:check_failed, [%{kind: :model, reason: OrchidError.slim(reason)}]}}
    end
  end

  defp merge_phrase_results([], [_ | _]), do: {:ok, nil}
  defp merge_phrase_results(results, _errors), do: Neume.Analysis.merge(results)

  # 身份裁决只依赖 workspace 事实与声库摘要，与模型 probe 成败无关；
  # 定位信息（phrase/span）在 analysis 可用时才补充。
  defp adjudicate_identity_errors(%__MODULE__{} = editor, analysis) do
    with {:ok, track} <- current_track(editor) do
      phrases = if analysis, do: analysis.phrases, else: []

      entries =
        track
        |> Identity.adjudicate(editor.session.channels, voicebank_digest(editor),
          phonology_digest: phonology_digest(editor)
        )
        |> Enum.map(&locate_identity_error(&1, editor.track_id, phrases))

      {:ok, entries}
    end
  end

  defp locate_identity_error(entry, track_id, phrases) do
    note_id = entry[:note_id] || patch_target(entry[:patch])
    phrase = Enum.find(phrases, &(note_id in &1.note_ids))

    entry
    |> Map.put_new(:track_id, track_id)
    |> maybe_put_location(phrase)
  end

  defp patch_target(%Patch{anchor: %{refs: [note_id | _]}}), do: note_id
  defp patch_target(_patch), do: nil

  defp maybe_put_location(entry, nil), do: entry

  defp maybe_put_location(entry, phrase) do
    entry
    |> Map.put(:phrase_id, phrase.id)
    |> Map.put(:span, {phrase.start_tick, phrase.end_tick})
  end

  # 挂载共用路径：底料经 channel 语义现场推导（`describe/1` 按 payload
  # 分派 schema → `base/4` 推导底料），显式 `:base` 仅作兼容入口；
  # `opts[:pin]` 透传 History 的 stale-write 校验。
  defp mount_pin(%__MODULE__{} = editor, note_id, channel, payload, opts) do
    with {:ok, semantics} <- fetch_semantics(editor.session.channels, channel),
         {:ok, descriptor} <- semantics.describe(payload),
         {:ok, base} <-
           mount_base(editor, note_id, semantics, descriptor, payload, Keyword.get(opts, :base)),
         {:ok, session, patch} <-
           Coconut.mount(editor.session, editor.track_id, note_id, channel, payload,
             base: base,
             pin: Keyword.get(opts, :pin)
           ) do
      {:ok, %{editor | session: session}, patch}
    end
  end

  # 显式 :base 是兼容入口：schema 必须与 payload 分派出的 descriptor
  # 一致（否则签错底座——如给 score_pitch_v2 签 pin_input_v1——挂载即
  # 永久 :base_changed）。
  defp mount_base(_editor, _note_id, _semantics, descriptor, _payload, base)
       when not is_nil(base) do
    case base do
      %{schema: schema} when schema == descriptor.base_schema ->
        {:ok, base}

      _mismatch ->
        {:error, {:pin_base_schema_mismatch, descriptor.base_schema, base}}
    end
  end

  defp mount_base(%__MODULE__{} = editor, note_id, semantics, descriptor, payload, nil) do
    with {:ok, track} <- current_track(editor) do
      context =
        Context.new(track, editor.track_id, voicebank_digest(editor),
          phonology_digest: phonology_digest(editor)
        )

      anchor = %Tamale.Anchor.Ordinal{refs: [note_id], at_version: track.space.version}
      semantics.base(context, anchor, descriptor, payload)
    end
  end

  # channel 入口校验：未注册 → 未知 channel；未完整实现 pin 语义回调 →
  # tagged error，不抛 UndefinedFunctionError。
  defp fetch_semantics(channels, channel) do
    case Map.fetch(channels, channel) do
      {:ok, semantics} ->
        if Semantics.implemented?(semantics),
          do: {:ok, semantics},
          else: {:error, {:missing_pin_semantics, semantics}}

      :error ->
        {:error, {:unknown_pin_channel, channel}}
    end
  end

  # 批次不含需要 probe 的 payload 时 sequences 为 nil，不做界内预校验
  # （fetch_alive_patches 已保证音符存活）。
  defp fetch_sequence(nil, _note_id), do: {:ok, nil}

  defp fetch_sequence(sequences, note_id) do
    case Map.fetch(sequences, note_id) do
      {:ok, sequence} -> {:ok, sequence}
      :error -> {:error, {:unknown_note, note_id}}
    end
  end

  # re-patch 计划：逐 patch 经其 channel 的 pin 语义分派——先校验可表达性
  # （duration 下标在 probe 序列界内），可表达的以该 channel 的当前底料
  # 重签后进批量。整轨 legacy 底料预计算一次，经 Context.legacy_bases
  # 共享；channel 未注册或未完整实现语义回调时降级为 tagged error。
  defp plan_repatch(patches, sequences, track, voicebank_digest, phonology_digest, channels) do
    bases = Identity.base_by_note(track, voicebank_digest)

    {discards, attaches, results} =
      Enum.reduce(patches, {[], [], []}, fn patch, {discards, attaches, results} ->
        note_id = hd(patch.anchor.refs)

        context =
          Context.new(track, patch.track_id, voicebank_digest,
            phonology_digest: phonology_digest,
            legacy_probe: sequences,
            legacy_bases: bases
          )

        with {:ok, semantics} <- fetch_semantics(channels, patch.channel),
             {:ok, _sequence} <- fetch_sequence(sequences, note_id),
             {:ok, descriptor} <- semantics.describe(patch.patch.payload),
             :ok <-
               semantics.expressible?(context, patch.anchor, descriptor, patch.patch.payload),
             {:ok, fresh_base} <-
               semantics.base(context, patch.anchor, descriptor, patch.patch.payload),
             {:ok, resigned} <- Tamale.Patch.new(fresh_base, patch.patch.payload),
             {:ok, replacement} <-
               Patch.new(%{
                 track_id: patch.track_id,
                 channel: patch.channel,
                 anchor: %Tamale.Anchor.Ordinal{
                   refs: patch.anchor.refs,
                   at_version: track.space.version
                 },
                 patch: resigned
               }) do
          entry = {patch.track_id, patch.id, :rebased}
          result = %{patch_id: patch.id, status: :repatched}
          {[entry | discards], [replacement | attaches], [result | results]}
        else
          {:error, reason} ->
            result = %{patch_id: patch.id, status: :degraded, reason: reason}
            {discards, attaches, [result | results]}
        end
      end)

    {:ok, Enum.reverse(discards), Enum.reverse(attaches), Enum.reverse(results)}
  end

  # 只允许重挂在册 patch。entry 可以是 check 冲突 entry（携完整 patch），
  # 也可以是 plain-data 引用（patch id / `%{patch_id: id}`）。
  defp fetch_alive_patches(%__MODULE__{} = editor, entries) do
    with {:ok, track} <- current_track(editor) do
      alive = Map.new(track.patches, &{&1.id, &1})

      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        case entry_patch_id(entry) do
          {:ok, id} ->
            case Map.fetch(alive, id) do
              {:ok, patch} -> {:cont, {:ok, [patch | acc]}}
              :error -> {:halt, {:error, {:patch_not_alive, id}}}
            end

          :error ->
            {:halt, {:error, {:invalid_repatch_entry, entry}}}
        end
      end)
      |> case do
        {:ok, patches} -> {:ok, Enum.reverse(patches)}
        {:error, _} = error -> error
      end
    end
  end

  defp entry_patch_id(%{patch: %Patch{id: id}}) when not is_nil(id), do: {:ok, id}
  defp entry_patch_id(%{patch_id: id}) when not is_nil(id), do: {:ok, id}
  defp entry_patch_id(id) when is_binary(id), do: {:ok, id}
  defp entry_patch_id(_other), do: :error

  # pins 归口（`design-2026-09-pin-carriers` §4 lowering 边界）：Neume 用
  # 裁决侧事实（存活 patch + channel semantics 的 descriptor）直接构造
  # engine-independent ResolvedPin，不经 Oi assemble 数据反推；runtime 经
  # `lower_pins/4` 降为执行输入。runtime 未实现 `lower_pins/4` 时只允许纯
  # legacy 批次回退 `checked_pins/1` 兼容入口；批次中出现 v2 schema 直接
  # `{:unsupported_pin_schema, schema}`——绝不把 v2 payload 塞进 legacy
  # 路径猜解。
  defp lowered_pins(%__MODULE__{} = editor, request) do
    with {:ok, resolved} <- resolved_pins(editor) do
      cond do
        function_exported?(editor.pipeline, :lower_pins, 4) ->
          case editor.pipeline.lower_pins(
                 editor.pipeline_state,
                 request.snapshot,
                 resolved,
                 editor.track_id
               ) do
            {:ok, pins} -> {:ok, pins}
            {:error, reason} -> {:error, {:check_failed, [pin_entry(editor, reason)]}}
          end

        legacy_only?(resolved) ->
          # 纯 legacy 批次的兼容回退；runtime 连 checked_pins/1 也未实现时
          # 给 tagged error，不抛 UndefinedFunctionError。
          if function_exported?(editor.pipeline, :checked_pins, 1) do
            {:ok, checked_pins(editor)}
          else
            {:error,
             {:check_failed, [pin_entry(editor, {:missing_pin_lowering, editor.pipeline})]}}
          end

        true ->
          schema = Enum.find_value(resolved, &unsupported_schema/1)
          {:error, {:check_failed, [pin_entry(editor, {:unsupported_pin_schema, schema})]}}
      end
    end
  end

  defp pin_entry(editor, reason),
    do: %{kind: :pin, track_id: editor.track_id, reason: reason}

  defp legacy_only?(resolved),
    do: Enum.all?(resolved, &(&1.descriptor.payload_schema in Schema.legacy_payload_schemas()))

  defp unsupported_schema(%Resolved{descriptor: descriptor}) do
    if descriptor.payload_schema in Schema.legacy_payload_schemas(),
      do: nil,
      else: descriptor.payload_schema
  end

  # 从存活 patch 构造 ResolvedPin：channel 未注册/未完整实现语义、或
  # payload 无法 describe 时，在同一会冲突界面聚合（与身份裁决同形状）。
  # 保持 track.patches 的原序——lowering 同 note/channel 后写覆盖
  # （later-write-wins，与 Coconut assemble 一致），不许反转。
  defp resolved_pins(%__MODULE__{} = editor) do
    with {:ok, track} <- current_track(editor) do
      track.patches
      |> Enum.reduce_while({:ok, []}, fn %Patch{} = patch, {:ok, acc} ->
        with {:ok, semantics} <- fetch_semantics(editor.session.channels, patch.channel),
             {:ok, descriptor} <- semantics.describe(patch.patch.payload) do
          resolved = %Resolved{
            channel: patch.channel,
            descriptor: descriptor,
            anchor: patch.anchor,
            payload: patch.patch.payload
          }

          {:cont, {:ok, [resolved | acc]}}
        else
          {:error, reason} ->
            entry = %{
              kind: :conflict,
              stage: :probe,
              track_id: patch.track_id,
              patch: patch,
              channel: patch.channel,
              reason: reason
            }

            {:halt, {:error, {:check_failed, [entry]}}}
        end
      end)
      |> case do
        {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
        {:error, _} = error -> error
      end
    end
  end

  # 端口路径属于 runtime 图实现；Editor 只传递静态 check 的 assemble 数据。
  # 仅供未实现 `lower_pins/4` 的 runtime 的纯 legacy 批次回退使用。
  defp checked_pins(%__MODULE__{} = editor) do
    data =
      case Coconut.checked(editor.session) do
        {:ok, %{data: data}} when is_map(data) -> data
        _other -> %{}
      end

    editor.pipeline.checked_pins(data)
  end

  # ---- 轨道挂载的 globals（extras 是持久化事实，session.globals 是派生视图）----

  # extras 的宿主命名空间键。
  @globals_ns :neume

  defp mounted_globals(%Track{extras: extras}) do
    with {:ok, ns} <- fetch_extras_ns(extras),
         {:ok, globals} <- fetch_ns_globals(ns) do
      {:ok, globals}
    end
  end

  defp fetch_extras_ns(extras) do
    case Map.fetch(extras, @globals_ns) do
      :error -> {:ok, %{}}
      {:ok, ns} when is_map(ns) and not is_struct(ns) -> {:ok, ns}
      {:ok, other} -> {:error, {:invalid_track_extras, @globals_ns, other}}
    end
  end

  defp fetch_ns_globals(ns) do
    case Map.fetch(ns, :globals) do
      :error -> {:ok, %{}}
      {:ok, globals} when is_map(globals) and not is_struct(globals) -> {:ok, globals}
      {:ok, other} -> {:error, {:invalid_track_globals, other}}
    end
  end

  defp merge_knobs(globals, knobs) do
    Enum.reduce(knobs, globals, fn
      {key, nil}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  # 无变化不落历史边；有变化先经 History 写轨道事实，再同步会话 render 配置。
  defp put_globals(session, %Track{} = track, merged) do
    extras = put_ns_globals(track.extras, merged)

    if extras == track.extras do
      {:ok, session}
    else
      with {:ok, session} <-
             Coconut.run(session, Command.put_track_extras(track.id, extras)) do
        Coconut.configure(session, globals: merged)
      end
    end
  end

  # 写回 extras 的 neume 命名空间；globals 清空时摘除 :globals，命名空间
  # 清空时整个摘除，保持 extras 干净（空写不留壳）。
  defp put_ns_globals(extras, globals) do
    ns = Map.get(extras, @globals_ns, %{})

    ns =
      if globals == %{},
        do: Map.delete(ns, :globals),
        else: Map.put(ns, :globals, globals)

    if ns == %{},
      do: Map.delete(extras, @globals_ns),
      else: Map.put(extras, @globals_ns, ns)
  end

  # undo/redo 后 extras 可能变化：会话 globals 从轨道事实重新派生。
  defp sync_mounted_globals(%__MODULE__{} = editor) do
    with {:ok, track} <- current_track(editor),
         {:ok, globals} <- mounted_globals(track),
         {:ok, session} <- Coconut.configure(editor.session, globals: globals) do
      {:ok, %{editor | session: session}}
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
      {:ok, session} -> sync_mounted_globals(%{editor | session: session})
      {:error, _} = error -> error
    end
  end

  defp validate_ticks_per_frame(value) when is_integer(value) and value > 0, do: :ok
  defp validate_ticks_per_frame(value), do: {:error, {:invalid_ticks_per_frame, value}}

  defp prepare_new_voicebank(opts) do
    case resolve_voicebank_entry(opts, nil) do
      {:ok, nil} -> {:ok, nil, opts}
      {:ok, %Entry{} = entry} -> {:ok, entry.signature, apply_voicebank_entry(opts, entry)}
      {:error, _} = error -> error
    end
  end

  defp prepare_selected_open_opts(expected_signature, opts) do
    with {:ok, entry} <- resolve_voicebank_entry(opts, expected_signature) do
      case entry do
        nil -> {:ok, opts}
        %Entry{} -> {:ok, apply_voicebank_entry(opts, entry)}
      end
    end
  end

  defp prepare_open_voicebank(expected_signature, opts) do
    case Keyword.get(opts, :voicebank_entry) do
      %Entry{} = entry -> {:ok, entry}
      nil when is_nil(expected_signature) -> {:ok, nil}
      nil -> {:error, {:voicebank_selection_required, expected_signature}}
    end
  end

  defp resolve_voicebank_entry(opts, expected_signature) do
    case Keyword.get(opts, :voicebank_entry) do
      %Entry{} = entry ->
        with :ok <- compare_signature(expected_signature, entry.signature), do: {:ok, entry}

      nil ->
        resolve_voicebank_selection(opts, expected_signature)

      other ->
        {:error, {:invalid_voicebank_entry, other}}
    end
  end

  defp resolve_voicebank_selection(opts, expected_signature) do
    case {Keyword.get(opts, :voicebank_registry), Keyword.get(opts, :voicebank_id),
          Keyword.get(opts, :voicebank_path)} do
      {%VoicebankRegistry{} = registry, id, nil} when is_binary(id) ->
        with {:ok, entry} <- VoicebankRegistry.fetch(registry, id),
             :ok <- compare_signature(expected_signature, entry.signature) do
          {:ok, entry}
        end

      {%VoicebankRegistry{} = registry, nil, nil} when not is_nil(expected_signature) ->
        VoicebankRegistry.resolve(registry, expected_signature)

      {nil, nil, path} when is_binary(path) ->
        with {:ok, entry} <- VoicebankRegistry.entry_from_path(path, opts),
             :ok <- compare_signature(expected_signature, entry.signature) do
          {:ok, entry}
        end

      {nil, nil, nil} when is_nil(expected_signature) ->
        {:ok, nil}

      {nil, nil, nil} ->
        {:error, {:voicebank_selection_required, expected_signature}}

      {nil, id, _path} when not is_nil(id) ->
        {:error, {:voicebank_registry_required, id}}

      {%VoicebankRegistry{}, nil, _path} ->
        {:error, :voicebank_id_required}

      {registry, _id, _path} when not is_nil(registry) ->
        {:error, {:invalid_voicebank_registry, registry}}

      {_registry, _id, _path} ->
        {:error, :ambiguous_voicebank_selection}
    end
  end

  defp apply_voicebank_entry(opts, %Entry{} = entry) do
    Keyword.put(opts, :voicebank_entry, entry)
  end

  defp compare_signature(nil, _actual), do: :ok
  defp compare_signature(signature, signature), do: :ok

  defp compare_signature(expected, actual),
    do: {:error, {:voicebank_mismatch, expected, actual}}

  defp compile_pipeline(nil, _track_id, ticks_per_frame, _opts) do
    with {:ok, state} <- MockPipeline.compile(ticks_per_frame: ticks_per_frame) do
      {:ok, MockPipeline, state}
    end
  end

  defp compile_pipeline(%Entry{runtime: runtime} = entry, track_id, ticks_per_frame, opts)
       when is_atom(runtime) do
    runtime_opts =
      opts
      |> Keyword.put(:entry, entry)
      |> Keyword.put(:track_id, track_id)
      |> Keyword.put(:ticks_per_frame, ticks_per_frame)

    with true <- Code.ensure_loaded?(runtime),
         true <- function_exported?(runtime, :compile, 1),
         {:ok, state} <- runtime.compile(runtime_opts) do
      {:ok, runtime, state}
    else
      false -> {:error, {:runtime_unavailable, runtime}}
      {:error, _} = error -> error
    end
  end
end
