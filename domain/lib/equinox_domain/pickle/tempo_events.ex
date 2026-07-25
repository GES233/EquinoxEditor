defmodule EquinoxDomain.Pickle.TempoEvents do
  @moduledoc """
  tempo 源事件列表（`Zongzi.Score.Tempo.tempo_events()`）的原生对象 codec。

  事件为 `{tick, %Zongzi.Score.Tempo.Event{module: m, context: ctx}}`，
  dump 为 `[[tick, %{module: m, context: ctx}], ...]`（tuple → list；
  ctx 由契约保证是无 struct 的 plain map）。

  输入形态与 `Zongzi.Score.TempoMap.compile/2` 对齐：

  - 纯事件列表 → `%{events: [...]}`
  - `{events, last_tick}` 元组 → `%{events: [...], last_tick: last}`

  load 还原同形态（列表 / `{events, last_tick}`）。
  """

  @behaviour EquinoxDomain.Pickle

  alias Zongzi.Score.Tempo.Event

  @impl true
  def dump(events) when is_list(events) do
    with {:ok, dumped} <- dump_events(events) do
      {:ok, %{events: dumped}}
    end
  end

  def dump({events, last_tick}) when is_list(events) do
    with {:ok, dumped} <- dump_events(events) do
      {:ok, %{events: dumped, last_tick: last_tick}}
    end
  end

  def dump(other), do: {:error, {:invalid_tempo_events, other}}

  @impl true
  def load(%{} = data) do
    with {:ok, events} <- load_events(Map.get(data, :events, [])) do
      case Map.fetch(data, :last_tick) do
        {:ok, last_tick} -> {:ok, {events, last_tick}}
        :error -> {:ok, events}
      end
    end
  end

  defp dump_events(events) do
    events
    |> Enum.reduce_while({:ok, []}, fn
      {tick, %Event{module: module, context: context}}, {:ok, acc} when is_integer(tick) ->
        {:cont, {:ok, [[tick, %{module: module, context: context}] | acc]}}

      other, _acc ->
        {:halt, {:error, {:invalid_tempo_event, other}}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp load_events(dumped) do
    dumped
    |> Enum.reduce_while({:ok, []}, fn
      [tick, %{module: module, context: context}], {:ok, acc}
      when is_integer(tick) and is_atom(module) and is_map(context) ->
        {:cont, {:ok, [{tick, %Event{module: module, context: context}} | acc]}}

      other, _acc ->
        {:halt, {:error, {:invalid_tempo_event_dump, other}}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end
end
