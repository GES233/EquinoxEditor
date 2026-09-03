defmodule Neume.DiffSingerIntegrationTest do
  @moduledoc """
  本机真声库冒烟测试。默认排除；显式运行：

      mix test --include integration test/neume/diff_singer_integration_test.exs

  可用 `DS_VOICEBANK` / `DS_PYTHON` 覆盖机器相关路径。
  """

  use ExUnit.Case, async: false

  alias Neume.Editor

  @moduletag :integration
  @moduletag timeout: 600_000
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

  @tag tmp_dir: "asaritsu"
  test "analyze 不产出音频，边界与 render 一致", %{tmp_dir: tmp_dir} do
    assert {:ok, editor} = asaritsu_editor(tmp_dir, "analyze")

    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "啦"})

    assert {:ok, editor} =
             Editor.insert_note(editor, "n2", "n1", {480, 960}, %{pitch: 62, lyric: "米"})

    assert {:ok, editor, analysis} = Editor.analyze(editor)
    assert analysis.total_frames > 0
    assert [%{id: "n1", phonemes: [_ | _]}, %{id: "n2", phonemes: [_ | _]}] = analysis.notes
    assert Enum.any?(analysis.phonemes, &(&1.note_id == "n2"))

    assert {:ok, _editor, artifact} = Editor.render(editor)
    # 同一内容：analyze 边界与 render 制品边界一致（全轨 origin 均为 0）
    assert analysis.phonemes == artifact.phonemes
    assert analysis.phoneme_durations == artifact.phoneme_durations
  end

  @tag tmp_dir: "asaritsu"
  test "check 把模型错误聚合为 check_failed", %{tmp_dir: tmp_dir} do
    assert {:ok, editor} = asaritsu_editor(tmp_dir, "check")

    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{
               pitch: 60,
               lyric: "qzx9",
               language: "en"
             })

    assert {:error, {:check_failed, [%{kind: :model} | _]}} = Editor.check(editor)
  end

  @tag tmp_dir: "asaritsu"
  test "多窗曲目编辑后仅受影响窗重渲", %{tmp_dir: tmp_dir} do
    assert {:ok, editor} = asaritsu_editor(tmp_dir, "windows")

    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "啦"})

    assert {:ok, editor} =
             Editor.insert_note(editor, "n2", "n1", {4800, 5280}, %{pitch: 64, lyric: "米"})

    assert {:ok, editor, first} = Editor.render(editor)
    assert [%{note_ids: ["n1"], cache: :miss}, %{note_ids: ["n2"], cache: :miss}] = first.windows

    assert {:ok, editor} = Editor.edit_note(editor, "n2", %{lyric: "噻"})
    assert {:ok, _editor, second} = Editor.render(editor)
    assert [%{note_ids: ["n1"], cache: :hit}, %{note_ids: ["n2"], cache: :miss}] = second.windows

    # 未受影响窗的边界逐条一致；受影响窗 n2 元音 onset 仍对齐音符起点 ±1 帧
    boundary1 = Enum.filter(first.phonemes, &(&1.note_id == "n1"))
    boundary2 = Enum.filter(second.phonemes, &(&1.note_id == "n1"))
    assert boundary1 == boundary2

    vowel = Enum.find(second.phonemes, &(&1.note_id == "n2" and &1.type == "vowel"))
    onset = round((4800 / 960 + second.lead_in_sec) * 44_100 / 512)
    assert_in_delta vowel.start_frame, onset, 1

    assert File.regular?(second.path)
    assert {:ok, "RIFF" <> _rest} = File.read(second.path)
  end

  defp asaritsu_editor(tmp_dir, name) do
    voicebank = System.get_env("DS_VOICEBANK") || @voicebank
    python = System.get_env("DS_PYTHON") || @python

    unless File.dir?(voicebank), do: raise("声库目录不存在：#{voicebank}")
    unless File.regular?(python), do: raise("Python 不存在：#{python}")

    Editor.new(
      voicebank_path: voicebank,
      python: [python],
      output_dir: Path.join(tmp_dir, name),
      speaker: "Normal",
      steps: 2
    )
  end
end
