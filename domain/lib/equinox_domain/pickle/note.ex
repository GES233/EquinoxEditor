defmodule EquinoxDomain.Pickle.Note do
  @moduledoc """
  `Zongzi.Score.Note` 的原生对象 codec。

  除 `key` 外字段直出；`key` 摊平为 `%{module: key.__struct__, midi: Key.to_midi(key)}`，
  load 时经 `module.from_midi(midi, nil)` 重建（key 为 nil 时原样保留 nil）。
  其余字段经 `Zongzi.Score.Note.new/1` 重建（校验生效，`seq_id` 在 attrs 里原样带）。
  """

  @behaviour EquinoxDomain.Pickle

  alias Zongzi.Score.{Key, Note}

  @impl true
  def dump(%Note{} = note) do
    {:ok,
     %{
       id: note.id,
       start_tick: note.start_tick,
       duration_tick: note.duration_tick,
       key: dump_key(note.key),
       lyric: note.lyric,
       seq_id: note.seq_id,
       annotation: note.annotation,
       metadata: note.metadata
     }}
  end

  @impl true
  def load(%{} = data) do
    with {:ok, key} <- load_key(Map.get(data, :key)) do
      data
      |> Map.put(:key, key)
      |> Note.new()
    end
  end

  defp dump_key(nil), do: nil
  defp dump_key(%module{} = key), do: %{module: module, midi: Key.to_midi(key)}

  defp load_key(nil), do: {:ok, nil}

  # 未知 key module：from_midi 自然报错（或未实现），包装为 error tuple，不 raise
  defp load_key(%{module: module, midi: midi} = dumped)
       when is_atom(module) and is_number(midi) do
    module.from_midi(midi, nil)
  rescue
    _ -> {:error, {:key_from_midi_failed, dumped}}
  end

  defp load_key(other), do: {:error, {:invalid_key_dump, other}}
end
