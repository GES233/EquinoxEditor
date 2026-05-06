defmodule EquinoxDomain.Timeline.RecordMap do
  @moduledoc """
  通用的 Record 编译与二分查找引擎。

  将一系列 positioned Records 编译为左闭右开的区间元组，
  提供二分查找能力。

  ## 编译后事件

  每个 compiled_event 必须包含 `start_pos` 和 `end_pos` 字段，
  其余字段由 `reducer` 自由填充。

  ## 示例

      # TempoMap 的 compile
      reducer = fn start_tick, end_tick, event, current_sec ->
        with {:ok, strategy} <- Tempo.build_segment_from_event(...) do
          duration = Tempo.duration_sec(strategy)
          {:ok, %{start_pos: start_tick, end_pos: end_tick, start_sec: current_sec, strategy: strategy},
           current_sec + duration}
        end
      end

      RecordMap.compile(tempo_events, reducer, 0.0)
  """

  alias EquinoxDomain.Timeline.{Record, Tick}
  import Tick

  @typedoc """
  编译后的事件。

  必须包含 `start_pos` 和 `end_pos` 用于二分查找。
  """
  @type compiled_event :: %{
          :start_pos => Record.position(),
          :end_pos => Tick.t(),
          optional(atom()) => term()
        }

  @type t :: tuple()

  @typedoc """
  Reducer 函数签名。

  接收当前区间的起始位置、结束位置、Record 值和累积状态，
  返回 `{:ok, compiled_event, new_acc}` 或 `{:error, reason}`。
  """
  @type reducer :: (Record.position(), Tick.t(), Record.value(), term() ->
                      {:ok, compiled_event(), term()} | {:error, term()})

  # ---- 编译 ----

  @doc """
  编译 Record 列表为可二分查找的元组。

  返回 `{:ok, compiled_tuple}` 或 `{:error, reason}`。
  """
  @spec compile(Record.records(), reducer(), term()) :: {:ok, t()} | {:error, term()}
  def compile([], _reducer, _initial_acc), do: {:error, :empty_records}

  def compile({[], _last}, _reducer, _initial_acc), do: {:error, :empty_records}

  def compile([_ | _] = records, reducer, initial_acc),
    do: compile({records, Tick.get_dynamic_tick()}, reducer, initial_acc)

  def compile({records, last_tick}, reducer, initial_acc) do
    with :ok <- last_tick_valid?(last_tick),
         :ok <- all_positions_numeric?(records),
         sorted = Enum.sort_by(records, fn {pos, _v} -> pos end),
         :ok <- no_duplicate_positions?(sorted),
         :ok <- first_record_at_zero?(sorted),
         {:ok, list_map} <- do_compile(sorted, last_tick, initial_acc, reducer, []) do
      {:ok, List.to_tuple(list_map)}
    end
  end

  # ---- 二分查找 ----

  @doc """
  在编译后的元组中查找包含 `target_pos` 的区间。

  区间格式为左闭右开 `[start_pos, end_pos)`。
  当 `target_pos` 超出所有区间时，返回最后一个区间。
  """
  @spec find_by_position(t(), Record.position()) :: compiled_event()
  def find_by_position(tuple, target_pos) do
    do_find(tuple, target_pos, 0, tuple_size(tuple) - 1)
  end

  # ---- 内部函数 ----

  # 最后一刻是刻
  defp last_tick_valid?(tick) do
    if is_tick(tick), do: :ok, else: {:error, {:invalid_last_tick, tick}}
  end

  # 所有事件以时间开始
  defp all_positions_numeric?(records) do
    case Enum.find(records, fn {pos, _v} -> not is_integer(pos) or pos < 0 end) do
      nil -> :ok
      bad -> {:error, {:invalid_record_position, bad}}
    end
  end

  # 没有一刻对应着多个事件的情况
  defp no_duplicate_positions?(sorted_records) do
    has_dup? =
      sorted_records
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [{p1, _}, {p2, _}] -> p1 == p2 end)

    if has_dup?, do: {:error, :duplicate_record_positions}, else: :ok
  end

  # 看完屁股看身子，看完身子看脑袋
  # 首个事件从 0 开始
  defp first_record_at_zero?([]), do: {:error, :empty_records}
  defp first_record_at_zero?([{0, _} | _]), do: :ok

  defp first_record_at_zero?([{pos, _v} | _rest]),
    do: {:error, {:first_record_must_start_at_zero, pos}}

  # 递归编译：配对相邻 Record 形成区间
  defp do_compile(
         [{start_pos, value}, {end_pos, _next_value} = next | rest],
         last_tick,
         acc_state,
         reducer,
         acc
       ) do
    case reducer.(start_pos, end_pos, value, acc_state) do
      {:ok, compiled, new_acc} ->
        do_compile([next | rest], last_tick, new_acc, reducer, [compiled | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 最后一个 Record：延伸到动态终点
  defp do_compile([{start_pos, value}], last_tick, acc_state, reducer, acc) do
    case reducer.(start_pos, last_tick, value, acc_state) do
      {:ok, compiled, _new_acc} ->
        {:ok, Enum.reverse([compiled | acc])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 二分搜索：在区间元组中定位 target_pos
  defp do_find(tuple, target_pos, low, high) when low <= high do
    mid = div(low + high, 2)
    seg = elem(tuple, mid)

    cond do
      target_pos < seg.start_pos ->
        do_find(tuple, target_pos, low, mid - 1)

      is_numeric_tick(seg.end_pos) and target_pos >= seg.end_pos ->
        do_find(tuple, target_pos, mid + 1, high)

      true ->
        seg
    end
  end

  # Fallback：超出范围时返回最后一个区间
  defp do_find(tuple, _target_pos, _low, _high),
    do: elem(tuple, tuple_size(tuple) - 1)
end
