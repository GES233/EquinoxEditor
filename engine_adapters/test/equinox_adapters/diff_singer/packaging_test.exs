defmodule EquinoxAdapters.DiffSinger.PackagingTest do
  use ExUnit.Case, async: true

  alias Coconut.Score.Key.TwelveET
  alias Coconut.Score.{Note, Tempo}
  alias EquinoxAdapters.DiffSinger.Packaging

  # 120bpm step tempo：tpqn 480 下 240 ticks = 0.25s
  @segments [
    %{
      start_pos: 0,
      end_pos: nil,
      start_sec: 0.0,
      strategy: %Tempo.Step{start_tick: 0, end_tick: nil, bpm: 120}
    }
  ]
  @tpqn 480

  defp note(id, key_midi, phonemes) do
    {:ok, key} = TwelveET.new(key_midi)

    {:ok, note} =
      Note.new(id: id, key: key, lyric: "la", metadata: %{"phonemes" => phonemes})

    note
  end

  test "两音符无间隙：tick→秒 + words 线上形状" do
    notes = [
      {"n1", note("n1", 60, [["zh", "l"], ["zh", "iang"]]), {0, 240}},
      {"n2", note("n2", 62, [["zh", "zh"], ["zh", "i"]]), {240, 720}}
    ]

    assert {:ok,
            [
              [[["zh", "l"], ["zh", "iang"]], 0.25, 60.0],
              [[["zh", "zh"], ["zh", "i"]], 0.5, 62.0]
            ]} = Packaging.build_words(notes, @segments, @tpqn)
  end

  test "间隙插 SP 休止词（语言沿用前一音符，midi 0）" do
    notes = [
      {"n1", note("n1", 60, [["zh", "l"]]), {0, 240}},
      {"n2", note("n2", 62, [["zh", "h"], ["zh", "u"]]), {480, 720}}
    ]

    assert {:ok,
            [
              [[["zh", "l"]], 0.25, 60.0],
              [[["zh", "SP"]], 0.25, 0],
              [[["zh", "h"], ["zh", "u"]], 0.25, 62.0]
            ]} = Packaging.build_words(notes, @segments, @tpqn)
  end

  test "乱序输入按 start_tick 排序" do
    notes = [
      {"n2", note("n2", 62, [["zh", "i"]]), {240, 480}},
      {"n1", note("n1", 60, [["zh", "l"]]), {0, 240}}
    ]

    assert {:ok, [[_, _, 60.0], [_, _, 62.0]]} =
             Packaging.build_words(notes, @segments, @tpqn)
  end

  test "缺音素 / 非法音素形状响亮报错" do
    {:ok, key} = TwelveET.new(60)
    {:ok, no_phonemes} = Note.new(id: "n1", key: key, lyric: "la")

    assert {:error, {:missing_phonemes, "n1"}} =
             Packaging.build_words([{"n1", no_phonemes, {0, 240}}], @segments, @tpqn)

    bad = note("n2", 60, ["not-a-pair"])

    assert {:error, {:invalid_phonemes, "n2"}} =
             Packaging.build_words([{"n2", bad, {0, 240}}], @segments, @tpqn)
  end

  test "空 tempo 切片报错" do
    assert {:error, :empty_tempo_segments} = Packaging.build_words([], [], @tpqn)
  end

  test "target/1：arity-2 闭包扇出到 {:port, :infer, :words}" do
    target = Packaging.target(%{frame_rate: 44100 / 512, hop: 512})

    request = %EquinoxDomain.Command.RenderRequest{
      track_id: "track_a",
      notes: [{"n1", note("n1", 60, [["zh", "l"]]), {0, 240}}],
      time_range: {0, 240},
      tempo_segments: @segments,
      tpqn: @tpqn
    }

    assert [
             {{:port, :infer, :words},
              %{
                words: [[[["zh", "l"]], 0.25, 60.0]],
                sample_rate: 44_100,
                hop_size: 512,
                track_id: "track_a",
                window_start: 0
              }}
           ] = target.(%{deltas: []}, request)
  end
end
