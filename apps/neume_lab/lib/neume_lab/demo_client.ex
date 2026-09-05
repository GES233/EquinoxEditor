defmodule NeumeLab.DemoClient do
  @moduledoc """
  演示用 DiffSinger client：encode/expand/check 的确定性纯 Elixir 实现。

  与 `apps/neumu/test/support/project_stub.ex` 的 `PhonemesClient` 同约定：
  组展开用"头词末音素当延续元音"近似（末音素非已知元音时抛
  `ArgumentError`），check 返回假预测。不实现 render：notebook 试听走
  `NeumeLab.SineRenderer`。
  """
  @behaviour Neume.Engine.DiffSingerWorker

  @impl true
  def call(%{action: "encode", notes: notes}, _config) do
    tokens =
      Map.new(notes, fn note ->
        phonemes = Enum.map(String.graphemes(note.lyric), &[note.language, &1])
        {to_string(note.id), phonemes}
      end)

    {:ok, %{"tokens" => tokens}}
  end

  def call(%{action: "expand", words: words} = payload, _config) do
    {:ok, %{"note_phonemes" => note_phonemes(words, Map.get(payload, :groups))}}
  end

  def call(%{action: "check", words: words} = payload, _config) do
    durations =
      Enum.map(words, fn [phonemes, seconds | _rest] ->
        length(phonemes) * round(seconds * 44_100 / 512)
      end)

    frame_count = Enum.sum(durations)

    {:ok,
     %{
       "ph_dur" => durations,
       "pitch_pred_midi" => List.duplicate(60.0, frame_count),
       "total_frames" => frame_count,
       "lead_in_sec" => 0.5,
       "note_phonemes" => note_phonemes(words, Map.get(payload, :groups)),
       "phonemes" => [
         %{
           "language" => "zh",
           "symbol" => "SP",
           "type" => "rest",
           "start_frame" => 0,
           "end_frame" => 43,
           "note_index" => nil,
           "phoneme_index" => 0
         },
         %{
           "language" => "zh",
           "symbol" => "a",
           "type" => "vowel",
           "start_frame" => 43,
           "end_frame" => frame_count,
           "note_index" => 0,
           "phoneme_index" => 0
         }
       ]
     }}
  end

  def call(_payload, _config), do: {:error, :not_used}

  # 拼音韵母近似表：只用于判断替身近似是否成立（与黄金向量
  # apps/neume/test/fixtures/expand_vectors.json 的约定一致）。
  @approx_vowels ~w(a o e i u v ü ai ei ao ou an en ang eng ong er)

  defp note_phonemes(words, groups) do
    member_vowels =
      for [head | members] <- groups || [],
          member <- members,
          into: %{} do
        [phonemes | _rest] = Enum.at(words, head)
        {member, [last_vowel!(phonemes, head)]}
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

  defp last_vowel!(phonemes, head_index) do
    [language, phone] = List.last(phonemes)

    if phone in @approx_vowels do
      [language, phone]
    else
      raise ArgumentError,
            "demo expand 近似不成立：头词 #{head_index} 末音素 #{inspect(phone)} 不是已知元音"
    end
  end
end
