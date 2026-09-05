defmodule Neume.FakePhonemes do
  @moduledoc """
  测试假 client 共用的 `expand`/`check` 派生：逐原词（音符）音素序列。

  组展开用"头词末音素当延续元音"的近似（与 mock pipeline 的约定一致）；
  真 worker 的 `expand` 按声库音素类型表取头词第一个元音。近似只在
  "末音素即元音"时成立——末音素不是已知元音时**必须** loudly 报错
  （`ArgumentError`），不许静默选错；一致性由黄金向量
  `apps/neume/test/fixtures/expand_vectors.json` 钉住。
  """

  # 拼音韵母近似表：只用于判断替身近似是否成立，不冒充声库音素类型。
  @approx_vowels ~w(a o e i u v ü ai ei ao ou an en ang eng ong er)

  @doc "按原 words 下标（字符串 key）归并逐词音素序列。"
  @spec note_phonemes([[term()]], [[non_neg_integer()]] | nil, [String.t()]) ::
          %{String.t() => [[String.t()]]}
  def note_phonemes(words, groups, vowels \\ @approx_vowels) do
    member_vowels =
      for [head | members] <- groups || [],
          member <- members,
          into: %{} do
        [phonemes | _rest] = Enum.at(words, head)
        {member, [last_vowel!(phonemes, head, vowels)]}
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

  # 近似前置断言：末音素必须是已知元音，否则替身与真身必然分歧。
  defp last_vowel!(phonemes, head_index, vowels) do
    [language, phone] = List.last(phonemes)

    if phone in vowels do
      [language, phone]
    else
      raise ArgumentError,
            "fake expand 近似不成立：头词 #{head_index} 末音素 #{inspect(phone)} 不是已知元音" <>
              "（真 worker 按声库类型表取第一个元音）；请改用黄金向量允许的数据或显式音素"
    end
  end
end
