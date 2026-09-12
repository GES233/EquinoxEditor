defmodule Neume.Phonology.Ref do
  @moduledoc """
  stable phonology ref 的确定性派生与解析（pin carrier 批次 C，
  `design-2026-09-pin-carriers` §7）。

  ref 不引入持久化 ID，全部由谱面事实确定性派生：

  - **unit ref** = 组头 note_id（Tamale 稳定锚；组归属由
    `Neume.Syllable` 纯派生，删头晋升/出缝断组规则不变）；
  - **segment ref** = `%{unit: 组头 note_id, member: 组内序号,
    index: 成员内音素序号}`——成员内序号是 Neume 层对确定性序列的
    派生，不是 runtime worker 的展开下标。

  ref 是位置性的：安全性由 base 兜住（`Pin<Co>` 底料覆盖全组输入事实
  + phonology digest），任何挪动序列的编辑先冲突、走 repatch 显式
  重签；本模块只负责派生与解析，不做裁决。

  本模块不跑 G2P、不调 worker：`resolve/3` 消费的逐音符音素序列由
  runtime probe（`Neume.Runtime.phonemes/3`）提供。
  """

  alias Coconut.Edit.Track
  alias Neume.Syllable

  @typedoc "unit ref：组头 note_id。"
  @type unit_ref :: term()

  @typedoc """
  segment ref：unit 内第 `member` 个成员（0 = 头）的第 `index` 个音素。
  """
  @type segment_ref :: %{
          unit: unit_ref(),
          member: non_neg_integer(),
          index: non_neg_integer()
        }

  @doc """
  对按时间升序的音符列表派生组归属（委托 `Neume.Syllable.derive_groups/1`），
  返回 `%{note_id => membership}`。
  """
  @spec memberships([Syllable.item()]) :: %{term() => Syllable.membership()}
  def memberships(notes) when is_list(notes),
    do: notes |> Syllable.derive_groups() |> Map.new(&{&1.id, &1})

  @doc """
  从轨道谱面事实派生全轨组归属：`Track.view/1` 的音符、span 与
  melisma 旗标构造 `memberships/1` 的 items（Track 入口的便捷封装）。
  """
  @spec track_memberships(Track.t()) :: %{term() => Syllable.membership()}
  def track_memberships(%Track{} = track) do
    track
    |> Track.view()
    |> Enum.map(fn {id, note, {start_tick, end_tick}} ->
      {id, start_tick, end_tick, Syllable.flagged?(note.metadata)}
    end)
    |> memberships()
  end

  @doc """
  由组归属派生 unit 组成表：`%{组头 note_id => [成员 note_id, ...]}`，
  成员按组内序号升序（头在首位）。
  """
  @spec units(%{term() => Syllable.membership()}) :: %{unit_ref() => [term()]}
  def units(memberships) when is_map(memberships) do
    memberships
    |> Map.values()
    |> Enum.group_by(& &1.head_id)
    |> Map.new(fn {head_id, members} ->
      {head_id, members |> Enum.sort_by(& &1.member_index) |> Enum.map(& &1.id)}
    end)
  end

  @doc "某成员资格的第 `index` 个音素的 segment ref。"
  @spec segment(Syllable.membership(), non_neg_integer()) :: segment_ref()
  def segment(%{head_id: head_id, member_index: member_index}, index)
      when is_integer(index) and index >= 0,
      do: %{unit: head_id, member: member_index, index: index}

  @doc """
  把 segment ref 解析为逐音符音素序列中的具体音素。

  `units` 为 `units/1` 产物，`note_phonemes` 为 runtime probe 的逐音符
  音素序列（`%{note_id => [[language, symbol]]}`）。ref 的任何一级
  解析失败（unit 不存在、member 越界、音符无序列、index 越界）都返回
  `{:error, {:unknown_segment_ref, ref}}`，不静默选错。
  """
  @spec resolve(segment_ref(), %{unit_ref() => [term()]}, %{term() => [[term()]]}) ::
          {:ok, [term()]} | {:error, {:unknown_segment_ref, segment_ref()}}
  def resolve(%{unit: unit, member: member, index: index} = ref, units, note_phonemes)
      when is_map(units) and is_map(note_phonemes) do
    with {:ok, members} <- fetch(units, unit, ref),
         {:ok, note_id} <- fetch(members, member, ref),
         {:ok, phonemes} <- fetch(note_phonemes, note_id, ref),
         {:ok, phoneme} <- fetch(phonemes, index, ref) do
      {:ok, phoneme}
    end
  end

  defp fetch(map, key, ref) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unknown_segment_ref, ref}}
    end
  end

  defp fetch(list, index, ref) when is_list(list) do
    case Enum.fetch(list, index) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unknown_segment_ref, ref}}
    end
  end
end
