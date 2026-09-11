defmodule NeumeOpuDs.PhonologyRefVectorsTest do
  @moduledoc """
  stable phonology ref 的黄金向量契约（pin carrier 批次 C）。

  复用 `apps/neume/test/fixtures/expand_vectors.json`：对同一组 syllable
  group，segment ref（`%{unit: 组头, member, index}`）在真 worker 期望序列
  与替身（`Neume.FakePhonemes`）序列上的解析结果必须逐一相同——钉住
  批次 D duration v2 lowering 的双 runtime 一致性前提。

  `within_fake_approximation=false` 的用例替身必须报错（由
  `ExpandVectorsTest` 钉住），本测试只消费真身期望一侧。
  """

  use ExUnit.Case, async: true

  alias Neume.FakePhonemes
  alias Neume.Phonology.Ref

  @vectors __DIR__
           |> Path.join("../../../neume/test/fixtures/expand_vectors.json")
           |> Path.expand()
           |> File.read!()
           |> Jason.decode!()

  # 由 fixture 的 words/groups 合成 unit 组成表与成员资格：
  # 组内 [head | members]，未入组的词是单成员 unit；note_id 取字符串下标，
  # 与 note_phonemes 的 key 形状一致。
  defp units_and_memberships(words, groups) do
    groups = groups || []
    grouped = Map.new(groups, fn [head | _members] = group -> {head, group} end)

    member_of =
      for [_head | members] <- groups, member <- members, into: %{}, do: {member, true}

    units =
      0..(length(words) - 1)
      |> Enum.reject(&Map.has_key?(member_of, &1))
      |> Map.new(fn head ->
        {to_string(head), Enum.map(Map.get(grouped, head, [head]), &to_string/1)}
      end)

    memberships =
      for {unit, members} <- units,
          {note_id, member_index} <- Enum.with_index(members),
          into: %{} do
        {note_id,
         %{id: note_id, head_id: unit, member_index: member_index, continuation?: member_index > 0}}
      end

    {units, memberships}
  end

  for vector_case <- @vectors["cases"] do
    name = vector_case["name"]
    words = vector_case["words"]
    groups = vector_case["groups"]
    expect = vector_case["expect"]
    within = vector_case["within_fake_approximation"]

    if expect["note_phonemes"] do
      test "ref 契约：#{name}" do
        words = unquote(Macro.escape(words))
        groups = unquote(Macro.escape(groups))
        expected = unquote(Macro.escape(expect["note_phonemes"]))
        {units, memberships} = units_and_memberships(words, groups)

        fake =
          if unquote(within),
            do: FakePhonemes.note_phonemes(words, groups),
            else: nil

        for {unit, members} <- units,
            {note_id, member_index} <- Enum.with_index(members),
            {phoneme, index} <- Enum.with_index(expected[note_id]) do
          ref = Ref.segment(memberships[note_id], index)
          assert ref == %{unit: unit, member: member_index, index: index}

          # 真身期望一侧：任何用例都必须可解析。
          assert Ref.resolve(ref, units, expected) == {:ok, phoneme}

          # 替身一侧：近似成立的用例解析结果必须与真身逐字节一致。
          if fake do
            assert Ref.resolve(ref, units, fake) == {:ok, phoneme}
          end
        end
      end
    end
  end
end
