defmodule Neume.Syllable do
  @moduledoc """
  跨音符音节组（melisma）的显式旗标与纯派生规则。

  身份表达：续音音符携带 `note.metadata["melisma"] == "continue"`，头音符
  缺省无键。组不是持久对象，而是按时间序对音符列表的纯派生：旗标仅在与
  前一音符贴接（`prev.end_tick == start_tick`）时生效，否则静默失效、该
  音符成为新组的头——删头自动晋升、移动出缝自动断组由此免费获得。

  组内成员的音素归属、逐成员音高与时长打包在 ScorePlan/Analysis 层消费；
  worker 只按展开后的词渲染，不对歌词或音高做启发式猜测。
  """

  @flag "continue"

  @typedoc "派生输入项：`{note_id, start_tick, end_tick, flagged?}`。"
  @type item :: {term(), non_neg_integer(), non_neg_integer(), boolean()}

  @typedoc """
  派生输出：`head_id` 指向组头音符 id，`member_index` 为组内序号
  （0 = 头），`continuation?` 为生效后的续音身份（旗标可能失效）。
  """
  @type membership :: %{
          id: term(),
          head_id: term(),
          member_index: non_neg_integer(),
          continuation?: boolean()
        }

  @doc "判断 metadata 是否携带续音旗标（不管是否生效）。"
  @spec flagged?(map() | nil) :: boolean()
  def flagged?(metadata) when is_map(metadata),
    do: Map.get(metadata, "melisma") == @flag

  def flagged?(_metadata), do: false

  @doc """
  对按时间升序的音符列表派生组归属。

  每个音符恰属于一个组：无旗标或不满足贴接条件的音符自成组头；生效的
  续音音符并入前一音符所在组。
  """
  @spec derive_groups([item()]) :: [membership()]
  def derive_groups(notes) when is_list(notes) do
    {memberships, _previous} =
      Enum.map_reduce(notes, nil, fn {id, start_tick, end_tick, flagged?}, previous ->
        continuation? = flagged? and previous != nil and previous.end_tick == start_tick

        {head_id, member_index} =
          if continuation?,
            do: {previous.head_id, previous.member_index + 1},
            else: {id, 0}

        membership = %{
          id: id,
          head_id: head_id,
          member_index: member_index,
          continuation?: continuation?
        }

        {membership, %{end_tick: end_tick, head_id: head_id, member_index: member_index}}
      end)

    memberships
  end
end
