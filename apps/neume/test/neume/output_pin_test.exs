defmodule Neume.OutputPinTest do
  use ExUnit.Case, async: true
  alias Neume.{Editor, OutputEditor}

  defmodule FailingPitch do
    def output_duration(_, _) do
      {:ok,
       %{
         channel: :duration,
         values: [2],
         segments: [%{note_id: "n", language: "zh", symbol: "a", start_frame: 0, end_frame: 2}],
         entries: [],
         projections: %{},
         frame_rate: 100.0,
         origin_sec: 0.0,
         lead_in_sec: 0.0
       }}
    end

    def output_pitch(_, _), do: {:error, :pitch_model_unavailable}
  end

  test "pitch 模型失败仍保留可编辑的 duration 提取，不伪造下游底料" do
    assert {:ok, packet} = Neume.OutputPipeline.run(FailingPitch, nil, nil, %{}, %{}, "vocal")
    assert {:ok, %{values: [2]}} = packet.projections.duration["n"]
    assert packet.projections.pitch == %{}
    assert [%{kind: :model, reason: :pitch_model_unavailable}] = packet.entries
  end

  setup do
    {:ok, editor} = Editor.new()
    {:ok, editor} = Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})
    %{editor: editor}
  end

  @tag tmp_dir: true
  test "输出 pin 随历史存读，旧输入约束不会被隐式升级", %{editor: editor, tmp_dir: dir} do
    {:ok, output} = OutputEditor.extract(editor)

    {:ok, pinned} =
      OutputEditor.put(editor, "n1", :pitch, [[0, 65]], output.regions["n1"].pitch.digest)

    path = Path.join(dir, "output.coconut")
    assert {:ok, ^path} = Editor.save(pinned, path)
    assert {:ok, restored} = Editor.load(path)
    assert {:ok, _, _} = Editor.check(restored)
    assert {:ok, restored} = Editor.undo(restored)
    assert Coconut.workspace(restored.session) == Coconut.workspace(editor.session)
    {:ok, legacy} = Editor.mount_pitch(editor, "n1", [[0, 64]])

    assert {:error, _} =
             OutputEditor.put(legacy, "n1", :pitch, [[0, 65]], output.regions["n1"].pitch.digest)
  end

  test "跨乐句只比较各自输出，休止与渲染沿用同一帧轴", %{editor: editor} do
    {:ok, editor} =
      Editor.insert_note(editor, "n2", "n1", {2400, 2880}, %{pitch: 67, lyric: "mi"})

    {:ok, output} = OutputEditor.extract(editor)

    {:ok, pinned} =
      OutputEditor.put(editor, "n2", :pitch, [[0, 70]], output.regions["n2"].pitch.digest)

    {:ok, changed} = Editor.edit_note(pinned, "n1", %{pitch: 63, lyric: "abc"})
    assert {:ok, _, artifact} = Editor.render(changed)
    assert Enum.at(artifact.midi, 240) == 70.0
    {:ok, moved} = Editor.drag_note(changed, "n2", "n1", {2520, 3000})

    assert {:error, {:check_failed, [%{note_id: "n2", reason: :base_changed}]}} =
             Editor.check(moved)
  end

  test "上游冲突禁止下游沿用；音素预算变化时降级保留原件", %{editor: editor} do
    {:ok, output} = OutputEditor.extract(editor)

    {:ok, editor} =
      OutputEditor.put(editor, "n1", :duration, [20, 28], output.regions["n1"].duration.digest)

    {:ok, output} = OutputEditor.extract(editor)

    {:ok, editor} =
      OutputEditor.put(editor, "n1", :pitch, [[0, 65]], output.regions["n1"].pitch.digest)

    {:ok, changed} = Editor.edit_note(editor, "n1", %{lyric: "abc"})
    {:ok, output} = OutputEditor.extract(changed)
    assert output.regions["n1"].pitch.blocked
    duration = Enum.find(output.entries, &(&1.channel == :duration))
    pitch = Enum.find(output.entries, &(&1.channel == :pitch))
    assert {:error, :upstream_output_conflict} = OutputEditor.repatch(changed, pitch.patch_id)

    assert {:ok, ^changed, %{status: :degraded}} =
             OutputEditor.repatch(changed, duration.patch_id)
  end

  test "输出干预不签输入事实：同输出改词存活，改音高产生输出冲突", %{editor: editor} do
    {:ok, editor} = Editor.edit_note(editor, "n1", %{phonemes: [["zh", "l"], ["zh", "a"]]})
    {:ok, output} = OutputEditor.extract(editor)
    pitch = output.regions["n1"].pitch
    {:ok, pinned} = OutputEditor.put(editor, "n1", :pitch, [[0, 65], [10, 66]], pitch.digest)
    assert {:ok, _, artifact} = Editor.render(pinned)
    assert Enum.at(artifact.midi, 5) == 65.5
    {:ok, changed} = Editor.edit_note(pinned, "n1", %{lyric: "同音不同字"})
    assert {:ok, _, _} = Editor.check(changed)
    {:ok, changed} = Editor.edit_note(changed, "n1", %{pitch: 62})
    assert {:error, {:check_failed, entries}} = Editor.check(changed)
    assert Enum.any?(entries, &(&1.reason == :base_changed and &1.channel == :pitch))
  end

  test "duration 在 DAG 上先合并，下游 pitch 漂移且显式重挂后可再次冲突", %{editor: editor} do
    {:ok, output} = OutputEditor.extract(editor)

    {:ok, editor} =
      OutputEditor.put(
        editor,
        "n1",
        :pitch,
        [[0, 64], [10, 65]],
        output.regions["n1"].pitch.digest
      )

    {:ok, output} = OutputEditor.extract(editor)

    {:ok, editor} =
      OutputEditor.put(editor, "n1", :duration, [20, 28], output.regions["n1"].duration.digest)

    assert {:error, {:check_failed, [entry]}} = Editor.check(editor)
    assert entry.channel == :pitch
    assert {:ok, editor, %{status: :repatched}} = OutputEditor.repatch(editor, entry.patch_id)
    assert {:ok, _, _} = Editor.check(editor)
    {:ok, output} = OutputEditor.extract(editor)

    {:ok, editor} =
      OutputEditor.put(editor, "n1", :duration, [21, 27], output.regions["n1"].duration.digest)

    assert {:error, {:check_failed, [%{channel: :pitch}]}} = Editor.check(editor)
  end

  test "拒绝旧提取和非法预算，重复提取一致，修改可撤销", %{editor: editor} do
    assert {:ok, first} = OutputEditor.extract(editor)
    assert {:ok, ^first} = OutputEditor.extract(editor)

    assert {:error, :invalid_duration_budget} =
             OutputEditor.put(
               editor,
               "n1",
               :duration,
               [100, 100],
               first.regions["n1"].duration.digest
             )

    {:ok, changed} = Editor.edit_note(editor, "n1", %{pitch: 63})

    assert {:error, :output_context_changed} =
             OutputEditor.put(changed, "n1", :pitch, [[0, 60]], first.regions["n1"].pitch.digest)

    {:ok, pinned} =
      OutputEditor.put(editor, "n1", :duration, [20, 28], first.regions["n1"].duration.digest)

    {:ok, restored} = Editor.undo(pinned)
    assert {:ok, ^first} = OutputEditor.extract(restored)
  end
end
