defmodule Neume.DiffSingerWindowedTest do
  @moduledoc """
  分窗增量渲染测试：用按词计帧的计数假 client 验证缓存命中/失效粒度，
  不依赖真声库。
  """

  use ExUnit.Case, async: false

  alias Neume.Editor
  alias Neume.VoicebankFixture

  defmodule CountingClient do
    @behaviour Neume.Engine.DiffSingerWorker

    @frame_rate 44_100 / 512

    @impl true
    def call(%{action: "encode", notes: notes}, config) do
      count(config, "encode")
      tokens = Map.new(notes, &{to_string(&1.id), [["zh", "a"]]})
      {:ok, %{"tokens" => tokens}}
    end

    def call(%{action: "expand", words: words} = payload, config) do
      count(config, "expand")

      {:ok,
       %{"note_phonemes" => Neume.FakePhonemes.note_phonemes(words, Map.get(payload, :groups))}}
    end

    def call(%{action: "check", words: words} = payload, config) do
      count(config, "check")

      {boundaries, _cursor, _ordinal} =
        Enum.reduce(words, {[], 0, -1}, fn [phonemes, seconds | _rest], {acc, cursor, ordinal} ->
          frames = round(seconds * @frame_rate)
          rest? = Enum.all?(phonemes, fn [_lang, phone] -> phone == "SP" end)
          ordinal = if rest?, do: ordinal, else: ordinal + 1

          boundary = %{
            "language" => "zh",
            "symbol" => if(rest?, do: "SP", else: "a"),
            "type" => if(rest?, do: "rest", else: "vowel"),
            "start_frame" => cursor,
            "end_frame" => cursor + frames,
            "note_index" => if(rest?, do: nil, else: ordinal),
            "phoneme_index" => 0
          }

          {[boundary | acc], cursor + frames, ordinal}
        end)

      durations =
        Enum.flat_map(words, fn [phonemes, seconds | _rest] ->
          List.duplicate(round(seconds * @frame_rate), max(length(phonemes), 1))
        end)

      frame_count = Enum.sum(durations)

      {:ok,
       %{
         "ph_dur" => durations,
         "pitch_pred_midi" => List.duplicate(60.0, frame_count),
         "total_frames" => frame_count,
         "lead_in_sec" => 0.5,
         "note_phonemes" => Neume.FakePhonemes.note_phonemes(words, Map.get(payload, :groups)),
         "phonemes" => Enum.reverse(boundaries)
       }}
    end

    def call(%{action: "render", out_path: path, ph_dur: ph_dur}, config) do
      count(config, "render")
      frames = Enum.sum(ph_dur)
      samples = frames * 512
      :ok = Neume.Wav.write(path, :binary.copy(<<0, 0>>, samples), 44_100)

      {:ok,
       %{
         "path" => path,
         "sample_rate" => 44_100,
         "frames" => frames,
         "samples" => samples,
         "duration_sec" => samples / 44_100
       }}
    end

    defp count(config, action) do
      case Map.get(config, :test_pid) do
        nil -> :ok
        pid -> send(pid, {:worker_call, action})
      end
    end
  end

  @tag tmp_dir: true
  test "分窗缓存：编辑只失效内容变化的窗口", %{tmp_dir: tmp_dir} do
    voicebank = VoicebankFixture.diffsinger(tmp_dir)

    assert {:ok, editor} =
             Editor.new(
               voicebank_path: voicebank,
               voicebank_mode: :stock,
               diffsinger_client: CountingClient,
               diffsinger_client_config: %{test_pid: self()},
               output_dir: Path.join(tmp_dir, "renders")
             )

    # 窗 A：n1+n2（gap 0）；空档 3840 tick = 8 拍 >= 3 拍 → 切开
    # 窗 B：n3
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "啊"})

    assert {:ok, editor} =
             Editor.insert_note(editor, "n2", "n1", {480, 960}, %{pitch: 62, lyric: "吧"})

    assert {:ok, editor} =
             Editor.insert_note(editor, "n3", "n2", {4800, 5280}, %{pitch: 64, lyric: "灿"})

    assert {:ok, editor, artifact} = Editor.render(editor)

    assert [
             %{note_ids: ["n1", "n2"], cache: :miss, start_tick: 0, end_tick: 1440},
             %{note_ids: ["n3"], cache: :miss, start_tick: 3840, end_tick: 5280}
           ] = artifact.windows

    calls = drain_worker_calls()
    assert Enum.count(calls, &(&1 == "render")) == 2
    assert Enum.count(calls, &(&1 == "check")) == 2

    # n3 起点 5.0s（4800 tick / 960），全局帧约定 = (5.0 + lead_in 0.5) * 帧率
    vowel3 = Enum.find(artifact.phonemes, &(&1.note_id == "n3"))
    assert_in_delta vowel3.start_frame, 5.5 * 44_100 / 512, 1

    # 无编辑再渲染：全部命中，无 worker 调用
    assert {:ok, editor, artifact2} = Editor.render(editor)
    assert Enum.all?(artifact2.windows, &(&1.cache == :hit))
    assert drain_calls("render") == []
    assert artifact2.phonemes == artifact.phonemes

    # 编辑 n1（窗 A）：仅窗 A 失效
    assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "呣"})
    assert {:ok, editor, artifact3} = Editor.render(editor)
    assert [%{cache: :miss}, %{cache: :hit}] = artifact3.windows
    assert Enum.count(drain_calls("render")) == 1

    # 给 n3（窗 B）挂 pitch pin：仅窗 B 失效
    assert {:ok, editor} = Editor.mount_pitch(editor, "n3", [[4900, 66]])
    assert {:ok, _editor, artifact4} = Editor.render(editor)
    assert [%{cache: :hit}, %{cache: :miss}] = artifact4.windows
    assert Enum.count(drain_calls("render")) == 1
  end

  @tag tmp_dir: true
  test "analyze 走 Analysis-only 图，不触发 render 也不写音频", %{tmp_dir: tmp_dir} do
    voicebank = VoicebankFixture.diffsinger(tmp_dir)

    assert {:ok, editor} =
             Editor.new(
               voicebank_path: voicebank,
               voicebank_mode: :stock,
               diffsinger_client: CountingClient,
               diffsinger_client_config: %{test_pid: self()},
               output_dir: Path.join(tmp_dir, "renders")
             )

    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "啊"})

    assert {:ok, editor} =
             Editor.insert_note(editor, "n2", "n1", {4800, 5280}, %{pitch: 64, lyric: "米"})

    assert {:ok, _editor, analysis} = Editor.analyze(editor)
    assert analysis.frame_rate == 44_100 / 512
    assert analysis.total_frames > 0
    assert Enum.map(analysis.notes, & &1.id) == ["n1", "n2"]

    assert [
             %{id: {"vocal", 0}, note_ids: ["n1"], start_tick: 0, end_tick: 960},
             %{id: {"vocal", 3840}, note_ids: ["n2"], start_tick: 3840, end_tick: 5280}
           ] = analysis.phrases

    assert Enum.any?(analysis.phonemes, &(&1.note_id == "n2" and &1.type == "vowel"))

    # 只跑了 encode + check，没有 render；不产出任何 WAV
    assert drain_calls("render") == []
    assert Path.wildcard(Path.join(tmp_dir, "renders/**/*.wav")) == []
  end

  @tag tmp_dir: true
  test "check 通过时返回 analysis 报告", %{tmp_dir: tmp_dir} do
    voicebank = VoicebankFixture.diffsinger(tmp_dir)

    assert {:ok, editor} =
             Editor.new(
               voicebank_path: voicebank,
               voicebank_mode: :stock,
               diffsinger_client: CountingClient,
               diffsinger_client_config: %{test_pid: self()},
               output_dir: Path.join(tmp_dir, "renders")
             )

    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "啊"})

    assert {:ok, _editor, %{analysis: analysis}} = Editor.check(editor)
    assert analysis.total_frames > 0
  end

  @tag tmp_dir: true
  test "check 会继续检查后续乐句并聚合带定位的模型错误", %{tmp_dir: tmp_dir} do
    defmodule SelectiveClient do
      @behaviour Neume.Engine.DiffSingerWorker
      def call(%{action: "encode", notes: [%{id: id}]}, _config),
        do: {:ok, %{"tokens" => %{id => [["zh", "a"]]}}}

      def call(%{action: "check", words: words} = payload, config) do
        send(config.test_pid, {:checked_phrase, length(words)})
        symbols = Enum.flat_map(words, &hd/1)

        if Enum.any?(symbols, fn [_language, symbol] -> symbol == "bad" end) do
          {:error, :rejected_phrase}
        else
          CountingClient.call(payload, config)
        end
      end

      def call(payload, config), do: CountingClient.call(payload, config)
    end

    voicebank = VoicebankFixture.diffsinger(tmp_dir)

    assert {:ok, editor} =
             Editor.new(
               voicebank_path: voicebank,
               voicebank_mode: :stock,
               diffsinger_client: SelectiveClient,
               diffsinger_client_config: %{test_pid: self()},
               output_dir: Path.join(tmp_dir, "renders")
             )

    assert {:ok, editor} =
             Editor.insert_note(editor, "bad", :head, {0, 480}, %{
               pitch: 60,
               lyric: "坏",
               phonemes: [["zh", "bad"]]
             })

    assert {:ok, editor} =
             Editor.insert_note(editor, "good", "bad", {4800, 5280}, %{
               pitch: 64,
               lyric: "好",
               phonemes: [["zh", "good"]]
             })

    assert {:error,
            {:check_failed,
             [
               %{
                 kind: :model,
                 track_id: "vocal",
                 phrase_id: {"vocal", 0},
                 span: {0, 960},
                 note_ids: ["bad"],
                 reason: reason
               }
             ]}} = Editor.check(editor)

    assert inspect(reason) =~ "rejected_phrase"
    assert length(drain_checked_phrases()) == 2
  end

  defp drain_checked_phrases do
    receive do
      {:checked_phrase, count} -> [count | drain_checked_phrases()]
    after
      0 -> []
    end
  end

  defp drain_worker_calls do
    receive do
      {:worker_call, action} -> [action | drain_worker_calls()]
    after
      0 -> []
    end
  end

  defp drain_calls(action) do
    receive do
      {:worker_call, ^action} -> [action | drain_calls(action)]
      {:worker_call, _other} -> drain_calls(action)
    after
      0 -> []
    end
  end
end
