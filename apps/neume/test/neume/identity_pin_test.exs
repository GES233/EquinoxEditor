defmodule Neume.IdentityPinTest do
  @moduledoc """
  pin 身份底料（§6.6 第二档）的端到端语义：爆炸半径、probe 期裁决与
  re-patch 批量重挂。全部走 mock 管线（纯 Elixir 派生，确定性）。
  """

  use ExUnit.Case, async: true

  alias Neume.Editor

  setup do
    {:ok, editor} =
      Editor.new(
        project_id: "project-identity",
        workspace_id: "workspace-identity",
        ticks_per_frame: 10
      )

    {:ok, editor: editor}
  end

  defp insert_la(editor, id \\ "n1", after_id \\ :head, span \\ {0, 480}) do
    {:ok, editor} =
      Editor.insert_note(editor, id, after_id, span, %{pitch: 60, lyric: "la"})

    editor
  end

  test "改音高与拖动不炸 pin（身份底料不含音高与时值）", %{editor: editor} do
    editor = insert_la(editor)
    assert {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])
    assert {:ok, _editor, %{analysis: _}} = Editor.check(editor)

    # 改音高：content base 时代会炸，身份底料不炸。
    assert {:ok, editor} = Editor.edit_note(editor, "n1", %{pitch: 62})
    assert {:ok, editor, _report} = Editor.check(editor)

    # 拖动（Move + Retime 同批）：音素序列不受影响，pin 存活。
    assert {:ok, editor} = Editor.drag_note(editor, "n1", :head, {240, 720})
    assert {:ok, _editor, _report} = Editor.check(editor)
  end

  test "改邻居音符不炸 pin", %{editor: editor} do
    editor = insert_la(editor)

    assert {:ok, editor} =
             Editor.insert_note(editor, "n2", "n1", {480, 960}, %{pitch: 64, lyric: "mi"})

    assert {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])
    assert {:ok, editor} = Editor.edit_note(editor, "n2", %{lyric: "mu"})

    assert {:ok, _editor, _report} = Editor.check(editor)
  end

  test "改词炸 pin，repatch 重签后通过，undo 一次回到冲突态", %{editor: editor} do
    editor = insert_la(editor)
    assert {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])

    # "la" → [l, a]，"lu" → [l, u]：音素序列变了。
    assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lu"})

    assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe} = entry]}} =
             Editor.check(editor)

    assert entry.channel == :duration
    assert entry.reason == :base_changed

    # 重签：下标 0 在新序列 [l, u] 界内，payload 保留。
    assert {:ok, editor, [%{patch_id: old_id, status: :repatched}]} =
             Editor.repatch(editor, [entry])

    assert entry.patch.id == old_id
    assert {:ok, editor, _report} = Editor.check(editor)

    # 一条历史边：undo 一次整批还原（旧 pin 回来，仍处冲突态）。
    assert {:ok, editor} = Editor.undo(editor)

    assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe}]}} =
             Editor.check(editor)
  end

  test "repatch 下标越界时降级，旧 patch 保持冲突态", %{editor: editor} do
    editor = insert_la(editor)
    assert {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[1, 96]])

    # "o" → [o]：单音素，pin 的下标 1 越界。
    assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "o"})

    assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe} = entry]}} =
             Editor.check(editor)

    assert {:ok, editor, [%{status: :degraded, reason: {:phoneme_index_out_of_range, 1, 1}}]} =
             Editor.repatch(editor, [entry])

    # 降级不落历史边、不动旧 patch：仍然冲突，undo 无可撤销。
    assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe}]}} =
             Editor.check(editor)
  end

  test "repatch 拒绝不在册的 patch", %{editor: editor} do
    editor = insert_la(editor)
    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
    assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lai"})

    assert {:error, {:check_failed, [%{patch: patch} = entry]}} = Editor.check(editor)

    # 先丢弃（进墓地），再 repatch → loud error。
    assert {:ok, session} = Coconut.discard_conflicts(editor.session, [entry])
    editor = %{editor | session: session}
    assert {:error, {:patch_not_alive, id}} = Editor.repatch(editor, [entry])
    assert id == patch.id
  end

  test "melisma 晋升炸续音 pin，repatch 按自身歌词重签", %{editor: editor} do
    editor = insert_la(editor)
    assert {:ok, editor} = Editor.split_note(editor, "n1", 240, "n1b")

    # 续音 n1b 的身份 = 头的延续元音 [a]（mock 取头末音素）。
    assert {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1b", [[0, 96]])
    assert {:ok, editor, _report} = Editor.check(editor)

    # 给 n1b 自己的歌词，然后拖出缝隙 → 旗标失效，晋升为头。
    assert {:ok, editor} = Editor.edit_note(editor, "n1b", %{lyric: "mi"})
    assert {:ok, editor, _report} = Editor.check(editor)

    assert {:ok, editor} = Editor.drag_note(editor, "n1b", "n1", {720, 960})

    # 晋升后身份 = 自身 G2P [m, i]，与签名的 [a] 失配。
    assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe} = entry]}} =
             Editor.check(editor)

    # 重签后 pin 指向 [m, i] 的下标 0（在界内），check 通过。
    assert {:ok, editor, [%{status: :repatched}]} = Editor.repatch(editor, [entry])
    assert {:ok, _editor, %{analysis: analysis}} = Editor.check(editor)
    assert analysis.note_phonemes["n1b"] == [["zh", "m"], ["zh", "i"]]
  end

  test "pitch pin 与 duration pin 的身份冲突聚合在一次 check 里", %{editor: editor} do
    editor = insert_la(editor)
    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
    assert {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])
    assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lai"})

    assert {:error, {:check_failed, entries}} = Editor.check(editor)
    assert length(entries) == 2
    assert Enum.all?(entries, &(&1.kind == :conflict and &1.stage == :probe))
    assert Enum.sort(Enum.map(entries, & &1.channel)) == [:duration, :pitch]

    # 批量重挂：两个一起，一条历史边。
    assert {:ok, editor, results} = Editor.repatch(editor, entries)
    assert Enum.all?(results, &(&1.status == :repatched))
    assert {:ok, editor, _report} = Editor.check(editor)

    assert {:ok, editor} = Editor.undo(editor)
    assert {:error, {:check_failed, entries2}} = Editor.check(editor)
    assert length(entries2) == 2
  end
end
