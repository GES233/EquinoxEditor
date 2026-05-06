defmodule EquinoxDomain.Timeline.TimeSigMap do
  @moduledoc """
  拍号变化事件的编译映射表。

  内部委托 `RecordMap` 完成编译与基于 Bar 的二分查找，
  自身负责 Bar→Tick 与 Tick→Bar 的转换。

  编译后的结构形如：

      {
        %{
          start_pos: 0,
          end_pos: 4,
          start_bar: 1,
          start_tick: 0,
          end_tick: 7680,
          time_sig: {:standard, 4, 4}
        },
        %{
          start_pos: 4,
          end_pos: 6,
          start_bar: 5,
          start_tick: 7680,
          end_tick: 10560,
          time_sig: {:standard, 3, 4}
        },
        ...
      }

  - `start_pos` / `end_pos` 是从 0 开始的内部位置，方便 `RecordMap` 进行二分查找
  - `start_bar` 是从 1 开始的用户可见小节号
  - `start_tick` / `end_tick` 是对应的累计 Tick 范围
  - 区间格式左闭右开

  ## 用例

      iex> TimeSigMap.compile([{1, {:standard, 4, 4}}, {8, {:standard, 3, 4}}, {15, {:standard, 4, 4}}])
      {:ok,
      {%{
          start_pos: 0,
          end_pos: 7,
          start_bar: 1,
          start_tick: 0,
          end_tick: 13440,
          time_sig: {:standard, 4, 4}
        },
        %{
          start_pos: 7,
          end_pos: 14,
          start_bar: 8,
          start_tick: 13440,
          end_tick: 23520,
          time_sig: {:standard, 3, 4}
        },
        %{
          start_pos: 14,
          end_pos: :open_end,
          start_bar: 15,
          start_tick: 23520,
          end_tick: :dynamic_tick,
          time_sig: {:standard, 4, 4}
        }}}
  """

  alias EquinoxDomain.Timeline.{TimeSig, RecordMap, Record, Tick}
  import Tick

  @type compiled_event :: %{
          start_pos: Record.position(),
          end_pos: Record.end_position(),
          start_bar: pos_integer(),
          start_tick: Tick.numeric_tick(),
          end_tick: Tick.t(),
          time_sig: TimeSig.t()
        }

  @type t :: tuple()

  @doc """
  编译拍号事件列表为可二分查找的元组。

  事件格式：`[{bar, time_sig}, ...]`，bar 从 1 开始。
  """
  @spec compile(TimeSig.time_sig_events()) :: {:ok, t()} | {:error, term()}
  def compile([]), do: {:error, :empty_time_sig_events}

  def compile({[], _last_bar}), do: {:error, :empty_time_sig_events}

  def compile([_ | _] = events) do
    compile({events, Record.open_end()})
  end

  def compile({events, end_bar}) do
    with {:ok, record_events} <- normalize_bar_events(events),
         {:ok, record_end} <- normalize_end_bar(end_bar) do
      reducer = fn start_pos, end_pos, time_sig, current_tick ->
        tpb = TimeSig.ticks_per_bar(time_sig)

        case {tpb, end_pos} do
          {nil, _} ->
            # 散拍子：无法计算 tick 边界
            {:ok,
             %{
               start_pos: start_pos,
               end_pos: end_pos,
               start_bar: start_pos + 1,
               start_tick: current_tick,
               end_tick: Tick.get_dynamic_tick(),
               time_sig: time_sig
             }, current_tick}

          {tpb, end_pos} when is_integer(tpb) and is_integer(end_pos) ->
            num_bars = end_pos - start_pos
            end_tick = current_tick + tpb * num_bars

            {:ok,
             %{
               start_pos: start_pos,
               end_pos: end_pos,
               start_bar: start_pos + 1,
               start_tick: current_tick,
               end_tick: end_tick,
               time_sig: time_sig
             }, end_tick}

          {tpb, :open_end} when is_integer(tpb) ->
            {:ok,
             %{
               start_pos: start_pos,
               end_pos: end_pos,
               start_bar: start_pos + 1,
               start_tick: current_tick,
               end_tick: Tick.get_dynamic_tick(),
               time_sig: time_sig
             }, current_tick}
        end
      end

      RecordMap.compile({record_events, record_end}, reducer, 0)
    end
  end

  @doc """
  将给定小节号转换为起始 Tick。

  返回该小节第一拍的 Tick 位置。
  """
  @spec bar_to_tick(t(), TimeSig.bar()) :: {:ok, Tick.numeric_tick()} | {:error, term()}
  def bar_to_tick(compiled, target_bar) when target_bar >= 1 do
    pos = target_bar - 1
    seg = RecordMap.find_by_position(compiled, pos)

    case TimeSig.ticks_per_bar(seg.time_sig) do
      nil ->
        {:error, {:free_meter_at_bar, target_bar}}

      tpb ->
        bars_offset = pos - seg.start_pos
        {:ok, seg.start_tick + tpb * bars_offset}
    end
  end

  def bar_to_tick(_compiled, bad_bar),
    do: {:error, {:invalid_bar, bad_bar}}

  @doc """
  将给定 Tick 转换为所在的小节号。

  返回该 Tick 落于的小节（1-based）。
  """
  @spec tick_to_bar(t(), Tick.numeric_tick()) :: {:ok, TimeSig.bar()} | {:error, term()}
  def tick_to_bar(compiled, target_tick) when is_numeric_tick(target_tick) do
    seg = find_by_tick(compiled, target_tick)

    case TimeSig.ticks_per_bar(seg.time_sig) do
      nil ->
        {:error, {:free_meter_at_tick, target_tick}}

      tpb ->
        tick_offset = target_tick - seg.start_tick
        bar_offset = div(tick_offset, tpb)
        {:ok, seg.start_bar + bar_offset}
    end
  end

  def tick_to_bar(_compiled, bad_tick),
    do: {:error, {:invalid_tick, bad_tick}}

  # ---- 内部函数 ----

  # 二分搜索：按 Tick 定位区间
  defp find_by_tick(tuple, target_tick, low, high) when low <= high do
    mid = div(low + high, 2)
    seg = elem(tuple, mid)

    cond do
      target_tick < seg.start_tick ->
        find_by_tick(tuple, target_tick, low, mid - 1)

      is_numeric_tick(seg.end_tick) and target_tick >= seg.end_tick ->
        find_by_tick(tuple, target_tick, mid + 1, high)

      true ->
        seg
    end
  end

  defp find_by_tick(tuple, _target_tick, _low, _high),
    do: elem(tuple, tuple_size(tuple) - 1)

  defp find_by_tick(tuple, target_tick),
    do: find_by_tick(tuple, target_tick, 0, tuple_size(tuple) - 1)

  defp normalize_bar_events(events) do
    normalized =
      Enum.map(events, fn
        {bar, time_sig} when is_integer(bar) and bar >= 1 ->
          {bar - 1, time_sig}

        bad ->
          bad
      end)

    {:ok, normalized}
  end

  defp normalize_end_bar(:open_end), do: {:ok, Record.open_end()}

  defp normalize_end_bar(end_bar) when is_integer(end_bar) and end_bar >= 1 do
    # 这里把用户可见 bar 边界转成内部 position 边界。
    # 因为左闭右开 [start_bar, end_bar)，而他在右边，所以需要 -1 。
    {:ok, end_bar - 1}
  end

  defp normalize_end_bar(bad), do: {:error, {:invalid_end_bar, bad}}
end
