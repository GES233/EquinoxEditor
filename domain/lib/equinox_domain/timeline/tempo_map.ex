defmodule EquinoxDomain.Timeline.TempoMap do
  @moduledoc """
  根据变化事件返回编译后的速度映射表。

  内部委托 `RecordMap` 完成编译与基于 Tick 的二分查找，
  自身负责秒数累积与基于秒的反向查找。

  结构形如：

      {
        %{start_pos: 0, end_pos: 1920, start_sec: 0.0, strategy: %Step{bpm: 120}},
        %{start_pos: 1920, end_pos: 2400, start_sec: 2.0, strategy: %Linear{...}},
        ...
      }

  区间格式左闭右开。
  """

  alias EquinoxDomain.{Timeline, Timeline.Tempo, Timeline.Tick, Timeline.RecordMap}

  @type compiled_event :: %{
          start_pos: Tick.numeric_tick(),
          end_pos: Tick.t(),
          start_sec: Timeline.physical_time(),
          strategy: Tempo.Segment.segment()
        }

  @type t :: tuple()

  @doc """
  当速度事件发生变化时，重新编译时间线。
  """
  @spec compile(Tempo.tempo_events()) :: {:ok, t()} | {:error, term()}
  def compile([]), do: {:error, :empty_tempo_events}

  def compile({[], _last_tick}), do: {:error, :empty_tempo_events}

  def compile([_ | _] = tempo_events),
    do: compile({tempo_events, Tick.get_dynamic_tick()})

  def compile({_events, _last_tick} = tempo_events) do
    reducer = fn start_tick, end_tick, event, current_sec ->
      with {:ok, strategy} <-
             Tempo.build_segment_from_event(
               event.module,
               start_tick,
               end_tick,
               event.context
             ) do
        duration = Tempo.duration_sec(strategy)
        next_sec = if duration == :infinity, do: current_sec, else: current_sec + duration

        {:ok,
         %{
           start_pos: start_tick,
           end_pos: end_tick,
           start_sec: current_sec,
           strategy: strategy
         }, next_sec}
      end
    end

    case RecordMap.compile(tempo_events, reducer, 0.0) do
      {:ok, tuple} ->
        {:ok, tuple}

      {:error, {:first_record_must_start_at_zero, pos}} ->
        {:error, {:first_tempo_event_must_start_at_zero, pos}}

      {:error, {:invalid_record_position, bad}} ->
        {:error, {:invalid_tempo_event_tick, bad}}

      {:error, :duplicate_record_positions} ->
        {:error, :duplicate_tempo_event_ticks}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "在 compiled_tuple 中查找 target_tick 所对应的秒数。"
  def tick_to_sec(compiled_tuple, target_tick) do
    seg = RecordMap.find_by_position(compiled_tuple, target_tick)
    seg.start_sec + Tempo.tick_to_sec(seg.strategy, target_tick - seg.start_pos)
  end

  @doc "在 compiled_tuple 中查找 target_sec 所对应的 tick。"
  def sec_to_tick(compiled_tuple, target_sec) do
    seg = find_segment_by_sec(compiled_tuple, target_sec, 0, tuple_size(compiled_tuple) - 1)
    offset_sec = target_sec - seg.start_sec
    seg.start_pos + Tempo.sec_to_tick(seg.strategy, offset_sec)
  end

  # ---- sec_to_tick 的工具函数 ----

  # 二分搜索：按秒数定位区间
  defp find_segment_by_sec(tuple, target_sec, low, high) when low <= high do
    mid = div(low + high, 2)
    seg = elem(tuple, mid)

    duration = Tempo.duration_sec(seg.strategy)

    cond do
      target_sec < seg.start_sec ->
        find_segment_by_sec(tuple, target_sec, low, mid - 1)

      duration != :infinity and target_sec >= seg.start_sec + duration ->
        find_segment_by_sec(tuple, target_sec, mid + 1, high)

      true ->
        seg
    end
  end

  # Fallback：超出范围返回最后一个区间
  defp find_segment_by_sec(tuple, _target_sec, _low, _high),
    do: elem(tuple, tuple_size(tuple) - 1)
end
