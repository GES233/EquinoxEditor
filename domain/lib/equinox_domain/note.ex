defmodule EquinoxDomain.Note do
  @moduledoc """
  有关音符的领域模型。
  """
  alias EquinoxDomain.{Util.ID, Timeline.Tick, Key}

  use EquinoxDomain.Model,
    keys: [:id, :start_tick, :duration_tick, :key, :lyric, :slice_flag, :annotation, extra: %{}],
    id_prefix: "Note_"
  # 类型需要自己写
  @type t :: %__MODULE__{
          id: ID.t(),
          start_tick: Tick.t(),
          duration_tick: Tick.t(),
          key: Key.t(),
          lyric: String.t(),
          slice_flag: term(),
          annotation: String.t() | nil,
          extra: %{}
        }

  # ---- 业务函数 ----
  # 业务函数返回 {:ok, result} 或 {:error, reason}

  # 拖拽音符到新的高度与 start_tick
  def drag_note(note, new_key_or_tick) do
    # ...
  end

  # 拖拽时长
  # drag_duration/2

  # 修改歌词
  # update_lyric

  # 修改标注
  # update_annotation

  # 修改附属的元数据
  # update_metadata

  # 根据部分片段切开音符
  # split(note, split_tick) -> {:ok, [note_1, note_2]} | err

  # 合并同音高相邻的音符 => 怎么界定「相邻」？
  # merge(note1, note2, opts) -> {:ok, note} | err
end
