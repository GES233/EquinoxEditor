defmodule Neume.Editor do
  @moduledoc """
  Neume 的无界面编辑入口。

  编辑状态由 `Coconut.Session` 持有；Neume 只负责把具名编辑动作、工程
  存取和固定的合成图收束成一个宿主 API。历史与最近一次检查结果是会话
  状态，不写入工程文件。
  """

  alias Coconut.Edit.{Command, Patch, Track, Workspace}
  alias Coconut.Edit.Operations.{DeleteNote, DragNote, EditNote, InsertNote}
  alias Coconut.Pickle.File
  alias Coconut.Pickle.Track, as: PickleTrack
  alias Coconut.Project
  alias Coconut.Util.ID
  alias Neume.Channels.{DurationPin, PitchPin}
  alias Neume.Engine.DiffSingerPipeline
  alias Neume.Engine.MockPipeline
  alias Neume.Identity
  alias Neume.Voicebank.DiffSinger

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
         {:ok, pipeline, pipeline_state} <-
           compile_pipeline(manifest, track_id, ticks_per_frame, opts),
         engine_config <- pipeline.engine_config(pipeline_state, track_id),
         {:ok, session} <-
           Coconut.new(project,
             channels: %{duration: DurationPin, pitch: PitchPin},
             engine: {CoconutOi.OrchidAdapter, engine_config}
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
  在音符上挂载绝对 tick 到 MIDI 的稀疏 pitch 控制点。

  身份底料（§6.6）：挂载时跑一次轻量 probe（G2P + 组展开，不跑模型），
  用物化的词内音素序列签名；probe 期裁决见 `Neume.Identity`。
  """
  @spec mount_pitch(t(), term(), [[number()]]) :: {:ok, t()} | {:error, term()}
  def mount_pitch(%__MODULE__{} = editor, note_id, points) do
    case mount_pin(editor, note_id, :pitch, points) do
      {:ok, editor, _patch} -> {:ok, editor}
      {:error, _} = error -> error
    end
  end

  @doc """
  在音符上挂载逐音素的稀疏时长 pin：`[[音素下标, tick 时长], ...]`。

  底料与裁决同 `mount_pitch/3`；下标指向 probe 物化序列中的音素。
  """
  @spec mount_phoneme_duration(t(), term(), [[non_neg_integer()]]) ::
          {:ok, t()} | {:error, term()}
  def mount_phoneme_duration(%__MODULE__{} = editor, note_id, durations) do
    case mount_pin(editor, note_id, :duration, durations) do
      {:ok, editor, _patch} -> {:ok, editor}
      {:error, _} = error -> error
    end
  end

  @doc """
  更新会话级全局旋钮（key 合并，nil 删除该键）。

  旋钮直接进 render，不经 tamale patch，也不进工程文件/undo 历史（与
  speaker/velocity 等编译期 globals 同一层）。当前声明白名单是
  `:energy` / `:breathiness` / `:voicing`（variance 预测曲线的乘性系数，
  `1.0` 中立，合法范围 0.0–2.0）；未知键或越界值在 `check/1` 的门禁聚合
  为 `%{kind: :global, ...}` entry。持久化若要落地，候选位置是
  `Project.metadata`（coconut Track 暂无 metadata/extras 字段）。
  """
  @spec update_globals(t(), map()) :: {:ok, t()} | {:error, term()}
  def update_globals(%__MODULE__{} = editor, knobs) when is_map(knobs) do
    globals =
      Enum.reduce(knobs, editor.session.globals, fn
        {key, nil}, acc -> Map.delete(acc, key)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    with {:ok, session} <- Coconut.configure(editor.session, globals: globals) do
      {:ok, %{editor | session: session}}
    end
  end

  @doc "当前会话级全局旋钮（不含管线编译期默认值）。"
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
    with {:ok, editor, request, analysis} <- checked_probe(editor),
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
  `mount_pitch/3` / `mount_phoneme_duration/3` 重新挂载。

  返回 `{:ok, editor, results}`，`results` 逐项为
  `%{patch_id, status: :repatched, new_patch_id}` 或
  `%{patch_id, status: :degraded, reason}`。
  """
  @spec repatch(t(), [map()]) :: {:ok, t(), [map()]} | {:error, term()}
  def repatch(%__MODULE__{} = editor, []), do: {:ok, editor, []}

  def repatch(%__MODULE__{} = editor, entries) when is_list(entries) do
    with {:ok, patches} <- fetch_alive_patches(editor, entries),
         {:ok, request} <- Coconut.request(editor.session),
         {:ok, sequences} <-
           editor.pipeline.phonemes(editor.pipeline_state, request.snapshot, editor.track_id),
         {:ok, track} <- current_track(editor),
         {:ok, discards, attaches, results} <- plan_repatch(patches, sequences, track),
         {:ok, session} <- run_repatch(editor.session, discards, attaches) do
      {:ok, %{editor | session: session}, results}
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
    with {:ok, editor, request, _analysis} <- checked_probe(editor),
         {:ok, artifact} <-
           editor.pipeline.render(
             editor.pipeline_state,
             request.snapshot,
             checked_pins(editor.session),
             request.globals,
             editor.track_id
           ) do
      {:ok, editor, artifact}
    end
  end

  @doc """
  analyze/align 闭环：不运行 acoustic/vocoder，返回 G2P 结果、duration
  预测和元音锚定后的音素边界（`Neume.Analysis`）。失败形状同 `render/1`。
  """
  @spec analyze(t()) :: {:ok, t(), Neume.Analysis.t()} | {:error, term()}
  def analyze(%__MODULE__{} = editor) do
    with {:ok, editor, _request, analysis} <- checked_probe(editor) do
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
    with {:ok, editor, _request, analysis} <- checked_probe(editor) do
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

    with {:ok, analysis} <-
           editor.pipeline.analyze(
             editor.pipeline_state,
             request.snapshot,
             checked_pins(editor.session),
             request.globals,
             editor.track_id
           ),
         :ok <- adjudicate_identity(editor, analysis) do
      {:ok, editor, request, analysis}
    else
      {:error, {:check_failed, _entries}} = error -> error
      {:error, reason} -> {:error, {:check_failed, [%{kind: :model, reason: reason}]}}
    end
  end

  defp adjudicate_identity(%__MODULE__{} = editor, %Neume.Analysis{} = analysis) do
    with {:ok, track} <- current_track(editor) do
      case Identity.adjudicate(track, editor.session.channels, analysis.note_phonemes) do
        [] -> :ok
        entries -> {:error, {:check_failed, entries}}
      end
    end
  end

  # 挂载共用路径：轻量 probe 物化身份底料 → 显式 :base 签名 → 一条历史边。
  defp mount_pin(%__MODULE__{} = editor, note_id, channel, payload) do
    with {:ok, request} <- Coconut.request(editor.session),
         {:ok, sequences} <-
           editor.pipeline.phonemes(editor.pipeline_state, request.snapshot, editor.track_id),
         {:ok, sequence} <- fetch_sequence(sequences, note_id),
         {:ok, session, patch} <-
           Coconut.mount(editor.session, editor.track_id, note_id, channel, payload,
             base: sequence
           ) do
      {:ok, %{editor | session: session}, patch}
    end
  end

  defp fetch_sequence(sequences, note_id) do
    case Map.fetch(sequences, note_id) do
      {:ok, sequence} -> {:ok, sequence}
      :error -> {:error, {:unknown_note, note_id}}
    end
  end

  # re-patch 计划：逐 patch 取新底料 + 可表达性校验，可重签的进批量。
  defp plan_repatch(patches, sequences, track) do
    {discards, attaches, results} =
      Enum.reduce(patches, {[], [], []}, fn patch, {discards, attaches, results} ->
        note_id = hd(patch.anchor.refs)

        with {:ok, fresh} <- fetch_sequence(sequences, note_id),
             :ok <- Identity.expressible?(patch.channel, patch.patch.payload, fresh),
             {:ok, resigned} <- Tamale.Patch.new(fresh, patch.patch.payload),
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

  # 只允许重挂在册 patch；entry 必须携带 patch（check 冲突 entry 形状）。
  defp fetch_alive_patches(%__MODULE__{} = editor, entries) do
    with {:ok, track} <- current_track(editor) do
      alive = Map.new(track.patches, &{&1.id, &1})

      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        case entry do
          %{patch: %Patch{id: id}} when not is_nil(id) ->
            case Map.fetch(alive, id) do
              {:ok, patch} -> {:cont, {:ok, [patch | acc]}}
              :error -> {:halt, {:error, {:patch_not_alive, id}}}
            end

          other ->
            {:halt, {:error, {:invalid_repatch_entry, other}}}
        end
      end)
      |> case do
        {:ok, patches} -> {:ok, Enum.reverse(patches)}
        {:error, _} = error -> error
      end
    end
  end

  # 从最近一次静态 check 的 assemble 结果里取 pins（无 patch 时为空 map）。
  # DiffSinger 图挂在 score_plan 输入上，mock 图挂在 pitch step 输入上。
  defp checked_pins(session) do
    case Coconut.checked(session) do
      {:ok, %{data: data}} when is_map(data) ->
        %{
          pitch: get_in(data, [:score_plan, :pitch_pins]) || get_in(data, [:pitch, :pins]) || %{},
          duration: get_in(data, [:score_plan, :duration_pins]) || %{}
        }

      _other ->
        %{pitch: %{}, duration: %{}}
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
    with {:ok, state} <- MockPipeline.compile(ticks_per_frame: ticks_per_frame) do
      {:ok, MockPipeline, state}
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
      |> put_option(:cache, opts, :cache)

    with {:ok, state} <- DiffSingerPipeline.compile(pipeline_opts) do
      {:ok, DiffSingerPipeline, state}
    end
  end

  defp put_option(target, target_key, source, source_key) do
    case Keyword.fetch(source, source_key) do
      {:ok, value} -> Keyword.put(target, target_key, value)
      :error -> target
    end
  end
end
