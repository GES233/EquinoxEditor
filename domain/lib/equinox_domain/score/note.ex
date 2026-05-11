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

  # ---- 元数据操作 ----

  @doc "更新附属的元数据，通过合并并入 current_metadata"
  @spec update_metadata(t(), map()) :: {:ok, t()} | {:error, term()}
  def update_metadata(note, new_metadata) when is_map(new_metadata) do
    {:ok, %{note | metadata: Map.merge(note.metadata, new_metadata)}}
  end

  @doc """
  读取元数据。

  * 无 key 时返回全部
  * 传 key 时返回 ok_or_err
  """
  @spec get_metadata(t()) :: {:ok, map()}
  def get_metadata(note), do: {:ok, note.metadata}

  # 使用 Map.fetch/2 区分是 nil 还是 not exist
  @spec get_metadata(t(), atom()) :: {:ok, term()} | {:error, {:key_not_found, atom()}}
  def get_metadata(note, key) when is_atom(key) do
    case Map.fetch(note.metadata, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:key_not_found, key}}
    end
  end

  @doc "移除元数据"
  # 应用于插件生命周期结束或序列化
  @spec remove_metadata(t(), :all | [atom()]) :: t()
  def remove_metadata(note, :all), do: %{note | metadata: %{}}

  def remove_metadata(note, keys) when is_list(keys) do
    %{note | metadata: Map.drop(note.metadata, keys)}
  end

  # ---- 音符切分与合并 ----

  @doc """
  在指定绝对 tick 位置切开音符。

  返回 `{:ok, [note_before, note_after]}`，两个音符均生成新 ID。
  `split_tick` 必须在音符内部（严格大于 start_tick，严格小于 end_tick）。

  `attrs` 可选，用于覆盖切分后后部音符的字段（如不同的歌词）。
  """
  @spec split(t(), Tick.t(), map() | keyword()) :: {:ok, [t()]} | {:error, term()}
  def split(note, split_tick, attrs \\ []) do
    note_end = note.start_tick + note.duration_tick

    cond do
      split_tick <= note.start_tick ->
        {:error, {:split_tick_before_note, split_tick, note.start_tick}}

      split_tick >= note_end ->
        {:error, {:split_tick_after_note, split_tick, note_end}}

      true ->
        before = %{note | duration_tick: split_tick - note.start_tick}

        after_note =
          %{
            start_tick: split_tick,
            duration_tick: note_end - split_tick,
            key: note.key,
            lyric: note.lyric,
            slice_flag: note.slice_flag,
            annotation: note.annotation,
            metadata: note.metadata
          }
          |> Map.merge(normalize_attrs(attrs, @keys))
          |> new()

        {:ok, [before, after_note]}
    end
  end

  @doc """
  合并两个音符。

  ## 选项

  - `:gap_tolerance` — 允许的音符间最大间隙（tick），默认 0（必须相邻或重叠）

  ## 行为

  - 两个音符必须是同一音高（通过 Key.to_midi/1 比较）
  - 必须重叠，或间隙 ≤ `gap_tolerance`
  - 返回 `{:ok, merged_note}`，生成新 ID
  - 合并后 `slice_flag` 设为 `:auto`
  - 歌词拼接（两者均有值时直接连接），标注取第一个非 nil 值
  """
  @spec merge(t(), t(), keyword()) :: {:ok, t()} | {:error, term()}
  def merge(note1, note2, opts \\ []) do
    gap_tolerance = Keyword.get(opts, :gap_tolerance, 0)
    note1_end = note1.start_tick + note1.duration_tick
    note2_end = note2.start_tick + note2.duration_tick

    cond do
      Key.to_midi(note1.key) != Key.to_midi(note2.key) ->
        {:error, {:key_mismatch, Key.to_midi(note1.key), Key.to_midi(note2.key)}}

      note1_end + gap_tolerance < note2.start_tick or
          note2_end + gap_tolerance < note1.start_tick ->
        {:error, {:gap_too_large, note1_end, note2.start_tick, gap_tolerance}}

      true -> do_merge(note1, note1_end, note2, note2_end)
    end
  end

  # ---- 一些工具函数 ----

  # 执行合并
  defp do_merge(note1, note1_end, note2, note2_end) do
    start_tick = min(note1.start_tick, note2.start_tick)
    end_tick = max(note1_end, note2_end)

    lyric =
      cond do
        is_nil(note1.lyric) and is_nil(note2.lyric) -> nil
        is_nil(note1.lyric) -> note2.lyric
        is_nil(note2.lyric) -> note1.lyric
        note1.lyric == note2.lyric -> note1.lyric
        # 考虑后者为连续的什么 -> 那就使用前者
        true -> note1.lyric <> note2.lyric
      end

    # 这里可能需要讨论下
    annotation = note1.annotation || note2.annotation

    merged =
      %{
        start_tick: start_tick,
        duration_tick: end_tick - start_tick,
        key: note1.key,
        lyric: lyric,
        slice_flag: :auto,
        annotation: annotation,
        metadata: Map.merge(note1.metadata, note2.metadata)
      }
      |> new()

    {:ok, merged}
  end

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

  # 在这里加一个对 metadata 处理的函数
  # 因为可能涉及插件的关系
  # 遍历模块即可

  # ---- 作为音符的属性 ----
  # Note:
  # 【关于时长】  <- 需要引入对应模块
  # 需要和 merge/3 一样，引入容忍程度
  # 以兼容手绘音符与从乐谱转换的音符的差异
end
