defmodule EquinoxDomain.Timeline.TempoMap do
  @moduledoc """
  根据变化事件返回编译后的速度映射表。

  结构形如：

      {
        %{start_tick: 0, end_tick: 1920, start_sec: 0.0, strategy: %Step{bpm: 120}},
        %{start_tick: 1920, end_tick: 2400, start_sec: 2.0, strategy: %Linear{...}},
        ...
      }

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

  @type t :: tuple()

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
         :ok <- first_event_valid?(sorted),
         {:ok, list_map} <- do_compile(sorted, last_tick, 0.0, []) do
      # 为什么这么设计，确保数据不可变，同时便于二分查找
      {:ok, List.to_tuple(list_map)}
    end
  end

  @doc "在 compiled_tuple 中查找 target_tick 所对应的秒数。"
  def tick_to_sec(compiled_tuple, target_tick) do
    seg = find_segment_by_tick(compiled_tuple, target_tick, 0, tuple_size(compiled_tuple) - 1)
    seg.start_sec + Tempo.tick_to_sec(seg.strategy, target_tick - seg.start_tick)
  end

  # 反向查询
  def sec_to_tick(compiled_tuple, target_sec) do
    seg = find_segment_by_sec(compiled_tuple, target_sec, 0, tuple_size(compiled_tuple) - 1)
    offset_sec = target_sec - seg.start_sec
    seg.start_tick + Tempo.sec_to_tick(seg.strategy, offset_sec)
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
  defp no_duplicate_ticks?(sorted_events) do
    has_dup? =
      sorted_events
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [{t1, _}, {t2, _}] -> t1 == t2 end)

    if has_dup?, do: {:error, :duplicate_tempo_event_ticks}, else: :ok
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
  defp find_segment_by_tick(tuple, target_tick, low, high) when low <= high do
    mid = div(low + high, 2)
    seg = elem(tuple, mid)

    cond do
      # 目标在当前片段左侧
      target_tick < seg.start_tick ->
        find_segment_by_tick(tuple, target_tick, low, mid - 1)

      # 目标在当前片段右侧且不是正无穷
      seg.end_tick != Tick.get_dynamic_tick() and target_tick >= seg.end_tick ->
        find_segment_by_tick(tuple, target_tick, mid + 1, high)

      # 命中区间（格式是左闭右开）
      true ->
        seg
    end
  end

  # 留个 Fallback ，下一个同理
  # 目前的策略是往回收一收
  # 也可以改成依照上一个 end_tick 为 bpm 的 Step （阶梯不是步骤）策略
  # 但先在这里留着，不用管
  defp find_segment_by_tick(tuple, _target_tick, _low, _high),
    do: elem(tuple, tuple_size(tuple) - 1)

  # ---- sec_to_tick 的工具函数 ----

  # 依旧二分搜索
  defp find_segment_by_sec(tuple, target_sec, low, high) when low <= high do
    mid = div(low + high, 2)
    seg = elem(tuple, mid)

    seg_end_sec = seg.start_sec + Tempo.duration_sec(seg.strategy)

    cond do
      target_sec < seg.start_sec ->
        find_segment_by_sec(tuple, target_sec, low, mid - 1)

      is_number(seg_end_sec) and target_sec >= seg_end_sec ->
        find_segment_by_sec(tuple, target_sec, mid + 1, high)

      true ->
        seg
    end
  end

  # 依旧 Fallback
  defp find_segment_by_sec(tuple, _target_sec, _low, _high),
    do: elem(tuple, tuple_size(tuple) - 1)
end
