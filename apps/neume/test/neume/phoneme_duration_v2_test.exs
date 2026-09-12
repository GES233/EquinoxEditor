defmodule Neume.PhonemeDurationV2Test do
  @moduledoc """
  `phoneme_duration_v2`（批次 D，stable segment ref）的 survival matrix 与
  lowering 契约。matrix 逐手势钉住：改音高/拖动/邻居编辑存活，改词/显式
  音素变化冲突（repatch 重签），split 引入续音成员冲突（重签），melisma
  晋升/断组冲突（repatch 经 `redirect/4` 机械重定 ref），index 越界降级，
  legacy payload 行为不变。
  """

  use ExUnit.Case, async: true

  alias Coconut.Edit.History
  alias Neume.Channels.DurationPin
  alias Neume.Editor
  alias Neume.Pin.{Resolved, Schema}

  setup do
    {:ok, editor} =
      Editor.new(
        project_id: "project-duration-v2",
        workspace_id: "workspace-duration-v2",
        ticks_per_frame: 10
      )

    {:ok, editor} =
      Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    {:ok, editor: editor}
  end

  defp current_track(editor) do
    History.current(editor.session.history).workspace.tracks[editor.track_id]
  end

  defp alive_patch(editor, channel) do
    editor |> current_track() |> Map.get(:patches) |> Enum.find(&(&1.channel == channel))
  end

  # v2 envelope：segment ref 指向锚定音符自身（unit = 组头，member = 组内
  # 序号，index = 成员内音素下标）。
  defp v2_payload(unit, member, index, ticks) do
    Schema.phoneme_duration_v2_payload([
      %{segment: %{unit: unit, member: member, index: index}, duration_tick: ticks}
    ])
  end

  describe "describe/1 与挂载" do
    test "v2 envelope 是 Pin<Co>，签 phoneme_correspondence_v1" do
      assert {:ok,
              %Neume.Pin.Descriptor{
                payload_schema: "phoneme_duration_v2",
                base_schema: "phoneme_correspondence_v1",
                carrier: :correspondence
              }} = DurationPin.describe(v2_payload("n1", 0, 1, 96))

      assert {:error, {:invalid_phoneme_duration_v2, _}} =
               DurationPin.describe(%{schema: "phoneme_duration_v2"})

      assert {:error, {:unknown_duration_payload_schema, _}} = DurationPin.describe(%{})
    end

    test "v2 挂载存活且 render 消费（lowering 降为成员内下标）", %{editor: editor} do
      assert {:ok, editor} =
               Editor.mount_phoneme_duration(editor, "n1", v2_payload("n1", 0, 1, 96))

      assert %{tamale_patch: %{payload: %{schema: "phoneme_duration_v2"}}} =
               alive_patch(editor, :duration)

      assert {:ok, _editor, _report} = Editor.check(editor)
      assert {:ok, _editor, _artifact} = Editor.render(editor)
    end

    test "未知音符挂载被拒绝", %{editor: editor} do
      assert {:error, {:unknown_note, "n9"}} =
               Editor.mount_phoneme_duration(editor, "n9", v2_payload("n9", 0, 0, 96))
    end
  end

  describe "E0a：list 入参换算为 v2 envelope" do
    test "单音符：成员内下标补 %{unit, member} 两分量", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[1, 96], [0, 48]])

      assert %{
               tamale_patch: %{
                 payload: %{
                   schema: "phoneme_duration_v2",
                   values: [
                     %{segment: %{unit: "n1", member: 0, index: 1}, duration_tick: 96},
                     %{segment: %{unit: "n1", member: 0, index: 0}, duration_tick: 48}
                   ]
                 }
               }
             } = alive_patch(editor, :duration)

      # v2 底料（phoneme_correspondence_v1）：改音高不炸。
      assert {:ok, editor} = Editor.edit_note(editor, "n1", %{pitch: 62})
      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    test "melisma 组成员：member 序号为组内序号", %{editor: editor} do
      assert {:ok, editor} = Editor.split_note(editor, "n1", 240, "n1b")

      # 续音 n1b 是组 n1 的第 1 个成员：list 下标换算为
      # %{unit: "n1", member: 1, index: _}。
      assert {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1b", [[0, 96]])

      assert %{
               tamale_patch: %{
                 payload: %{
                   schema: "phoneme_duration_v2",
                   values: [%{segment: %{unit: "n1", member: 1, index: 0}, duration_tick: 96}]
                 }
               }
             } = alive_patch(editor, :duration)

      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    test "显式 v2 envelope 透传不动", %{editor: editor} do
      payload = v2_payload("n1", 0, 1, 96)
      assert {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", payload)
      assert %{tamale_patch: %{payload: ^payload}} = alive_patch(editor, :duration)
    end

    test "list 元素形状非法：tagged error，不落历史边", %{editor: editor} do
      assert {:error, {:invalid_duration_payload, ["x", 96]}} =
               Editor.mount_phoneme_duration(editor, "n1", [["x", 96]])

      assert {:error, {:invalid_duration_payload, [-1, 96]}} =
               Editor.mount_phoneme_duration(editor, "n1", [[-1, 96]])

      assert {:error, {:invalid_duration_payload, [0, 0]}} =
               Editor.mount_phoneme_duration(editor, "n1", [[0, 0]])

      assert {:error, {:invalid_duration_payload, [0, 96, 5]}} =
               Editor.mount_phoneme_duration(editor, "n1", [[0, 96, 5]])

      assert [] == current_track(editor).patches
    end

    test "未知音符：tagged error", %{editor: editor} do
      assert {:error, {:unknown_note, "n9"}} =
               Editor.mount_phoneme_duration(editor, "n9", [[0, 96]])
    end
  end

  describe "survival matrix" do
    test "改音高、拖动与邻居编辑存活", %{editor: editor} do
      assert {:ok, editor} =
               Editor.mount_phoneme_duration(editor, "n1", v2_payload("n1", 0, 1, 96))

      assert {:ok, editor} = Editor.edit_note(editor, "n1", %{pitch: 62})
      assert {:ok, editor} = Editor.drag_note(editor, "n1", :head, {240, 720})

      assert {:ok, editor} =
               Editor.insert_note(editor, "n2", "n1", {720, 1200}, %{pitch: 64, lyric: "mi"})

      assert {:ok, editor} = Editor.edit_note(editor, "n2", %{lyric: "mu"})
      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    test "改词冲突，repatch 重签存活（无 ref 漂移，不触发 redirect）", %{editor: editor} do
      assert {:ok, editor} =
               Editor.mount_phoneme_duration(editor, "n1", v2_payload("n1", 0, 1, 96))

      assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lu"})

      assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe} = entry]}} =
               Editor.check(editor)

      assert {:ok, editor, [%{status: :repatched} = result]} = Editor.repatch(editor, [entry])
      refute Map.has_key?(result, :redirected)
      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    test "改词缩短音素序列：index 越界，repatch 降级且不落历史边", %{editor: editor} do
      assert {:ok, editor} =
               Editor.mount_phoneme_duration(editor, "n1", v2_payload("n1", 0, 1, 96))

      assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "l"})

      assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe} = entry]}} =
               Editor.check(editor)

      patch_id = alive_patch(editor, :duration).id

      assert {:ok, editor, [%{status: :degraded, reason: {:phoneme_index_out_of_range, 1, 1}}]} =
               Editor.repatch(editor, [entry])

      # 降级不动旧 patch，冲突仍在。
      assert alive_patch(editor, :duration).id == patch_id

      assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe}]}} =
               Editor.check(editor)
    end

    test "split 引入续音成员：unit 组成变化冲突，repatch 重签存活", %{editor: editor} do
      assert {:ok, editor} =
               Editor.mount_phoneme_duration(editor, "n1", v2_payload("n1", 0, 1, 96))

      assert {:ok, editor} = Editor.split_note(editor, "n1", 240, "n1b")

      assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe} = entry]}} =
               Editor.check(editor)

      assert {:ok, editor, [%{status: :repatched}]} = Editor.repatch(editor, [entry])
      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    test "melisma 断组晋升：repatch 机械重定 ref（redirect），重写后存活", %{editor: editor} do
      assert {:ok, editor} = Editor.split_note(editor, "n1", 240, "n1b")

      # n1b 是续音（unit = n1，member = 1），延续元音序列长度为 1。
      assert {:ok, editor} =
               Editor.mount_phoneme_duration(editor, "n1b", v2_payload("n1", 1, 0, 96))

      assert {:ok, _editor, _report} = Editor.check(editor)

      # 拖出缝隙：旗标失效，n1b 晋升为新组头（unit n1 → n1b，member 1 → 0）。
      assert {:ok, editor} = Editor.drag_note(editor, "n1b", "n1", {720, 960})

      # lowering 的 segment 失配（kind :pin）与底料冲突（kind :conflict）
      # 在同一界面聚合；repatch 以冲突 entry 为入口。
      assert {:error, {:check_failed, entries}} = Editor.check(editor)
      assert Enum.any?(entries, &(&1.kind == :pin))
      assert %{} = entry = Enum.find(entries, &(&1.kind == :conflict))

      assert {:ok, editor, [%{status: :repatched, redirected: true}]} =
               Editor.repatch(editor, [entry])

      # payload 的 ref 被机械重写为晋升后的 membership（index 不变）。
      assert %{
               tamale_patch: %{
                 payload: %{
                   values: [%{segment: %{unit: "n1b", member: 0, index: 0}, duration_tick: 96}]
                 }
               }
             } = alive_patch(editor, :duration)

      assert {:ok, _editor, _report} = Editor.check(editor)
      assert {:ok, _editor, _artifact} = Editor.render(editor)
    end

    test "删头晋升：repatch 重定 ref 后存活", %{editor: editor} do
      assert {:ok, editor} = Editor.split_note(editor, "n1", 240, "n1b")

      assert {:ok, editor} =
               Editor.mount_phoneme_duration(editor, "n1b", v2_payload("n1", 1, 0, 96))

      assert {:ok, editor} = Editor.delete_note(editor, "n1")

      assert {:error, {:check_failed, entries}} = Editor.check(editor)
      assert %{} = entry = Enum.find(entries, &(&1.kind == :conflict))

      assert {:ok, editor, [%{status: :repatched, redirected: true}]} =
               Editor.repatch(editor, [entry])

      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    test "undo/redo 与保存/加载往返保持 v2 payload 与底料", %{editor: editor} do
      assert {:ok, editor} =
               Editor.mount_phoneme_duration(editor, "n1", v2_payload("n1", 0, 1, 96))

      assert {:ok, editor} = Editor.undo(editor)
      assert [] == current_track(editor).patches
      assert {:ok, editor} = Editor.redo(editor)
      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    @tag tmp_dir: true
    test "保存/加载往返", %{editor: editor, tmp_dir: tmp_dir} do
      assert {:ok, editor} =
               Editor.mount_phoneme_duration(editor, "n1", v2_payload("n1", 0, 1, 96))

      path = Path.join(tmp_dir, "duration-v2.coconut")
      assert {:ok, ^path} = Editor.save(editor, path)
      assert {:ok, loaded} = Editor.load(path, ticks_per_frame: 10)
      assert {:ok, _loaded, _report} = Editor.check(loaded)
      assert {:ok, _loaded, _artifact} = Editor.render(loaded)
    end
  end

  describe "lowering 契约（mock 侧）" do
    test "segment ref 降为成员序列内下标", %{editor: editor} do
      {:ok, request} = Coconut.request(editor.session)

      resolved = [
        %Resolved{
          channel: :duration,
          descriptor: %Neume.Pin.Descriptor{
            payload_schema: "phoneme_duration_v2",
            base_schema: "phoneme_correspondence_v1",
            carrier: :correspondence
          },
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"]},
          payload:
            Schema.phoneme_duration_v2_payload([
              %{segment: %{unit: "n1", member: 0, index: 1}, duration_tick: 96}
            ])
        }
      ]

      assert {:ok, %{pitch: %{}, duration: %{"n1" => [[1, 96]]}}} =
               Neume.Engine.MockPipeline.lower_pins(nil, request.snapshot, resolved, "vocal")
    end

    test "ref 与锚定音符 membership 不一致：loud 报错不猜解", %{editor: editor} do
      {:ok, request} = Coconut.request(editor.session)

      resolved = [
        %Resolved{
          channel: :duration,
          descriptor: %Neume.Pin.Descriptor{
            payload_schema: "phoneme_duration_v2",
            base_schema: "phoneme_correspondence_v1",
            carrier: :correspondence
          },
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"]},
          payload:
            Schema.phoneme_duration_v2_payload([
              %{segment: %{unit: "n9", member: 0, index: 0}, duration_tick: 96}
            ])
        }
      ]

      assert {:error, {:segment_ref_mismatch, "n1", %{unit: "n9", member: 0, index: 0}}} =
               Neume.Engine.MockPipeline.lower_pins(nil, request.snapshot, resolved, "vocal")
    end
  end
end
