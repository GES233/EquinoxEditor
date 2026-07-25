defmodule EquinoxDomain.Pickle.TimeSigEvents do
  @moduledoc """
  拍号源事件列表（`Zongzi.Score.TimeSig.time_sig_events()`）的原生对象 codec。

  事件为 `{bar, sig}`，sig 归一化编码（tuple / atom → list / binary）：

  - `{n, d}` 与 `{:standard, n, d}` → `["standard", n, d]`
  - `{:compound, groupings, d}` → `["compound", groupings, d]`
  - `:san` → `"san"`

  dump 为 `[[bar, encoded_sig], ...]`；输入形态与
  `Zongzi.Score.TimeSigMap.compile/2` 对齐：纯列表 → `%{events: [...]}`，
  `{events, end_bar}` → `%{events: [...], end_bar: end_bar}`，load 还原同形态。

  注意：`{n, d}` 与 `{:standard, n, d}` 编码相同，load 统一还原为
  规范形 `{:standard, n, d}`（zongzi compile 对两者等价处理）。
  """

  @behaviour EquinoxDomain.Pickle

  @impl true
  def dump(events) when is_list(events) do
    with {:ok, dumped} <- dump_events(events) do
      {:ok, %{events: dumped}}
    end
  end

  def dump({events, end_bar}) when is_list(events) do
    with {:ok, dumped} <- dump_events(events) do
      {:ok, %{events: dumped, end_bar: end_bar}}
    end
  end

  def dump(other), do: {:error, {:invalid_time_sig_events, other}}

  @impl true
  def load(%{} = data) do
    with {:ok, events} <- load_events(Map.get(data, :events, [])) do
      case Map.fetch(data, :end_bar) do
        {:ok, end_bar} -> {:ok, {events, end_bar}}
        :error -> {:ok, events}
      end
    end
  end

  defp dump_events(events) do
    events
    |> Enum.reduce_while({:ok, []}, fn
      {bar, sig}, {:ok, acc} when is_integer(bar) ->
        case encode_sig(sig) do
          {:ok, encoded} -> {:cont, {:ok, [[bar, encoded] | acc]}}
          {:error, _} = err -> {:halt, err}
        end

      other, _acc ->
        {:halt, {:error, {:invalid_time_sig_event, other}}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp load_events(dumped) do
    dumped
    |> Enum.reduce_while({:ok, []}, fn
      [bar, encoded], {:ok, acc} when is_integer(bar) ->
        case decode_sig(encoded) do
          {:ok, sig} -> {:cont, {:ok, [{bar, sig} | acc]}}
          {:error, _} = err -> {:halt, err}
        end

      other, _acc ->
        {:halt, {:error, {:invalid_time_sig_event_dump, other}}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp encode_sig({n, d}) when is_integer(n) and is_integer(d), do: {:ok, ["standard", n, d]}

  defp encode_sig({:standard, n, d}) when is_integer(n) and is_integer(d),
    do: {:ok, ["standard", n, d]}

  defp encode_sig({:compound, groupings, d}) when is_list(groupings) and is_integer(d),
    do: {:ok, ["compound", groupings, d]}

  defp encode_sig(:san), do: {:ok, "san"}
  defp encode_sig(other), do: {:error, {:invalid_time_sig, other}}

  defp decode_sig(["standard", n, d]) when is_integer(n) and is_integer(d),
    do: {:ok, {:standard, n, d}}

  defp decode_sig(["compound", groupings, d]) when is_list(groupings) and is_integer(d),
    do: {:ok, {:compound, groupings, d}}

  defp decode_sig("san"), do: {:ok, :san}
  defp decode_sig(other), do: {:error, {:invalid_time_sig_dump, other}}
end
