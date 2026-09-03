defmodule Neume.DiffSingerEditorTest do
  use ExUnit.Case, async: false

  alias Neume.Editor
  alias Neume.VoicebankFixture

  defmodule FakeClient do
    @behaviour Neume.Engine.DiffSingerWorker

    @impl true
    def call(%{action: "encode", notes: notes}, _config) do
      tokens = Map.new(notes, &{to_string(&1.id), [["zh", "a"]]})
      {:ok, %{"tokens" => tokens}}
    end

    def call(%{action: "check", words: words}, _config) do
      durations =
        Enum.map(words, fn [_phonemes, seconds, _midi] ->
          round(seconds * 44_100 / 512)
        end)

      frame_count = Enum.sum(durations)

      {:ok,
       %{
         "ph_dur" => durations,
         "pitch_pred_midi" => List.duplicate(60.0, frame_count),
         "total_frames" => frame_count,
         "lead_in_sec" => 0.5,
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

    def call(%{action: "render", out_path: path, ph_dur: ph_dur}, _config) do
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
  end

  defmodule RecordingClient do
    @behaviour Neume.Engine.DiffSingerWorker

    @impl true
    def call(%{action: "check"} = payload, config) do
      send(Map.fetch!(config, :test_pid), {:check_payload, payload})

      {:ok,
       %{
         "ph_dur" => List.duplicate(1, length(payload.words)),
         "pitch_pred_midi" => [60.0],
         "total_frames" => 1
       }}
    end

    def call(%{action: "render", out_path: path, ph_dur: ph_dur}, _config) do
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
  end

  @tag tmp_dir: true
  test "外部声库经 CoconutOi 和 Oi 产出 WAV 制品", %{tmp_dir: tmp_dir} do
    voicebank = VoicebankFixture.diffsinger(tmp_dir)
    output_dir = Path.join(tmp_dir, "renders")

    assert {:ok, editor} =
             Editor.new(
               project_id: "project-diffsinger",
               workspace_id: "workspace-diffsinger",
               voicebank_path: voicebank,
               output_dir: output_dir,
               diffsinger_client: FakeClient
             )

    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "啊"})

    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 61]])
    assert {:ok, editor, artifact} = Editor.render(editor)
    assert artifact.format == :wav
    assert artifact.sample_rate == 44_100
    assert artifact.lead_in_sec == 0.5
    assert [rest, vowel] = artifact.phonemes
    assert rest.note_id == nil
    assert vowel.note_id == "n1"
    assert vowel.symbol == "a"
    assert File.regular?(artifact.path)

    assert {:ok, project} = Coconut.project(editor.session)
    assert project.voicebank.name == "Test Singer"
    assert project.voicebank.engine == :diffsinger
    assert byte_size(project.voicebank.digest) == 64
  end

  @tag tmp_dir: true
  test "打开工程时拒绝摘要不同的同名声库", %{tmp_dir: tmp_dir} do
    voicebank = VoicebankFixture.diffsinger(tmp_dir)

    assert {:ok, editor} =
             Editor.new(
               voicebank_path: voicebank,
               diffsinger_client: FakeClient,
               output_dir: Path.join(tmp_dir, "renders")
             )

    assert {:ok, project} = Coconut.project(editor.session)
    File.write!(Path.join(voicebank, "acoustic.onnx"), "changed")

    assert {:error, {:voicebank_mismatch, expected, actual}} =
             Editor.open(project,
               voicebank_path: voicebank,
               diffsinger_client: FakeClient,
               output_dir: Path.join(tmp_dir, "renders")
             )

    assert expected.name == actual.name
    refute expected.digest == actual.digest
  end

  @tag tmp_dir: true
  test "首音符前空白和 pitch 点共享同一绝对秒域", %{tmp_dir: tmp_dir} do
    voicebank = VoicebankFixture.diffsinger(tmp_dir)

    assert {:ok, editor} =
             Editor.new(
               voicebank_path: voicebank,
               diffsinger_client: RecordingClient,
               diffsinger_client_config: %{test_pid: self()},
               output_dir: Path.join(tmp_dir, "renders")
             )

    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {480, 960}, %{
               pitch: 60,
               lyric: "a",
               language: "zh",
               phonemes: [["zh", "a"]]
             })

    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[600, 62]])
    assert {:ok, _editor, _artifact} = Editor.render(editor)
    assert_receive {:check_payload, payload}

    assert [head, gap, note] = payload.words
    assert head == [[["zh", "SP"]], 0.5, 0.0]
    assert gap == [[["zh", "SP"]], 0.5, 0.0]
    assert note == [[["zh", "a"]], 0.5, 60.0]

    assert [%{note_index: 2, points: [[seconds, 62.0]]}] = payload.overrides
    assert_in_delta seconds, 1.125, 1.0e-9
  end

  @tag tmp_dir: true
  test "音素时长 pin 经 History 的 undo/redo 进入 worker", %{tmp_dir: tmp_dir} do
    voicebank = VoicebankFixture.diffsinger(tmp_dir)

    assert {:ok, editor} =
             Editor.new(
               voicebank_path: voicebank,
               diffsinger_client: RecordingClient,
               diffsinger_client_config: %{test_pid: self()},
               output_dir: Path.join(tmp_dir, "renders"),
               cache: false
             )

    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{
               pitch: 60,
               lyric: "sa",
               language: "zh",
               phonemes: [["zh", "s"], ["zh", "a"]]
             })

    assert {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])
    assert {:ok, editor, _artifact} = Editor.render(editor)
    assert_receive {:check_payload, pinned}

    assert [%{kind: "duration", note_index: 1, durations: [[0, seconds]]}] =
             Enum.filter(pinned.overrides, &(&1.kind == "duration"))

    assert_in_delta seconds, 0.1, 1.0e-9

    assert {:ok, editor} = Editor.undo(editor)
    assert {:ok, editor, _artifact} = Editor.render(editor)
    assert_receive {:check_payload, undone}
    assert Enum.all?(undone.overrides, &(&1.kind != "duration"))

    assert {:ok, editor} = Editor.redo(editor)
    assert {:ok, _editor, _artifact} = Editor.render(editor)
    assert_receive {:check_payload, redone}
    assert Enum.any?(redone.overrides, &(&1.kind == "duration"))
  end
end
