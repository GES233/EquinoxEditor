defmodule Neume.FakePhonemes do
  @moduledoc """
  测试假 client 共用的 `expand`/`check` 派生：逐原词（音符）音素序列。

  组展开用"头词末音素当延续元音"的近似（与 mock pipeline 的约定一致）；
  真 worker 的 `expand` 按声库音素类型取第一个元音，假 client 的测试数据
  都满足"末音素即元音"。
  """

  @doc "按原 words 下标（字符串 key）归并逐词音素序列。"
  @spec note_phonemes([[term()]], [[non_neg_integer()]] | nil) :: %{String.t() => [[String.t()]]}
  def note_phonemes(words, groups) do
    member_vowels =
      for [head | members] <- groups || [],
          member <- members,
          into: %{} do
        [phonemes | _rest] = Enum.at(words, head)
        {member, [List.last(phonemes)]}
      end

    words
    |> Enum.with_index()
    |> Map.new(fn {word, index} ->
      phonemes =
        case Map.fetch(member_vowels, index) do
          {:ok, vowel} -> vowel
          :error -> hd(word)
        end

      {to_string(index), phonemes}
    end)
  end
end
