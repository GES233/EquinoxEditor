defmodule EquinoxDomain.Score.Track do
  @moduledoc """
  轨道——承载音符（zongzi Timeline 体系）、干预（interventions）、混音参数与 Port 预设。

  ## 音符存储模型

  - `timeline` — `Zongzi.Timeline` 双向链表，维护音符的全序关系
    （SeqID 单调递增、删除/合并留墓碑）。
  - `notes_by_seq` — `%{SeqID.t() => Note.t()}` 音符快照；Timeline 不持
    Note 本体，所有写操作遵循 Caller 同步契约：Timeline 写入后同步写回本 map。

  ## 干预（zongzi Intervention 体系）

  - `interventions` — 用户挂在音符上的 `Zongzi.Intervention.t()` 列表
    （如 phoneme timing delta）。通过 `mount_intervention/5` 挂载
    （自动派生三元组锚、写 snapshot）。
  - 音符写操作（insert/delete/split/merge/update）**不**自动 rebase 干预——
    Caller 在编辑批次结束后显式调 `rebase_interventions/1`
    （与 zongzi Caller 编排模型一致），conflicts/decisions 上浮给 Caller。

  ## 切片

  `slice/2` 是 Notes → 瞬态 `[Zongzi.Windowing.Segment.t()]` 的**单向投影**：
  组装 `Windowing.Context` 后跑 `EquinoxDomain.Score.SlicePolicy`
  （zongzi 默认 `RestSplit3Beats` + slice_flag 两遍修正）。
  Segment 永不持久化，重切片时从音符全量重建。

  ## 序列化

  `dump/1` / `load/1` 遵循 `EquinoxDomain.Pickle` 原生对象 codec 约定：
  标量字段直出；`timeline` 经 `Pickle.Timeline`（track_id 由本模块注入）、
  `notes_by_seq` 经 `Pickle.Note`、`interventions` 经 `Pickle.Intervention`、
  `presets` 经 `Preset.dump/1` 组合，load 时用 `with` 串联各子 codec。
  """

  alias EquinoxDomain.Pickle
  alias EquinoxDomain.Score.{Project, Track, SliceFlag, SlicePolicy}
  alias EquinoxDomain.Port.Preset
  alias Zongzi.{Anchor, Intervention, Timeline, Windowing}
  alias Zongzi.Anchor.TripletMatch
  alias Zongzi.Score.{Note, Tick}
  alias Zongzi.Timeline.{Query, SeqID}
  alias Zongzi.Util.ID

  @type t :: %__MODULE__{
          id: ID.t(Track),
          project_id: ID.t(Project),
          name: String.t(),
          timeline: Timeline.t() | nil,
          notes_by_seq: %{SeqID.t() => Note.t()},
          interventions: [Intervention.t()],
          mix_automation: map(),
          gain: number(),
          pan: number(),
          mute: boolean(),
          solo: boolean(),
          presets: %{binary() => Preset.t()},
          active_preset: nil | binary(),
          metadata: map()
        }

  use Zongzi.Util.Model,
    keys: [
      :id,
      :project_id,
      :name,
      type: :synth,
      # ---- Note 层（zongzi Timeline 体系） ----
      timeline: nil,
      notes_by_seq: %{},
      # ---- 干预（zongzi Intervention 体系） ----
      interventions: [],
      # ---- Mix Automation ----
      mix_automation: %{},
      # ---- Mix 静态值 ----
      gain: 1.0,
      pan: 0.0,
      mute: false,
      solo: false,
      # ---- Port 预设 ----
      presets: %{},
      active_preset: nil,
      # ---- 其他 ----
      metadata: %{}
    ],
    id_prefix: "Track_"

  # ---- 构造 ----

  @doc "创建轨道；`timeline` 缺省时以 track.id 初始化空 Timeline。"
  def new(attrs) do
    with {:ok, track} <- super(attrs) do
      case track.timeline do
        nil ->
          {:ok, timeline} = Timeline.new(track.id)
          {:ok, %{track | timeline: timeline}}

        _timeline ->
          {:ok, track}
      end
    end
  end

  # ---- 音符写操作（Caller 同步契约：Timeline 写入后同步 notes_by_seq） ----

  @doc """
  插入音符。

  `attrs` 缺 `:id` 时自动生成。定位规则：active 序中第一个
  `start_tick` 严格大于新音符的 seq 之前插入；找不到则追加到尾部
  （同 `start_tick` 时稳定落在既有同 tick 音符之后）。
  """
  @spec insert_note(t(), map() | keyword()) :: {:ok, t(), Note.t()} | {:error, term()}
  def insert_note(%__MODULE__{} = track, attrs) do
    attrs = attrs |> Map.new() |> Map.put_new_lazy(:id, fn -> ID.generate_id("Note_") end)

    with {:ok, note} <- Note.new(attrs),
         {:ok, timeline, note} <- insert_to_timeline(track, note) do
      track = %{
        track
        | timeline: timeline,
          notes_by_seq: Map.put(track.notes_by_seq, note.seq_id, note)
      }

      {:ok, track, note}
    end
  end

  @doc "删除音符；seq 不存在报 `{:error, {:note_not_found, seq_id}}`。"
  @spec delete_note(t(), SeqID.t()) :: {:ok, t()} | {:error, term()}
  def delete_note(%__MODULE__{} = track, seq_id) do
    if Map.has_key?(track.notes_by_seq, seq_id) do
      with {:ok, timeline} <- Timeline.delete_note(track.timeline, seq_id) do
        {:ok, %{track | timeline: timeline, notes_by_seq: Map.delete(track.notes_by_seq, seq_id)}}
      end
    else
      {:error, {:note_not_found, seq_id}}
    end
  end

  @doc """
  在 `split_tick` 处切开音符。

  before 保原 seq、after 分配新 seq（新 id 自动生成），两者均写回
  `notes_by_seq`。`attrs` 透传给 `Zongzi.Score.Note.split/4`
  （如给后半音符换歌词）。
  """
  @spec split_note(t(), SeqID.t(), Tick.numeric_tick(), map() | keyword()) ::
          {:ok, t(), Note.t(), Note.t()} | {:error, term()}
  def split_note(%__MODULE__{} = track, seq_id, split_tick, attrs \\ []) do
    with {:ok, note} <- note(track, seq_id),
         {:ok, timeline, before_note, after_note} <-
           Timeline.split_note(track.timeline, note, split_tick, ID.generate_id("Note_"), attrs) do
      notes_by_seq =
        track.notes_by_seq
        |> Map.put(before_note.seq_id, before_note)
        |> Map.put(after_note.seq_id, after_note)

      {:ok, %{track | timeline: timeline, notes_by_seq: notes_by_seq}, before_note, after_note}
    end
  end

  @doc """
  合并两个音符（同音高且相邻，见 `Zongzi.Score.Note.merge/4`）。

  merged 写回 seq_a（新 id 自动生成），seq_b 成墓碑并从 `notes_by_seq` 移除。
  """
  @spec merge_notes(t(), SeqID.t(), SeqID.t()) :: {:ok, t(), Note.t()} | {:error, term()}
  def merge_notes(%__MODULE__{} = track, seq_a, seq_b) do
    with {:ok, note_a} <- note(track, seq_a),
         {:ok, note_b} <- note(track, seq_b),
         {:ok, timeline, merged} <-
           Timeline.merge_notes(track.timeline, note_a, note_b, ID.generate_id("Note_")) do
      notes_by_seq =
        track.notes_by_seq
        |> Map.put(seq_a, merged)
        |> Map.delete(seq_b)

      {:ok, %{track | timeline: timeline, notes_by_seq: notes_by_seq}, merged}
    end
  end

  @doc """
  更新音符字段并写回 `notes_by_seq`。

  `attrs` 含 `:start_tick` 时按新时间重定位链表顺序（见 relocate 私有函数）。
  """
  @spec update_note(t(), SeqID.t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def update_note(%__MODULE__{} = track, seq_id, attrs) do
    with {:ok, note} <- note(track, seq_id),
         {:ok, note} <- Note.update(note, attrs) do
      track = %{track | notes_by_seq: Map.put(track.notes_by_seq, seq_id, note)}

      if attrs |> Map.new() |> Map.has_key?(:start_tick) do
        relocate(track, seq_id, note.start_tick)
      else
        {:ok, track}
      end
    end
  end

  @doc "写入音符的 slice_flag（存于 Note.metadata，见 `EquinoxDomain.Score.SliceFlag`）。"
  @spec apply_slice_flag(t(), SeqID.t(), SliceFlag.t()) :: {:ok, t()} | {:error, term()}
  def apply_slice_flag(%__MODULE__{} = track, seq_id, flag) do
    with {:ok, note} <- note(track, seq_id),
         {:ok, note} <- SliceFlag.set(note, flag) do
      {:ok, %{track | notes_by_seq: Map.put(track.notes_by_seq, seq_id, note)}}
    end
  end

  # ---- 查询 ----

  @doc "按 seq 取音符。"
  @spec note(t(), SeqID.t()) :: {:ok, Note.t()} | {:error, {:note_not_found, SeqID.t()}}
  def note(%__MODULE__{notes_by_seq: notes_by_seq}, seq_id) do
    case Map.fetch(notes_by_seq, seq_id) do
      {:ok, note} -> {:ok, note}
      :error -> {:error, {:note_not_found, seq_id}}
    end
  end

  @doc "active 序的 `[{seq_id, note}]` 列表（跳过墓碑）。"
  @spec active_notes(t()) :: [{SeqID.t(), Note.t()}]
  def active_notes(%__MODULE__{} = track) do
    track.timeline
    |> active_seqs()
    |> Enum.map(fn seq -> {seq, Map.fetch!(track.notes_by_seq, seq)} end)
  end

  # ---- 切片（单向投影） ----

  @doc """
  Notes → 瞬态 `[Zongzi.Windowing.Segment.t()]` 的单向投影。

  可选 opts：`:time_sig_map`、`:tempo_map`、`:interventions`，
  其余键原样透传 `Windowing.Context` 的 `:opts`（如 `:tpqn` / `:beat_ticks`）。
  """
  @spec slice(t(), keyword()) :: {:ok, [Windowing.Segment.t()]} | {:error, term()}
  def slice(%__MODULE__{} = track, opts \\ []) do
    ctx =
      Windowing.Context.new(
        timeline: track.timeline,
        notes_by_seq: track.notes_by_seq,
        time_sig_map: opts[:time_sig_map],
        tempo_map: opts[:tempo_map],
        interventions: opts[:interventions] || [],
        # zongzi 侧要求 opts 为 map（Context.scope_ctx/1 走 Map.get），
        # 这里把 keyword 统一归一为 map
        opts: Map.new(opts)
      )

    Windowing.run_stages(ctx, [SlicePolicy])
  end

  # ---- 干预挂载与 rebase（zongzi Intervention 体系） ----

  @doc """
  把 intervention 挂载到 `seq_id` 对应的音符上。

  用 `Anchor.TripletMatch.scrub_triplet/2` 派生三元组锚，再调
  `Intervention.mount/5`（更新 payload/anchor、经 declaration 写 snapshot、
  校验锚引用的 seq 均 active）。成功后 prepend 到 `track.interventions`，
  返回 `{:ok, track, mounted_intervention}`。

  `seq_id` 非 active（已删/不存在）时报 `{:error, :not_active}`。
  """
  @spec mount_intervention(t(), Intervention.t(), term(), SeqID.t(), term()) ::
          {:ok, t(), Intervention.t()} | {:error, term()}
  def mount_intervention(
        %__MODULE__{} = track,
        %Intervention{} = int,
        payload,
        seq_id,
        projection
      ) do
    with {:ok, anchor} <- TripletMatch.scrub_triplet(track.timeline, seq_id),
         {:ok, mounted} <- Intervention.mount(int, payload, anchor, track.timeline, projection) do
      {:ok, %{track | interventions: [mounted | track.interventions]}, mounted}
    end
  end

  @doc """
  编辑批次结束后，对全部 interventions 跑结构 rebase。

  注入 `Anchor.Context`（`notes_by_seq: track.notes_by_seq`），
  `track.interventions` 替换为 survived 列表（含 on_rebase 维护后的 payload），
  conflicts/decisions 原样上浮给 Caller（UI 提示、指标等）。

  本函数只判结构死活；语义有效性（snapshot 比对）在渲染时由
  `Declaration.resolve/2` 判定。
  """
  @spec rebase_interventions(t()) ::
          {:ok, t(),
           %{
             conflicts: [{Intervention.t(), term()}],
             decisions: %{optional(term()) => Anchor.decision_label()}
           }}
  def rebase_interventions(%__MODULE__{} = track) do
    ctx = Anchor.Context.new(notes_by_seq: track.notes_by_seq)

    %{survived: survived, conflicts: conflicts, decisions: decisions} =
      Anchor.rebase_all(track.interventions, track.timeline, ctx)

    {:ok, %{track | interventions: survived}, %{conflicts: conflicts, decisions: decisions}}
  end

  # ---- 序列化（EquinoxDomain.Pickle 原生对象 codec） ----

  @doc """
  摊平为 plain map（遵循 `EquinoxDomain.Pickle` 约定）。

  标量字段直出；`timeline` / `notes_by_seq` / `interventions` / `presets`
  分别经对应子 codec 组合（`notes_by_seq` 的整数 seq 键原生保留）。
  """
  @spec dump(t()) :: {:ok, map()} | {:error, term()}
  def dump(%__MODULE__{} = track) do
    with {:ok, timeline} <- Pickle.Timeline.dump(track.timeline),
         {:ok, notes_by_seq} <- dump_notes(track.notes_by_seq),
         {:ok, interventions} <- dump_interventions(track.interventions),
         {:ok, presets} <- dump_presets(track.presets) do
      {:ok,
       %{
         id: track.id,
         project_id: track.project_id,
         name: track.name,
         type: track.type,
         timeline: timeline,
         notes_by_seq: notes_by_seq,
         interventions: interventions,
         mix_automation: track.mix_automation,
         gain: track.gain,
         pan: track.pan,
         mute: track.mute,
         solo: track.solo,
         presets: presets,
         active_preset: track.active_preset,
         metadata: track.metadata
       }}
    end
  end

  @doc """
  从 plain map 重建 Track。

  先 `new/1`（自动建空 Timeline），再把 `Pickle.Timeline.load/2`
  （注入 track.id）、notes_by_seq、interventions、presets 及其余字段
  经 `update/2` 写入。
  """
  @spec load(map()) :: {:ok, t()} | {:error, term()}
  def load(%{} = data) do
    with {:ok, track} <- data |> Map.take([:id, :project_id, :name, :type]) |> new(),
         {:ok, timeline} <- load_timeline(Map.get(data, :timeline), track.id),
         {:ok, notes_by_seq} <- load_notes(Map.get(data, :notes_by_seq, %{})),
         {:ok, interventions} <- load_interventions(Map.get(data, :interventions, [])),
         {:ok, presets} <- load_presets(Map.get(data, :presets, %{})) do
      attrs =
        data
        |> Map.take([:mix_automation, :gain, :pan, :mute, :solo, :active_preset, :metadata])
        |> Map.merge(%{
          timeline: timeline,
          notes_by_seq: notes_by_seq,
          interventions: interventions,
          presets: presets
        })

      update(track, attrs)
    end
  end

  defp dump_notes(notes_by_seq) do
    map_values_ok(notes_by_seq, &Pickle.Note.dump/1)
  end

  defp dump_interventions(interventions) do
    list_values_ok(interventions, &Pickle.Intervention.dump/1)
  end

  defp dump_presets(presets) do
    map_values_ok(presets, &Preset.dump/1)
  end

  defp load_timeline(nil, track_id), do: Timeline.new(track_id)
  defp load_timeline(dump, track_id), do: Pickle.Timeline.load(dump, track_id)

  defp load_notes(notes_by_seq) do
    map_values_ok(notes_by_seq, &Pickle.Note.load/1)
  end

  defp load_interventions(interventions) do
    list_values_ok(interventions, &Pickle.Intervention.load/1)
  end

  defp load_presets(presets) do
    map_values_ok(presets, &Preset.load/1)
  end

  # 对 map 的值逐个跑 {:ok, _} / {:error, _} 子 codec，任一失败即整体失败
  defp map_values_ok(map, fun) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case fun.(value) do
        {:ok, converted} -> {:cont, {:ok, Map.put(acc, key, converted)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # 对 list 逐个跑子 codec（保持顺序），任一失败即整体失败
  defp list_values_ok(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  # ---- 内部：定位与重定位 ----

  # 按 start_tick 定位插入点：active 序中第一个 start_tick 严格大于
  # 新音符的 seq 之前；找不到则追加尾部。
  defp insert_to_timeline(%__MODULE__{} = track, %Note{} = note) do
    case find_insert_target(track, note.start_tick, nil) do
      nil -> Timeline.insert_note(track.timeline, note)
      target_seq -> Timeline.insert_note_before(track.timeline, note, target_seq)
    end
  end

  # start_tick 变化后的重定位：
  # - target = active 序（排除自身）中第一个 start_tick 严格大于新值的 seq；
  #   target 存在且当前 active 后继 ≠ target → 移到 target 之前；
  # - target 不存在（应居末位）且当前 active 后继 ≠ nil → 移到最末 active 之后；
  # - 其余情况链表序已正确，不动。
  defp relocate(%__MODULE__{} = track, seq_id, start_tick) do
    target = find_insert_target(track, start_tick, seq_id)
    current_next = next_active_seq(track.timeline, seq_id)

    cond do
      not is_nil(target) and current_next != target ->
        with {:ok, timeline} <- Timeline.move_note(track.timeline, seq_id, target, :before) do
          {:ok, %{track | timeline: timeline}}
        end

      is_nil(target) and not is_nil(current_next) ->
        last_seq = track.timeline |> active_seqs() |> List.last()

        with {:ok, timeline} <- Timeline.move_note(track.timeline, seq_id, last_seq, :after) do
          {:ok, %{track | timeline: timeline}}
        end

      true ->
        {:ok, track}
    end
  end

  # active 序中第一个 start_tick 严格大于给定值的 seq（可排除某个 seq）
  defp find_insert_target(%__MODULE__{} = track, start_tick, exclude_seq) do
    track.timeline
    |> active_seqs()
    |> Enum.find(fn seq ->
      seq != exclude_seq and Map.fetch!(track.notes_by_seq, seq).start_tick > start_tick
    end)
  end

  # Timeline 链表序中的 active seq 列表（跳过墓碑）
  defp active_seqs(%Timeline{} = timeline) do
    timeline
    |> Timeline.to_list()
    |> Enum.filter(&Query.active?(timeline, &1))
  end

  # 链表中 seq 之后的第一个 active seq（无则 nil）
  defp next_active_seq(%Timeline{} = timeline, seq_id) do
    case Query.scan(timeline, seq_id, :next, limit: 1) do
      [next_seq] -> next_seq
      [] -> nil
    end
  end
end
