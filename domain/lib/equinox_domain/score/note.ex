defmodule EquinoxDomain.Score.Note do
  @moduledoc """
  有关音符的领域模型。
  """
  alias EquinoxDomain.{Util.ID, Util.Model, Util.Pickle, Timeline.Tick, Score.Key}

  # 切片操作逻辑
  # 默认交给 Slicer 根据休止时间自动判断
  # 强制操作为该音符和【后面的】
  @type slice_flag ::
          :auto
          | :force_slice
          | :force_merge

  use Model,
    keys: [
      :id,
      :start_tick,
      :duration_tick,
      :key,
      :lyric,
      slice_flag: :auto,
      annotation: nil,
      metadata: %{}
    ],
    id_prefix: "Note_"

  # 类型需要自己写
  @type t :: %__MODULE__{
          id: ID.t(),
          start_tick: Tick.t(),
          duration_tick: Tick.t(),
          key: Key.t(),
          lyric: String.t() | nil,
          slice_flag: slice_flag(),
          annotation: String.t() | nil,
          metadata: %{}
        }

  # ---- 业务函数 ----
  # 业务函数返回 {:ok, result} 或 {:error, reason}

  @doc "拖拽音符到新的高度与 start_tick"
  @spec drag_note(
          t(),
          %{optional(:start_tick) => Tick.t(), optional(:key) => Key.t()}
          | keyword(Tick.t() | Key.t())
        ) ::
          {:ok, t()} | {:error, term()}
  def drag_note(note, new_key_or_tick) do
    {new_key, new_key_or_tick} = new_key_or_tick |> Map.new() |> Map.pop(:key, note.key)
    {new_start_tick, new_key_or_tick} = Map.pop(new_key_or_tick, :start_tick, note.start_tick)

    with 0 <- map_size(new_key_or_tick), true <- new_start_tick >= 0 do
      {:ok, %{note | key: new_key, start_tick: new_start_tick}}
    else
      false -> {:error, {:invalid_negative_tick, new_start_tick}}
      _num -> {:error, {:extra_fields_exist, new_key_or_tick}}
    end
  end

  @doc "拖拽时长"
  @spec drag_duration(t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def drag_duration(note, new_duraion) do
    with true <- new_duraion >= 0 do
      {:ok, %{note | duration_tick: new_duraion}}
    else
      false -> {:error, {:invalid_negative_tick, new_duraion}}
    end
  end

  @doc "修改歌词"
  @spec update_lyric(t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def update_lyric(note, new_lyric) do
    case new_lyric do
      nil -> {:ok, %{note | lyric: nil}}
      new_lyric when is_binary(new_lyric) -> {:ok, %{note | lyric: new_lyric}}
      _ -> {:error, :lyric_not_support}
    end
  end

  @doc "修改标注"
  @spec update_annotation(t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def update_annotation(note, new_annotation) do
    case new_annotation do
      nil -> {:ok, %{note | annotation: nil}}
      new_annotation when is_binary(new_annotation) -> {:ok, %{note | annotation: new_annotation}}
      _ -> {:error, :annotation_not_support}
    end
  end

  # 修改附属的元数据
  # def update_metadata(note, new_metadata_kw)
  # 通过合并并入 current_metadata

  # 移除元数据（应用于插件生命周期结束或序列化）
  def remove_metadata(note, :all), do: %{note | metadata: %{}}
  # def remove_metadata(note, metadata_keys) when is_list(metadata_keys) do

  # 根据部分片段切开音符
  # split(note, split_tick) -> {:ok, [note_1, note_2]} | err

  # 合并同音高相邻的音符 => 怎么界定「相邻」？在 opts 内设定「容忍 gap tick」
  # merge(note1, note2, opts) -> {:ok, note} | err

  # ---- 序列化与反序列化 ----
  # @behaviour EquinoxDomain.Util.Pickle

  @spec serialize(t()) :: {:ok, Pickle.serialized()} | {:error, term()}
  def serialize(note) do
    with {:ok, start_tick} <- Tick.serialize(note.start_tick),
         {:ok, duration_tick} <- Tick.serialize(note.duration_tick) do
      # TODO:
      # key 等类型需要实现对应的协议
      # 确定 slice_flag 以及 matadata
      {:ok,
       %{
         "type" => "Note",
         "id" => note.id,
         "start" => start_tick,
         "duration" => duration_tick,
         "key" => note.key
       }}
    end
  end

  # @spec deserialze(Pickle.serialized()) :: {:ok, t()} | {:error, term()}

  # ---- 作为音符的属性 ----
  # Note:
  # 【关于时长】
  # 需要和 merge/3 一样，引入容忍程度
  # 以兼容手绘音符与从乐谱转换的音符的差异
end
