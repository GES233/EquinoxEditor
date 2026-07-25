defmodule EquinoxDomain.Command.RenderRequest do
  @moduledoc """
  渲染请求——Compiler 的统一入口。

  构造时自动完成：
  - 从 Track 查询 Note 本体
  - 按 scope 与窗口区间相交过滤 Track 上的 interventions
  - 切片 TempoMap 中的 tempo_segments
  - 从 interventions 派生 channel → declaration 模块注册表

  RenderRequest 携带的是**结构存活**的干预——Caller 应先在编辑批次结束后跑
  `Track.rebase_interventions/1`。`Declaration.resolve/2` 的语义判定
  （snapshot 比对）发生在引擎 check 阶段，不在本结构内。
  """

  alias EquinoxDomain.{Score.Track, Port.Channel}
  alias Zongzi.{Intervention, Util.ID, Score.TempoMap, Score.Tick, Score.Note, Windowing}
  alias Zongzi.Windowing.Segment

  @type t :: %__MODULE__{
          track_id: ID.t(Track),
          note_ids: [ID.t(Note)],
          notes: [Note.t()],
          time_range: {Tick.numeric_tick(), Tick.numeric_tick()},
          tempo_segments: [TempoMap.compiled_event()],
          interventions: [Intervention.t()],
          declarations: %{Channel.channel() => module()}
        }

  use Zongzi.Util.Object,
    keys: [
      :track_id,
      note_ids: [],
      notes: [],
      time_range: {0, 0},
      tempo_segments: [],
      interventions: [],
      declarations: %{}
    ]

  @doc """
  从 Segment（预览路径）构建 RenderRequest。

  Segment 是 Windowing 的瞬态投影；Track 上 scope 与本 Segment 区间
  （左闭右开）相交的 interventions 被纳入请求。
  """
  @spec from_window(Segment.t(), Track.t(), TempoMap.t()) :: {:ok, t()} | {:error, term()}
  def from_window(%Segment{} = segment, %Track{} = track, tempo_map) do
    time_range = {segment.start_tick, segment.end_tick}
    {t0, t1} = time_range
    scope_ctx = %{timeline: track.timeline, tempo_map: tempo_map, tpqn: 480}

    with {:ok, notes} <- lookup_notes(track, segment.seq_ids) do
      interventions = filter_by_scope(track.interventions, scope_ctx, time_range)

      new(
        track_id: track.id,
        note_ids: Enum.map(notes, & &1.id),
        notes: notes,
        time_range: time_range,
        tempo_segments: TempoMap.slice(tempo_map, t0, t1),
        interventions: interventions,
        declarations: Map.new(interventions, &{&1.channel, &1.declaration})
      )
    end
  end

  # ---- helpers ----

  # 按 Segment.seq_ids 从 Track.notes_by_seq 取 Note 本体（保持 seq 序）
  defp lookup_notes(%Track{notes_by_seq: notes_by_seq}, seq_ids) do
    case Enum.reduce_while(seq_ids, {:ok, []}, fn seq_id, {:ok, acc} ->
           case Map.fetch(notes_by_seq, seq_id) do
             {:ok, note} -> {:cont, {:ok, [note | acc]}}
             :error -> {:halt, {:error, {:note_not_found, seq_id}}}
           end
         end) do
      {:ok, notes} -> {:ok, Enum.reverse(notes)}
      {:error, _} = err -> err
    end
  end

  # scope 经 normalize_scope 归一为 tick 后与窗口区间（左闭右开）判交；
  # 归一化失败（如秒基准 scope 缺 tempo_map）的干预跳过
  defp filter_by_scope(interventions, scope_ctx, {win_start, win_end}) do
    Enum.filter(interventions, fn %Intervention{declaration: decl} = int ->
      case Windowing.Context.normalize_scope(decl.scope(int, scope_ctx), scope_ctx) do
        {:ok, {s, e}} -> s < win_end and e > win_start
        {:error, _} -> false
      end
    end)
  end
end
