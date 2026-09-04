defmodule Neume.EditorTest do
  use ExUnit.Case, async: true

  alias Neume.Editor

  setup do
    {:ok, editor} =
      Editor.new(
        project_id: "project-test",
        workspace_id: "workspace-test",
        ticks_per_frame: 10
      )

    {:ok, editor: editor}
  end

  test "编辑、撤销和重做只经过 Coconut 会话入口", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lai"})
    assert [{"n1", note, {0, 480}}] = notes(editor)
    assert note.lyric == "lai"

    assert {:ok, editor} = Editor.undo(editor)
    assert [{"n1", note, {0, 480}}] = notes(editor)
    assert note.lyric == "la"

    assert {:ok, editor} = Editor.redo(editor)
    assert [{"n1", note, {0, 480}}] = notes(editor)
    assert note.lyric == "lai"

    assert {:ok, editor} = Editor.drag_note(editor, "n1", :head, {240, 720})
    assert [{"n1", _note, {240, 720}}] = notes(editor)
  end

  @tag tmp_dir: true
  test "保存和加载保留当前工程与 undo/redo 历史", %{editor: editor, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "roundtrip.coconut")

    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
    assert {:ok, ^path} = Editor.save(editor, path)
    assert {:ok, loaded} = Editor.load(path, ticks_per_frame: 10)
    assert [{"n1", note, {0, 480}}] = notes(loaded)
    assert note.lyric == "la"
    assert {:ok, _loaded, artifact} = Editor.render(loaded)
    assert Enum.at(artifact.midi, 12) == 72.0

    # 历史随档恢复：undo 撤销 pin 挂载，redo 还原；跨档 traversal 可用。
    assert {:ok, undone} = Editor.undo(loaded)
    assert {:ok, _undone, artifact} = Editor.render(undone)
    assert Enum.at(artifact.midi, 12) == 60.0

    assert {:ok, redone} = Editor.redo(undone)
    assert {:ok, _redone, artifact} = Editor.render(redone)
    assert Enum.at(artifact.midi, 12) == 72.0
  end

  test "分数与 pitch patch 经 CoconutOi 和 Oi 产出 mock 帧制品", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, editor} =
             Editor.insert_note(editor, "n2", "n1", {480, 960}, %{pitch: 67, lyric: "mi"})

    assert {:ok, editor} = Editor.mount_pitch(editor, "n2", [[600, 72]])
    assert {:ok, _editor, artifact} = Editor.render(editor)

    assert artifact.format == :mock_frames
    assert artifact.frame_count == 96
    assert Enum.at(artifact.midi, 60) == 72.0
    assert Enum.at(artifact.lyrics, 60) == "mi"
    assert Enum.at(artifact.note_ids, 60) == "n2"
    assert Enum.count(artifact.midi, &(&1 == 60.0)) == 48
    assert Enum.count(artifact.midi, &(&1 == 67.0)) == 47
  end

  test "Bezier pitch intervention 经 mock 管线逐帧栅格化", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    curve = %Coconut.Curve.Adapter.Bezier{
      points: [
        %Coconut.Curve.ControlPoint{
          tick: 0,
          value: 60.0,
          handle_right: %{tick: 160, value: 6.0}
        },
        %Coconut.Curve.ControlPoint{
          tick: 479,
          value: 64.0,
          handle_left: %{tick: -160, value: 6.0}
        }
      ]
    }

    assert {:ok, editor} = Editor.mount_pitch_curve(editor, "n1", curve)
    assert {:ok, _editor, artifact} = Editor.render(editor)
    assert length(artifact.midi) == 48
    assert Enum.at(artifact.midi, 24) > 64.0
  end

  test "引擎拒绝落在音符范围外的 pitch 控制点", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[500, 72]])

    assert {:error, error} = Editor.render(editor)
    assert inspect(error) =~ "outside_note_span"
  end

  test "内容修改触发 probe 期身份冲突，撤销后恢复可渲染", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
    assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lai"})

    # mock G2P："la" → [l, a]，"lai" → [l, a, i]——词内音素序列变了，pin 炸。
    assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe}]}} =
             Editor.render(editor)

    assert {:ok, editor} = Editor.undo(editor)
    assert {:ok, _editor, artifact} = Editor.render(editor)
    assert Enum.at(artifact.midi, 12) == 72.0
  end

  test "analyze 不产出音频，返回确定性音素边界", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, _editor, analysis} = Editor.analyze(editor)
    assert analysis.total_frames == 48
    assert analysis.frame_rate == 48.0
    assert [%{id: "n1", phonemes: [["zh", "l"], ["zh", "a"]]}] = analysis.notes

    assert [
             %{symbol: "l", start_frame: 0, end_frame: 24, note_id: "n1", phoneme_index: 0},
             %{symbol: "a", start_frame: 24, end_frame: 48, note_id: "n1", phoneme_index: 1}
           ] = analysis.phonemes

    assert analysis.phoneme_durations == [24, 24]
  end

  test "check 通过时携带 analysis，模型错误聚合为 check_failed", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, _editor, %{analysis: analysis}} = Editor.check(editor)
    assert analysis.total_frames == 48

    assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: nil})

    assert {:error, {:check_failed, [%{kind: :model, reason: {:missing_lyric, "n1"}}]}} =
             Editor.check(editor)
  end

  test "check 把身份冲突聚合为 check_failed（probe 期）", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
    assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lai"})
    assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe}]}} = Editor.check(editor)
  end

  test "split_note 右子自动获得续音旗标，undo 一步还原", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, editor} = Editor.split_note(editor, "n1", 240, "n1b")
    assert [{"n1", head, {0, 240}}, {"n1b", member, {240, 480}}] = notes(editor)
    refute Map.has_key?(head.metadata, "melisma")
    assert member.metadata["melisma"] == "continue"

    # 续音派生头音符的末音素（"la" → l/a，延续 a）
    assert {:ok, _editor, analysis} = Editor.analyze(editor)
    assert analysis.total_frames == 48

    assert [
             %{symbol: "l", start_frame: 0, end_frame: 12, note_id: "n1"},
             %{symbol: "a", start_frame: 12, end_frame: 24, note_id: "n1"},
             %{symbol: "a", start_frame: 24, end_frame: 48, note_id: "n1b"}
           ] = analysis.phonemes

    assert {:ok, editor} = Editor.undo(editor)
    assert [{"n1", _note, {0, 480}}] = notes(editor)
  end

  test "拆出的续音拖出缝隙后断组，恢复按自身歌词发音", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, editor} = Editor.split_note(editor, "n1", 240, "n1b")
    assert {:ok, editor} = Editor.edit_note(editor, "n1b", %{lyric: "mi"})
    assert {:ok, editor} = Editor.drag_note(editor, "n1b", "n1", {480, 720})

    assert {:ok, _editor, analysis} = Editor.analyze(editor)

    assert [
             %{symbol: "l", note_id: "n1"},
             %{symbol: "a", note_id: "n1"},
             %{symbol: "m", note_id: "n1b"},
             %{symbol: "i", note_id: "n1b"}
           ] = analysis.phonemes
  end

  @tag tmp_dir: true
  test "全局旋钮挂载轨道 extras：undo/redo、随工程往返、无变化不落边", %{
    editor: editor,
    tmp_dir: tmp_dir
  } do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, editor} = Editor.update_globals(editor, %{energy: 1.5})
    assert Editor.globals(editor) == %{energy: 1.5}
    assert track_extras(editor) == %{neume: %{globals: %{energy: 1.5}}}

    # 重复同样值不落新历史边：一次 undo 即回到无旋钮状态。
    assert {:ok, editor} = Editor.update_globals(editor, %{energy: 1.5})
    assert {:ok, editor} = Editor.undo(editor)
    assert Editor.globals(editor) == %{}
    assert track_extras(editor) == %{}

    assert {:ok, editor} = Editor.redo(editor)
    assert Editor.globals(editor) == %{energy: 1.5}

    # 随工程保存/加载往返。
    path = Path.join(tmp_dir, "globals.coconut")
    assert {:ok, ^path} = Editor.save(editor, path)
    assert {:ok, loaded} = Editor.load(path, ticks_per_frame: 10)
    assert Editor.globals(loaded) == %{energy: 1.5}
    assert {:ok, _loaded, _artifact} = Editor.render(loaded)

    # nil 删空后 extras 恢复干净（不留空壳）。
    assert {:ok, editor} = Editor.update_globals(editor, %{energy: nil})
    assert Editor.globals(editor) == %{}
    assert track_extras(editor) == %{}
  end

  test "全局旋钮：会话合并、nil 删除、门禁聚合（mock 不消费旋钮值）", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, editor} = Editor.update_globals(editor, %{energy: 1.2, breathiness: 0.8})
    assert Editor.globals(editor) == %{energy: 1.2, breathiness: 0.8}
    assert {:ok, editor, _report} = Editor.check(editor)
    assert {:ok, editor, _artifact} = Editor.render(editor)

    assert {:ok, editor} = Editor.update_globals(editor, %{energy: nil})
    assert Editor.globals(editor) == %{breathiness: 0.8}

    assert {:ok, editor} = Editor.update_globals(editor, %{energy: 2.5})

    assert {:error, {:check_failed, [%{kind: :global, key: :energy, reason: reason}]}} =
             Editor.check(editor)

    assert reason == {:out_of_range, {0.0, 2.0}}

    assert {:ok, editor} = Editor.update_globals(editor, %{energy: 1.0, loudness: 1.0})

    assert {:error, {:check_failed, [%{kind: :global, key: :loudness, reason: :unknown_global}]}} =
             Editor.check(editor)
  end

  defp notes(editor) do
    {:ok, notes} = Editor.notes(editor)
    notes
  end

  defp track_extras(editor) do
    {:ok, track} =
      editor.session
      |> Coconut.workspace()
      |> Coconut.Edit.Workspace.fetch_track("vocal")

    track.extras
  end
end
