defmodule EquinoxDomain.Score.SliceFlag do
  @moduledoc """
  音符切片旗标（slice_flag）——`EquinoxDomain.Windowing` 的输入信号。

  存储于 `Coconut.Score.Note.metadata`（宿主扩展点），键为 `"slice_flag"`，
  值为字符串 `"force_slice" | "force_merge"`；`:auto` 为缺省
  （不写或读不到即视为 `:auto`）。

  ## 语义

  flag 管辖的是该音符**之前**的边界：

  - `:force_slice` — 此音符前必切（无论间隙多小）
  - `:force_merge` — 此音符前禁切（无论休止多大）
  - `:auto` — 交给休止检测
  """

  alias Coconut.Score.Note

  @type t :: :auto | :force_slice | :force_merge

  @metadata_key "slice_flag"

  @doc "读取音符的 slice_flag；容忍原子/字符串两种写法，未知值按 `:auto`。"
  @spec get(Note.t()) :: t()
  def get(%Note{metadata: metadata}) do
    case Map.get(metadata, @metadata_key) do
      "force_slice" -> :force_slice
      :force_slice -> :force_slice
      "force_merge" -> :force_merge
      :force_merge -> :force_merge
      _ -> :auto
    end
  end

  @doc """
  写入音符的 slice_flag。

  `:auto` 从 metadata 删除该键，其余写入字符串形式；
  非法 flag 返回 `{:error, {:invalid_slice_flag, flag}}`。
  """
  @spec set(Note.t(), t()) :: {:ok, Note.t()} | {:error, term()}
  def set(%Note{} = note, :auto) do
    Note.update(note, metadata: Map.delete(note.metadata, @metadata_key))
  end

  def set(%Note{} = note, flag) when flag in [:force_slice, :force_merge] do
    Note.update(note, metadata: Map.put(note.metadata, @metadata_key, Atom.to_string(flag)))
  end

  def set(%Note{}, flag), do: {:error, {:invalid_slice_flag, flag}}
end
