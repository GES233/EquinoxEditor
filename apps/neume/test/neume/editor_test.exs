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
  test "保存和加载保留当前工程，但重置会话历史", %{editor: editor, tmp_dir: tmp_dir} do
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
    assert {:error, :nothing_to_undo} = Editor.undo(loaded)
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

  test "引擎拒绝落在音符范围外的 pitch 控制点", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[500, 72]])

    assert {:error, error} = Editor.render(editor)
    assert inspect(error) =~ "outside_note_span"
  end

  test "内容修改触发 patch 冲突，撤销后恢复可渲染", %{editor: editor} do
    assert {:ok, editor} =
             Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
    assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lai"})

    assert {:error, {:resolve_vetoed, [%{kind: :conflict}]}} = Editor.render(editor)

    assert {:ok, editor} = Editor.undo(editor)
    assert {:ok, _editor, artifact} = Editor.render(editor)
    assert Enum.at(artifact.midi, 12) == 72.0
  end

  defp notes(editor) do
    {:ok, notes} = Editor.notes(editor)
    notes
  end
end
