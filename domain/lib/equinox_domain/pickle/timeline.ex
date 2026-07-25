defmodule EquinoxDomain.Pickle.Timeline do
  @moduledoc """
  `Zongzi.Timeline` 的原生对象 codec。

  dump 形状：

      %{
        note_order: [seq_id],        # 完整链表序（含墓碑）
        seq_map: %{seq_id => note_id},
        tombstones: [seq_id],        # 排序后的列表
        next_seq: pos_integer()
      }

  **不存 `track_id`**——由宿主 Track 在 load 时注入，故本模块的入口是
  `load/2` 而非 behaviour 的 `load/1`（也因此不声明 `@behaviour EquinoxDomain.Pickle`）。

  load 经 `Zongzi.Timeline.build/1` 重建链表（nodes/head/tail 由 note_order 推导）。
  """

  alias Zongzi.Timeline
  alias Zongzi.Util.ID

  @doc "把 Timeline 摊平为 plain map（不含 track_id）。"
  @spec dump(Timeline.t()) :: {:ok, map()}
  def dump(%Timeline{} = timeline) do
    {:ok,
     %{
       note_order: Timeline.to_list(timeline),
       seq_map: timeline.seq_map,
       tombstones: timeline.tombstones |> MapSet.to_list() |> Enum.sort(),
       next_seq: timeline.next_seq
     }}
  end

  @doc "从 plain map 重建 Timeline，`track_id` 由宿主注入。"
  @spec load(map(), ID.t()) :: {:ok, Timeline.t()}
  def load(%{} = data, track_id) do
    attrs = %{
      track_id: track_id,
      note_order: Map.get(data, :note_order, []),
      seq_map: Map.get(data, :seq_map, %{}),
      tombstones: Map.get(data, :tombstones, [])
    }

    # build/1 对缺省 next_seq 有兜底（max(note_order) + 1），仅在显式存在时覆盖
    attrs =
      case Map.fetch(data, :next_seq) do
        {:ok, next_seq} -> Map.put(attrs, :next_seq, next_seq)
        :error -> attrs
      end

    Timeline.build(attrs)
  end
end
