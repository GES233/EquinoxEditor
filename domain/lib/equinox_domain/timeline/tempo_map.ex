defmodule EquinoxDomain.Timeline.TempoMap do
  @moduledoc """
  根据变化事件返回编译后的速度映射表。

  结构形如：

      [
        %{start_tick: 0, end_tick: 1920, start_sec: 0.0, strategy: %Step{bpm: 120}},
        %{start_tick: 1920, end_tick: 2400, start_sec: 2.0, strategy: %Linear{...}},
        ...
      ]

  区间格式左闭右开。
  """

  alias EquinoxDomain.{Timeline, Timeline.Tempo, Timeline.Tick}
  import Tick

  @type compiled_event :: %{
          start_tick: Tick.numeric_tick(),
          end_tick: Tick.t(),
          start_sec: Timeline.physical_time(),
          strategy: Tempo.Segment.segment()
        }

  @type t :: [compiled_event()]

  @doc """
  当速度事件发生变化时，重新编译时间线。
  """
  @spec compile(Tempo.tempo_events()) :: {:ok, t()} | {:error, term()}
  def compile([]), do: {:error, :empty_tempo_events}

  def compile({[], _last_tick}), do: {:error, :empty_tempo_events}

  def compile([_ | _] = tempo_events),
    do: compile({tempo_events, Tick.get_dynamic_tick()})

  def compile({events, last_tick}) do
    with :ok <- last_tick_valid?(last_tick),
         :ok <- event_start_with_numeric?(events),
         sorted = Enum.sort_by(events, fn {tick, _event} -> tick end),
         :ok <- no_duplicate_ticks?(sorted),
         :ok <- first_event_valid?(sorted) do
      do_compile(sorted, last_tick, 0.0, [])
    end
  end

  @doc "在 compiled_map 中查找 target_tick 所对应的秒数。"
  def tick_to_sec(compiled_map, target_tick) do
    case binary_search_segment(compiled_map, target_tick) do
      nil -> nil
      seg -> seg.start_sec + Tempo.tick_to_sec(seg.strategy, target_tick - seg.start_tick)
    end
  end

  # 反向查询
  def sec_to_tick(compiled_map, target_sec) do
    Enum.reduce_while(compiled_map, nil, fn seg, _acc ->
      seg_end_sec = seg.start_sec + Tempo.duration_sec(seg.strategy)

      if target_sec >= seg.start_sec and target_sec < seg_end_sec do
        offset_sec = target_sec - seg.start_sec
        offset_tick = Tempo.sec_to_tick(seg.strategy, offset_sec)
        {:halt, seg.start_tick + offset_tick}
      else
        {:cont, nil}
      end
    end)
  end

  # ---- 关于 compile/1 的工具函数 ----

  # 最后一刻是刻
  defp last_tick_valid?(tick) when is_tick(tick), do: :ok
  defp last_tick_valid?(tick), do: {:error, {:invalid_last_tick, tick}}

  # 所有事件以时间刻开始
  defp event_start_with_numeric?(events) do
    Enum.find(events, fn
      {tick, _event} when is_numeric_tick(tick) -> false
      _ -> true
    end)
    |> case do
      nil -> :ok
      bad -> {:error, {:invalid_tempo_event_tick, bad}}
    end
  end

  # 没有一刻对应着多个事件的情况
  defp no_duplicate_ticks?(events) do
    ticks = Enum.map(events, fn {tick, _event} -> tick end)

    if(length(ticks) == length(Enum.uniq(ticks)),
      do: :ok,
      else: {:error, :duplicate_tempo_event_ticks}
    )
  end

  # 看完屁股看身子，看完身子看脑袋
  # 首个事件从 0 开始
  defp first_event_valid?([]), do: {:error, :empty_tempo_events}
  defp first_event_valid?([{0, _} | _]), do: :ok

  defp first_event_valid?([{tick, _event} | _rest]),
    do: {:error, {:first_tempo_event_must_start_at_zero, tick}}

  # 一个经典的递归操作
  defp do_compile(
         [{start_tick, event}, {end_tick, _next_event} = next | rest],
         last_tick,
         current_sec,
         acc
       ) do
    with {:ok, compiled} <- build_compiled_event(start_tick, end_tick, event, current_sec),
         duration when is_number(duration) <- Tempo.duration_sec(compiled.strategy) do
      next_sec = current_sec + duration

      do_compile([next | rest], last_tick, next_sec, [compiled | acc])
    else
      :infinity ->
        {:error, {:unexpected_infinite_duration, %{start_tick: start_tick, end_tick: end_tick}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 最后一个片段
  defp do_compile([{start_tick, event}], last_tick, current_sec, acc) do
    with {:ok, compiled} <- build_compiled_event(start_tick, last_tick, event, current_sec) do
      {:ok, Enum.reverse([compiled | acc])}
    end
  end

  # 构建片段载荷
  defp build_compiled_event(start_tick, end_tick, event, current_sec) do
    with {:ok, strategy} <-
           Tempo.build_segment_from_event(
             event.module,
             start_tick,
             end_tick,
             event.context
           ) do
      {:ok,
       %{
         start_tick: start_tick,
         end_tick: end_tick,
         start_sec: current_sec,
         strategy: strategy
       }}
    end
  end

  # ---- tick_to_sec 的工具函数 ----

  # 二分搜索
  defp binary_search_segment(compiled_map, target_tick) do
    # compiled_map 按 start_tick 升序排列
    idx =
      Enum.find_index(compiled_map, fn seg ->
        seg.start_tick <= target_tick and
          (seg.end_tick == :infinity or target_tick < seg.end_tick)
      end)

    idx && Enum.at(compiled_map, idx)
  end
end
