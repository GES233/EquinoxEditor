defmodule Neume.DiffSingerIntegrationTest do
  @moduledoc """
  本机真声库冒烟测试。默认排除；显式运行：

      mix test --include integration test/neume/diff_singer_integration_test.exs

  可用 `DS_VOICEBANK` / `DS_PYTHON` 覆盖机器相关路径。
  """

  use ExUnit.Case, async: false

  alias Neume.Editor

  @moduletag :integration
  @tag timeout: 600_000
  @voicebank "E:/ProgramAssets/OpenUTAUSingers/Asaritsu"
  @python "D:/CodeRepo/Qy/coconut/.venv/Scripts/python.exe"

  @tag tmp_dir: "asaritsu"
  test "Asaritsu 从音符渲染出 WAV", %{tmp_dir: tmp_dir} do
    voicebank = System.get_env("DS_VOICEBANK") || @voicebank
    python = System.get_env("DS_PYTHON") || @python

    assert File.dir?(voicebank), "声库目录不存在：#{voicebank}"
    assert File.regular?(python), "Python 不存在：#{python}"

    assert {:ok, editor} =
             Editor.new(
               voicebank_path: voicebank,
               python: [python],
               output_dir: tmp_dir,
               speaker: "Normal",
               steps: 2
             )

    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{
               pitch: 60,
               lyric: "啦",
               language: "zh"
             })

    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 62], [360, 58]])
    assert {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])
    assert {:ok, _editor, artifact} = Editor.render(editor)
    assert artifact.format == :wav
    assert artifact.sample_rate == 44_100
    assert artifact.frame_count > 0
    assert artifact.sample_count > 0
    assert artifact.phoneme_durations |> Enum.sum() == artifact.frame_count

    consonant = Enum.find(artifact.phonemes, &(&1.note_id == "n1" and &1.type != "vowel"))
    vowel = Enum.find(artifact.phonemes, &(&1.note_id == "n1" and &1.type == "vowel"))
    note_onset = round(artifact.lead_in_sec * artifact.sample_rate / 512)

    assert consonant.end_frame == vowel.start_frame
    assert consonant.end_frame - consonant.start_frame == round(0.1 * 44_100 / 512)
    assert consonant.start_frame < note_onset
    assert_in_delta vowel.start_frame, note_onset, 1
    assert File.regular?(artifact.path)
    assert {:ok, "RIFF" <> _rest} = File.read(artifact.path)
  end
end
