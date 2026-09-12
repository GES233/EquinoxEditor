defmodule Neume.ScorePitchV2Test do
  @moduledoc """
  `score_pitch_v2`（批次 B，`note_tick` transport）的 survival matrix 与
  lowering 契约。matrix 逐手势钉住：改词/换声库/拖动存活，trim/split
  界内存活、越界在消费边界 loud 报错且 repatch 降级，merge 锚重定签
  产生冲突（repatch = 显式接受新 origin），legacy payload 行为不变。
  """

  use ExUnit.Case, async: true

  alias Coconut.Edit.History
  alias Neume.Channels.PitchPin
  alias Neume.{Editor, Identity}
  alias Neume.Pin.{Context, Descriptor, Lower, Resolved, Schema}

  # 不实现 lower_pins/4 的 runtime：纯 legacy 批次走 checked_pins/1 兼容
  # 回退；批次中出现 v2 schema 时 Editor 直接 {:unsupported_pin_schema, _}，
  # 不把 v2 payload 塞进 legacy 路径猜解。
  defmodule LegacyOnlyPipeline do
    @moduledoc false
    alias Neume.Engine.MockPipeline

    defdelegate compile(opts), to: MockPipeline
    defdelegate voicebank_digest(state), to: MockPipeline
    defdelegate checked_pins(data), to: MockPipeline
    defdelegate engine_config(state, track_id), to: MockPipeline
    defdelegate analyze_phrases(state, snapshot, pins, globals, track_id), to: MockPipeline
    defdelegate analyze(state, snapshot, pins, globals, track_id), to: MockPipeline
    defdelegate phonemes(state, snapshot, track_id), to: MockPipeline
    defdelegate render(state, snapshot, pins, globals, track_id), to: MockPipeline
  end

  # 既不实现 lower_pins/4 也不实现 checked_pins/1 的 runtime：legacy 批次
  # 也无路可走，Editor 给 tagged error，不抛 UndefinedFunctionError。
  defmodule NoLoweringPipeline do
    @moduledoc false
    alias Neume.Engine.MockPipeline

    defdelegate compile(opts), to: MockPipeline
    defdelegate voicebank_digest(state), to: MockPipeline
    defdelegate engine_config(state, track_id), to: MockPipeline
    defdelegate analyze_phrases(state, snapshot, pins, globals, track_id), to: MockPipeline
    defdelegate analyze(state, snapshot, pins, globals, track_id), to: MockPipeline
    defdelegate phonemes(state, snapshot, track_id), to: MockPipeline
    defdelegate render(state, snapshot, pins, globals, track_id), to: MockPipeline
  end

  setup do
    {:ok, editor} =
      Editor.new(
        project_id: "project-pitch-v2",
        workspace_id: "workspace-pitch-v2",
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

  # 模拟旧档/兼容路径：显式签 pin_input_v1 底料的 legacy pitch 点列。
  defp mount_legacy_pitch(editor, note_id, points) do
    with {:ok, base} <- Editor.derive_base(editor, note_id),
         {:ok, session, _patch} <-
           Coconut.mount(editor.session, editor.track_id, note_id, :pitch, points, base: base) do
      {:ok, %{editor | session: session}}
    end
  end

  describe "describe/1 与 base/4（v2 分派）" do
    test "score_pitch_v2 envelope 是 Pin<S>，签 score_region_v1" do
      payload = Schema.score_pitch_v2_payload([[0, 60.0], [120, 61.0]])

      assert {:ok,
              %Descriptor{
                payload_schema: "score_pitch_v2",
                base_schema: "score_region_v1",
                carrier: :score
              }} = PitchPin.describe(payload)
    end

    test "coordinates 非 note_tick 的 envelope 返回 tagged error" do
      assert {:error, {:invalid_score_pitch_v2, _}} =
               PitchPin.describe(%{
                 schema: "score_pitch_v2",
                 coordinates: "project_tick",
                 values: []
               })
    end

    test "v2 底料只钉 track/note/坐标系：不含歌词、声库与绝对起点", %{editor: editor} do
      payload = Schema.score_pitch_v2_payload([[0, 60.0]])
      {:ok, descriptor} = PitchPin.describe(payload)
      anchor = %Tamale.Anchor.Ordinal{refs: ["n1"]}

      # 声库摘要不同（无声库 nil / 有摘要）底料不变——改词换声库不炸。
      context_no_vb = Context.new(current_track(editor), editor.track_id, nil)
      context_with_vb = Context.new(current_track(editor), editor.track_id, "digest-x")

      assert {:ok, base} = PitchPin.base(context_no_vb, anchor, descriptor, payload)

      assert base == %{
               schema: "score_region_v1",
               coordinates: "note_tick",
               track: "vocal",
               note: "n1"
             }

      assert {:ok, ^base} = PitchPin.base(context_with_vb, anchor, descriptor, payload)

      # 与 legacy 底料无交集：不含 lyric/phonemes/group/voicebank 分量。
      refute Map.has_key?(base, :lyric)
      refute Map.has_key?(base, :voicebank)
    end

    test "v2 底料对非存活音符与不支持 anchor 给 tagged error", %{editor: editor} do
      payload = Schema.score_pitch_v2_payload([[0, 60.0]])
      {:ok, descriptor} = PitchPin.describe(payload)
      context = Context.new(current_track(editor), editor.track_id, nil)

      assert {:error, {:unknown_note, "n9"}} =
               PitchPin.base(context, %Tamale.Anchor.Ordinal{refs: ["n9"]}, descriptor, payload)

      assert {:error, {:unsupported_anchor, %Tamale.Anchor.Metric{}}} =
               PitchPin.base(context, %Tamale.Anchor.Metric{}, descriptor, payload)
    end
  end

  describe "expressible?/4（v2 偏移界内校验）" do
    test "偏移在 span 界内则 :ok，越界/负值/坏形状给 tagged error", %{editor: editor} do
      {:ok, descriptor} = PitchPin.describe(Schema.score_pitch_v2_payload([[0, 60.0]]))
      anchor = %Tamale.Anchor.Ordinal{refs: ["n1"]}
      context = Context.new(current_track(editor), editor.track_id, nil)

      assert :ok =
               PitchPin.expressible?(context, anchor, descriptor, %{
                 schema: "score_pitch_v2",
                 coordinates: "note_tick",
                 values: [[0, 60.0], [479, 61.0]]
               })

      assert {:error, {:pitch_offset_out_of_range, "n1", 480, 480}} =
               PitchPin.expressible?(context, anchor, descriptor, %{
                 schema: "score_pitch_v2",
                 coordinates: "note_tick",
                 values: [[480, 60.0]]
               })

      assert {:error, {:pitch_offset_out_of_range, "n1", -10, 480}} =
               PitchPin.expressible?(context, anchor, descriptor, %{
                 schema: "score_pitch_v2",
                 coordinates: "note_tick",
                 values: [[-10, 60.0]]
               })

      assert {:error, {:invalid_score_pitch_v2_value, ["x", 60]}} =
               PitchPin.expressible?(context, anchor, descriptor, %{
                 schema: "score_pitch_v2",
                 coordinates: "note_tick",
                 values: [["x", 60]]
               })
    end
  end

  describe "mount 默认产 v2" do
    test "绝对 tick 入参换算为 note_tick 偏移", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])

      assert %{
               tamale_patch: %{
                 payload: %{
                   schema: "score_pitch_v2",
                   coordinates: "note_tick",
                   values: [[120, 72.0]]
                 }
               }
             } = alive_patch(editor, :pitch)
    end

    test "非 0 起点的音符按 span 起点换算", %{editor: editor} do
      assert {:ok, editor} =
               Editor.insert_note(editor, "n2", "n1", {480, 960}, %{pitch: 64, lyric: "mi"})

      assert {:ok, editor} = Editor.mount_pitch(editor, "n2", [[600, 72]])

      assert %{tamale_patch: %{payload: %{values: [[120, 72.0]]}}} = alive_patch(editor, :pitch)
    end

    test "未知音符挂载被拒绝", %{editor: editor} do
      assert {:error, {:unknown_note, "n9"}} = Editor.mount_pitch(editor, "n9", [[0, 72]])
    end
  end

  describe "survival matrix" do
    test "改词存活：v2 底料不含输入事实", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
      assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lu"})
      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    test "改音高与邻居编辑存活", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
      assert {:ok, editor} = Editor.edit_note(editor, "n1", %{pitch: 62})

      assert {:ok, editor} =
               Editor.insert_note(editor, "n2", "n1", {480, 960}, %{pitch: 64, lyric: "mi"})

      assert {:ok, editor} = Editor.edit_note(editor, "n2", %{lyric: "mu"})
      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    test "拖动存活且 pin 跟随：lowering 后落在新绝对位置", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
      assert {:ok, editor} = Editor.drag_note(editor, "n1", :head, {240, 720})
      assert {:ok, editor, _report} = Editor.check(editor)

      # 偏移 120 随音符平移到绝对 tick 360；mock 帧轴从首音符起点计，
      # (360 - 240) / 10 = frame 12。
      assert {:ok, _editor, artifact} = Editor.render(editor)
      assert Enum.at(artifact.midi, 12) == 72.0
      assert Enum.at(artifact.midi, 0) == 60.0
    end

    test "trim 界内存活", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[0, 62], [120, 63]])
      assert {:ok, editor} = Editor.trim_note(editor, "n1", {0, 240})
      assert {:ok, editor, _report} = Editor.check(editor)

      assert {:ok, _editor, artifact} = Editor.render(editor)
      assert Enum.at(artifact.midi, 0) == 62.0
      assert Enum.at(artifact.midi, 12) == 63.0
    end

    test "trim 越界：消费边界 loud 报错，repatch 降级、不落历史边", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[0, 62], [120, 63]])
      assert {:ok, editor} = Editor.trim_note(editor, "n1", {0, 100})

      # 偏移 120 越界：render 在消费边界 loud 报错（与 legacy 同一规则）。
      assert {:error, error} = Editor.render(editor)
      assert inspect(error) =~ "outside_note_span"

      # repatch：expressible?/4 判越界 → 降级，旧 patch 原样保留。
      patch = alive_patch(editor, :pitch)

      assert {:ok, editor,
              [%{status: :degraded, reason: {:pitch_offset_out_of_range, "n1", 120, 100}}]} =
               Editor.repatch(editor, [patch.id])

      assert alive_patch(editor, :pitch).id == patch.id
    end

    test "split：左子继承 id，界内点存活", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[0, 62], [120, 63]])
      assert {:ok, editor} = Editor.split_note(editor, "n1", 240, "n1b")
      assert {:ok, editor, _report} = Editor.check(editor)

      assert {:ok, _editor, artifact} = Editor.render(editor)
      assert Enum.at(artifact.midi, 0) == 62.0
      assert Enum.at(artifact.midi, 12) == 63.0
    end

    test "merge：被吸收音符的 pin 冲突（origin 变化），repatch 显式重签", %{editor: editor} do
      assert {:ok, editor} =
               Editor.insert_note(editor, "n2", "n1", {480, 960}, %{pitch: 64, lyric: "mi"})

      assert {:ok, editor} = Editor.mount_pitch(editor, "n2", [[600, 70]])
      assert {:ok, editor, report} = Editor.merge_notes(editor, ["n1", "n2"])
      assert [%{channel: :pitch, from_note_id: "n2", note_id: "n1"}] = report.moved_pins

      # 锚被 Tamale 重定签到 into（n1），v2 底料的 note 分量失配 → 冲突。
      assert {:error,
              {:check_failed, [%{kind: :conflict, stage: :probe, reason: :base_changed} = entry]}} =
               Editor.check(editor)

      # repatch = 显式接受新 origin（偏移改按 n1 起点解释）：重签存活。
      assert {:ok, editor, [%{status: :repatched}]} = Editor.repatch(editor, [entry])
      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    test "undo/redo 与保存/加载往返保持 v2 payload 与底料", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
      assert {:ok, editor} = Editor.undo(editor)
      assert [] == current_track(editor).patches
      assert {:ok, editor} = Editor.redo(editor)
      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    @tag tmp_dir: true
    test "保存/加载往返", %{editor: editor, tmp_dir: tmp_dir} do
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
      path = Path.join(tmp_dir, "v2.coconut")
      assert {:ok, ^path} = Editor.save(editor, path)
      assert {:ok, loaded} = Editor.load(path, ticks_per_frame: 10)
      assert {:ok, _loaded, artifact} = Editor.render(loaded)
      assert Enum.at(artifact.midi, 12) == 72.0
    end
  end

  describe "legacy payload 行为不变" do
    test "legacy 点列可读可渲染，改词仍炸、repatch 重签", %{editor: editor} do
      assert {:ok, editor} = mount_legacy_pitch(editor, "n1", [[120, 72]])

      assert {:ok, _editor, artifact} = Editor.render(editor)
      assert Enum.at(artifact.midi, 12) == 72.0

      assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lu"})

      assert {:error, {:check_failed, [%{kind: :conflict, stage: :probe} = entry]}} =
               Editor.check(editor)

      assert {:ok, editor, [%{status: :repatched}]} = Editor.repatch(editor, [entry])

      # 重签后 digest 是 pin_input_v1 输入事实底料（schema 不跨级升级）。
      assert {:ok, expected} = Identity.base_for(current_track(editor), "n1", nil)
      assert {:ok, digest} = Tamale.Digest.digest(expected)
      assert alive_patch(editor, :pitch).tamale_patch.base_digest == digest
    end
  end

  describe "lowering 契约" do
    test "v2 按 snapshot 平移为绝对 tick，legacy 透传", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
      assert {:ok, editor} = Editor.mount_phoneme_duration(editor, "n1", [[0, 96]])
      {:ok, request} = Coconut.request(editor.session)

      resolved = [
        %Resolved{
          channel: :pitch,
          descriptor: %Descriptor{
            payload_schema: "score_pitch_v2",
            base_schema: "score_region_v1",
            carrier: :score
          },
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"]},
          payload: Schema.score_pitch_v2_payload([[120, 72.0]])
        },
        %Resolved{
          channel: :duration,
          descriptor: %Descriptor{
            payload_schema: "phoneme_duration_v1",
            base_schema: "pin_input_v1",
            carrier: :correspondence
          },
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"]},
          payload: [[0, 96]]
        }
      ]

      assert {:ok, %{pitch: %{"n1" => [[120, 72.0]]}, duration: %{"n1" => [[0, 96]]}}} =
               Lower.lower(resolved, request.snapshot, editor.track_id)
    end

    test "未知 schema 与未知音符返回 tagged error", %{editor: editor} do
      {:ok, request} = Coconut.request(editor.session)

      unknown = %Resolved{
        channel: :pitch,
        descriptor: %Descriptor{
          payload_schema: "score_pitch_v9",
          base_schema: "score_region_v9",
          carrier: :score
        },
        anchor: %Tamale.Anchor.Ordinal{refs: ["n1"]},
        payload: %{}
      }

      assert {:error, {:unsupported_pin_schema, "score_pitch_v9"}} =
               Lower.lower([unknown], request.snapshot, editor.track_id)

      dangling = %Resolved{
        channel: :pitch,
        descriptor: %Descriptor{
          payload_schema: "score_pitch_v2",
          base_schema: "score_region_v1",
          carrier: :score
        },
        anchor: %Tamale.Anchor.Ordinal{refs: ["n9"]},
        payload: Schema.score_pitch_v2_payload([[0, 60.0]])
      }

      assert {:error, {:unknown_note, "n9"}} =
               Lower.lower([dangling], request.snapshot, editor.track_id)
    end

    test "runtime 未实现 lower_pins/4：legacy 批次回退兼容入口，v2 批次拒绝", %{
      editor: editor
    } do
      # 纯 legacy 批次：回退 checked_pins/1，照常 check/render。
      assert {:ok, legacy_editor} = mount_legacy_pitch(editor, "n1", [[120, 72]])
      legacy_editor = %{legacy_editor | pipeline: LegacyOnlyPipeline}
      assert {:ok, legacy_editor, _report} = Editor.check(legacy_editor)
      assert {:ok, _legacy_editor, artifact} = Editor.render(legacy_editor)
      assert Enum.at(artifact.midi, 12) == 72.0

      # v2 批次：不以 legacy 路径猜解，统一冲突界面给 tagged error。
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])
      v2_editor = %{editor | pipeline: LegacyOnlyPipeline}

      assert {:error,
              {:check_failed,
               [%{kind: :pin, reason: {:unsupported_pin_schema, "score_pitch_v2"}}]}} =
               Editor.check(v2_editor)
    end

    test "runtime 两个 lowering 入口都缺失时 legacy 批次也给 tagged error", %{editor: editor} do
      assert {:ok, editor} = mount_legacy_pitch(editor, "n1", [[120, 72]])
      editor = %{editor | pipeline: NoLoweringPipeline}

      assert {:error,
              {:check_failed,
               [%{kind: :pin, reason: {:missing_pin_lowering, NoLoweringPipeline}}]}} =
               Editor.check(editor)
    end

    test "同 note/channel 重复挂载：later-write-wins（与 Coconut assemble 一致）", %{
      editor: editor
    } do
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 61]])
      assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[120, 72]])

      assert {:ok, _editor, artifact} = Editor.render(editor)
      assert Enum.at(artifact.midi, 12) == 72.0
    end

    test "显式 :base 的 schema 与 payload 分派不一致时拒绝挂载", %{editor: editor} do
      # derive_base/2 返回 legacy pin_input_v1 底料；v2 点列 payload 必须签
      # score_region_v1——错配挂载会永久 :base_changed，挂载期即拒绝。
      assert {:ok, legacy_base} = Editor.derive_base(editor, "n1")

      assert {:error, {:pin_base_schema_mismatch, "score_region_v1", ^legacy_base}} =
               Editor.mount_pitch(editor, "n1", [[120, 72]], base: legacy_base)

      # legacy payload + 正确 schema 的显式底料仍可挂载（兼容入口不变）。
      assert {:ok, editor} = mount_legacy_pitch(editor, "n1", [[120, 72]])
      assert {:ok, _editor, _report} = Editor.check(editor)
    end
  end
end
