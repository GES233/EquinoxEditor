defmodule Neume.PitchCurveV2Test do
  @moduledoc """
  `pitch_curve_v2`（批次 E，Bezier envelope 的 `note_tick` 相对坐标化）的
  survival matrix 与 lowering 契约。matrix 逐手势钉住：改词/改音高/拖动
  存活，trim 界内存活、越界在消费边界 loud 报错且 repatch 降级，merge
  锚重定签产生冲突（repatch = 显式接受新 origin）；`replace_pin` 支持
  legacy → v2 显式升级、拒绝 v2 → legacy 降级。legacy `pitch_curve_v1`
  经 `mount_pitch/4` 兼容路径行为不变。
  """

  use ExUnit.Case, async: true

  alias Coconut.Curve.Adapter.Bezier
  alias Coconut.Curve.ControlPoint
  alias Coconut.Edit.History
  alias Neume.Channels.PitchPin
  alias Neume.Editor
  alias Neume.Pin.{Context, Descriptor, Lower, Resolved, Schema}

  setup do
    {:ok, editor} =
      Editor.new(
        project_id: "project-curve-v2",
        workspace_id: "workspace-curve-v2",
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

  defp bezier(tick_value_pairs) do
    %Bezier{
      points:
        Enum.map(tick_value_pairs, fn {tick, value} ->
          %ControlPoint{tick: tick, value: value * 1.0}
        end)
    }
  end

  # 带 handle 的曲线：value 在两端锚点之外冲高，便于断言栅格化跟随。
  defp handled_bezier do
    %Bezier{
      points: [
        %ControlPoint{tick: 0, value: 60.0, handle_right: %{tick: 160, value: 6.0}},
        %ControlPoint{tick: 479, value: 64.0, handle_left: %{tick: -160, value: 6.0}}
      ]
    }
  end

  defp legacy_curve_map(points) do
    %{
      format: :pitch_curve_v1,
      adapter: :bezier,
      coord: :absolute_tick,
      value: :absolute_midi,
      points:
        Enum.map(points, fn {tick, value} ->
          %{tick: tick, value: value * 1.0, handle_left: nil, handle_right: nil}
        end)
    }
  end

  describe "describe/1 与 base/4（v2 分派）" do
    test "pitch_curve_v2 envelope 是 Pin<S>，签 score_region_v1" do
      payload =
        Schema.pitch_curve_v2_payload([
          %{offset_tick: 0, value: 60.0, handle_left: nil, handle_right: nil}
        ])

      assert {:ok,
              %Descriptor{
                payload_schema: "pitch_curve_v2",
                base_schema: "score_region_v1",
                carrier: :score
              }} = PitchPin.describe(payload)
    end

    test "畸形 envelope 返回 tagged error" do
      assert {:error, {:invalid_pitch_curve_v2, _}} =
               PitchPin.describe(%{schema: "pitch_curve_v2", coordinates: "project_tick"})

      assert {:error, {:invalid_pitch_curve_v2, _}} =
               PitchPin.describe(%{
                 schema: "pitch_curve_v2",
                 coordinates: "note_tick",
                 adapter: "linear",
                 points: []
               })
    end

    test "v2 底料只钉 track/note/坐标系，与点列 v2 同构", %{editor: editor} do
      payload =
        Schema.pitch_curve_v2_payload([
          %{offset_tick: 0, value: 60.0, handle_left: nil, handle_right: nil}
        ])

      {:ok, descriptor} = PitchPin.describe(payload)
      anchor = %Tamale.Anchor.Ordinal{refs: ["n1"]}
      context = Context.new(current_track(editor), editor.track_id, nil)

      assert {:ok,
              %{
                schema: "score_region_v1",
                coordinates: "note_tick",
                track: "vocal",
                note: "n1"
              }} = PitchPin.base(context, anchor, descriptor, payload)
    end
  end

  describe "expressible?/4（anchor 偏移界内校验）" do
    test "anchor offset 在 span 界内则 :ok；handle 越出 span 不判", %{editor: editor} do
      {:ok, descriptor} =
        PitchPin.describe(
          Schema.pitch_curve_v2_payload([
            %{offset_tick: 0, value: 60.0, handle_left: nil, handle_right: nil}
          ])
        )

      anchor = %Tamale.Anchor.Ordinal{refs: ["n1"]}
      context = Context.new(current_track(editor), editor.track_id, nil)

      # handle 的 tick 偏移越出 span（0 + 600 > 480）不影响可表达性。
      assert :ok =
               PitchPin.expressible?(context, anchor, descriptor, %{
                 schema: "pitch_curve_v2",
                 coordinates: "note_tick",
                 adapter: "bezier",
                 points: [
                   %{
                     offset_tick: 0,
                     value: 60.0,
                     handle_left: nil,
                     handle_right: %{tick: 600, value: 2.0}
                   },
                   %{
                     offset_tick: 479,
                     value: 62.0,
                     handle_left: %{tick: -200, value: -2.0},
                     handle_right: nil
                   }
                 ]
               })
    end

    test "anchor offset 越界/负值/坏形状给 tagged error", %{editor: editor} do
      {:ok, descriptor} =
        PitchPin.describe(
          Schema.pitch_curve_v2_payload([
            %{offset_tick: 0, value: 60.0, handle_left: nil, handle_right: nil}
          ])
        )

      anchor = %Tamale.Anchor.Ordinal{refs: ["n1"]}
      context = Context.new(current_track(editor), editor.track_id, nil)

      assert {:error, {:pitch_offset_out_of_range, "n1", 480, 480}} =
               PitchPin.expressible?(context, anchor, descriptor, %{
                 schema: "pitch_curve_v2",
                 coordinates: "note_tick",
                 adapter: "bezier",
                 points: [
                   %{offset_tick: 480, value: 60.0, handle_left: nil, handle_right: nil}
                 ]
               })

      assert {:error, {:pitch_offset_out_of_range, "n1", -5, 480}} =
               PitchPin.expressible?(context, anchor, descriptor, %{
                 schema: "pitch_curve_v2",
                 coordinates: "note_tick",
                 adapter: "bezier",
                 points: [
                   %{offset_tick: -5, value: 60.0, handle_left: nil, handle_right: nil}
                 ]
               })

      assert {:error, {:invalid_pitch_curve_v2_point, %{"offset_tick" => 10}}} =
               PitchPin.expressible?(context, anchor, descriptor, %{
                 schema: "pitch_curve_v2",
                 coordinates: "note_tick",
                 adapter: "bezier",
                 points: [%{"offset_tick" => 10}]
               })

      assert {:error, {:invalid_pitch_curve_v2, %{schema: "pitch_curve_v2"}}} =
               PitchPin.expressible?(context, anchor, descriptor, %{schema: "pitch_curve_v2"})
    end
  end

  describe "mount 默认产 v2" do
    test "Bezier struct 按 span 起点换算为 offset_tick，handle 原样携带", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch_curve(editor, "n1", handled_bezier())

      assert %{
               tamale_patch: %{
                 payload: %{
                   schema: "pitch_curve_v2",
                   coordinates: "note_tick",
                   adapter: "bezier",
                   points: [
                     %{
                       offset_tick: 0,
                       value: 60.0,
                       handle_left: nil,
                       handle_right: %{tick: 160, value: 6.0}
                     },
                     %{
                       offset_tick: 479,
                       value: 64.0,
                       handle_left: %{tick: -160, value: 6.0},
                       handle_right: nil
                     }
                   ]
                 }
               }
             } = alive_patch(editor, :pitch)
    end

    test "非 0 起点音符上的绝对 tick plain map 按 span 起点换算", %{editor: editor} do
      assert {:ok, editor} =
               Editor.insert_note(editor, "n2", "n1", {480, 960}, %{pitch: 64, lyric: "mi"})

      assert {:ok, editor} =
               Editor.mount_pitch_curve(editor, "n2", legacy_curve_map([{600, 70}, {959, 66}]))

      assert %{
               tamale_patch: %{
                 payload: %{
                   schema: "pitch_curve_v2",
                   points: [
                     %{offset_tick: 120, value: 70.0},
                     %{offset_tick: 479, value: 66.0}
                   ]
                 }
               }
             } = alive_patch(editor, :pitch)
    end

    test "显式 v2 envelope 校验后透传", %{editor: editor} do
      envelope =
        Schema.pitch_curve_v2_payload([
          %{offset_tick: 240, value: 63.0, handle_left: nil, handle_right: nil},
          %{offset_tick: 0, value: 60.0, handle_left: nil, handle_right: nil}
        ])

      assert {:ok, editor} = Editor.mount_pitch_curve(editor, "n1", envelope)

      # normalize_v2 按 offset_tick 排序。
      assert %{
               tamale_patch: %{
                 payload: %{
                   schema: "pitch_curve_v2",
                   points: [%{offset_tick: 0}, %{offset_tick: 240}]
                 }
               }
             } = alive_patch(editor, :pitch)
    end

    test "未知音符与未知 schema envelope 被拒绝", %{editor: editor} do
      assert {:error, {:unknown_note, "n9"}} =
               Editor.mount_pitch_curve(editor, "n9", handled_bezier())

      assert {:error, {:unknown_pitch_payload_schema, _}} =
               Editor.mount_pitch_curve(editor, "n1", %{schema: "pitch_curve_v9", points: []})
    end

    test "mount_pitch/4 兼容路径的 legacy curve map 保持 legacy", %{editor: editor} do
      assert {:ok, editor} =
               Editor.mount_pitch(editor, "n1", legacy_curve_map([{0, 60}, {479, 62}]))

      assert %{tamale_patch: %{payload: %{format: :pitch_curve_v1}}} = alive_patch(editor, :pitch)
    end
  end

  describe "survival matrix" do
    test "改词/改音高存活：v2 底料不含输入事实", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch_curve(editor, "n1", handled_bezier())
      assert {:ok, editor} = Editor.edit_note(editor, "n1", %{lyric: "lu", pitch: 62})
      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    test "拖动存活且曲线跟随：栅格化轮廓不变", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch_curve(editor, "n1", handled_bezier())
      assert {:ok, _editor, before} = Editor.render(editor)

      assert {:ok, editor} = Editor.drag_note(editor, "n1", :head, {240, 720})
      assert {:ok, editor, _report} = Editor.check(editor)
      assert {:ok, _editor, after_drag} = Editor.render(editor)

      # mock 帧轴从首音符起点计：拖动后整段轮廓逐帧一致（曲线随音符平移）。
      assert after_drag.midi == before.midi
    end

    test "trim 界内存活", %{editor: editor} do
      curve = bezier([{0, 60}, {120, 63}])
      assert {:ok, editor} = Editor.mount_pitch_curve(editor, "n1", curve)
      assert {:ok, editor} = Editor.trim_note(editor, "n1", {0, 240})
      assert {:ok, editor, _report} = Editor.check(editor)
      assert {:ok, _editor, _artifact} = Editor.render(editor)
    end

    test "trim 越界：repatch 经 expressible? 降级、不落历史边", %{editor: editor} do
      curve = bezier([{0, 60}, {300, 63}])
      assert {:ok, editor} = Editor.mount_pitch_curve(editor, "n1", curve)
      assert {:ok, editor} = Editor.trim_note(editor, "n1", {0, 100})

      # mock 曲线消费边界不做 span 复核（Bezier 自然外推，与 legacy 曲线同一
      # 规则；真实 worker 路径在 `PitchCurve.to_worker_points/5` 复核）。越界
      # 裁决由 repatch 的 expressible?/4 承担：offset 300 越出 span 100 →
      # 降级，旧 patch 原样保留。
      patch = alive_patch(editor, :pitch)

      assert {:ok, editor,
              [%{status: :degraded, reason: {:pitch_offset_out_of_range, "n1", 300, 100}}]} =
               Editor.repatch(editor, [patch.id])

      assert alive_patch(editor, :pitch).id == patch.id
    end

    test "merge：被吸收音符的 pin 冲突（origin 变化），repatch 显式重签", %{editor: editor} do
      assert {:ok, editor} =
               Editor.insert_note(editor, "n2", "n1", {480, 960}, %{pitch: 64, lyric: "mi"})

      assert {:ok, editor} =
               Editor.mount_pitch_curve(editor, "n2", legacy_curve_map([{600, 70}, {959, 66}]))

      assert {:ok, editor, report} = Editor.merge_notes(editor, ["n1", "n2"])
      assert [%{channel: :pitch, from_note_id: "n2", note_id: "n1"}] = report.moved_pins

      assert {:error,
              {:check_failed, [%{kind: :conflict, stage: :probe, reason: :base_changed} = entry]}} =
               Editor.check(editor)

      assert {:ok, editor, [%{status: :repatched}]} = Editor.repatch(editor, [entry])
      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    test "undo/redo 往返保持 v2 payload", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch_curve(editor, "n1", handled_bezier())
      assert {:ok, editor} = Editor.undo(editor)
      assert [] == current_track(editor).patches
      assert {:ok, editor} = Editor.redo(editor)
      assert {:ok, _editor, _report} = Editor.check(editor)
    end

    @tag tmp_dir: true
    test "保存/加载往返", %{editor: editor, tmp_dir: tmp_dir} do
      assert {:ok, editor} = Editor.mount_pitch_curve(editor, "n1", handled_bezier())
      assert {:ok, _editor, before} = Editor.render(editor)

      path = Path.join(tmp_dir, "curve-v2.coconut")
      assert {:ok, ^path} = Editor.save(editor, path)
      assert {:ok, loaded} = Editor.load(path, ticks_per_frame: 10)
      assert {:ok, _loaded, artifact} = Editor.render(loaded)
      assert artifact.midi == before.midi
    end
  end

  describe "lowering 契约" do
    test "v2 平移为绝对 tick 的 legacy plain map，handle 原样携带", %{editor: editor} do
      {:ok, request} = Coconut.request(editor.session)

      resolved = [
        %Resolved{
          channel: :pitch,
          descriptor: %Descriptor{
            payload_schema: "pitch_curve_v2",
            base_schema: "score_region_v1",
            carrier: :score
          },
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"]},
          payload:
            Schema.pitch_curve_v2_payload([
              %{
                offset_tick: 120,
                value: 61.0,
                handle_left: nil,
                handle_right: %{tick: 60, value: 1.0}
              }
            ])
        }
      ]

      assert {:ok,
              %{
                pitch: %{
                  "n1" => %{
                    format: :pitch_curve_v1,
                    adapter: :bezier,
                    coord: :absolute_tick,
                    value: :absolute_midi,
                    points: [
                      %{
                        tick: 120,
                        value: 61.0,
                        handle_left: nil,
                        handle_right: %{tick: 60, value: 1.0}
                      }
                    ]
                  }
                },
                duration: %{}
              }} = Lower.lower(resolved, request.snapshot, editor.track_id)
    end

    test "畸形点与未知音符返回 tagged error", %{editor: editor} do
      {:ok, request} = Coconut.request(editor.session)

      malformed = %Resolved{
        channel: :pitch,
        descriptor: %Descriptor{
          payload_schema: "pitch_curve_v2",
          base_schema: "score_region_v1",
          carrier: :score
        },
        anchor: %Tamale.Anchor.Ordinal{refs: ["n1"]},
        payload: %{schema: "pitch_curve_v2", points: [%{offset_tick: "x", value: 60}]}
      }

      assert {:error, {:invalid_pitch_curve_v2_point, %{offset_tick: "x", value: 60}}} =
               Lower.lower([malformed], request.snapshot, editor.track_id)

      dangling = %Resolved{
        channel: :pitch,
        descriptor: %Descriptor{
          payload_schema: "pitch_curve_v2",
          base_schema: "score_region_v1",
          carrier: :score
        },
        anchor: %Tamale.Anchor.Ordinal{refs: ["n9"]},
        payload:
          Schema.pitch_curve_v2_payload([
            %{offset_tick: 0, value: 60.0, handle_left: nil, handle_right: nil}
          ])
      }

      assert {:error, {:unknown_note, "n9"}} =
               Lower.lower([dangling], request.snapshot, editor.track_id)
    end

    test "与 legacy 直接挂载的栅格化结果逐帧一致", %{editor: editor} do
      curve = handled_bezier()

      # v2 路径：mount_pitch_curve 默认产 v2，lowering 平移回绝对 tick。
      assert {:ok, v2_editor} = Editor.mount_pitch_curve(editor, "n1", curve)
      assert {:ok, _v2_editor, v2_artifact} = Editor.render(v2_editor)

      # legacy 路径：同一曲线经 mount_pitch 兼容路径保持 pitch_curve_v1。
      legacy_map = %{
        format: :pitch_curve_v1,
        adapter: :bezier,
        coord: :absolute_tick,
        value: :absolute_midi,
        points:
          Enum.map(curve.points, fn point ->
            %{
              tick: point.tick,
              value: point.value,
              handle_left: point.handle_left,
              handle_right: point.handle_right
            }
          end)
      }

      assert {:ok, legacy_editor} = Editor.mount_pitch(editor, "n1", legacy_map)
      assert {:ok, _legacy_editor, legacy_artifact} = Editor.render(legacy_editor)

      assert v2_artifact.midi == legacy_artifact.midi
    end
  end

  describe "replace_pin（显式升级手势）" do
    test "legacy → v2 升级：一条历史边，undo 一次还原旧 payload", %{editor: editor} do
      assert {:ok, editor} =
               Editor.mount_pitch(editor, "n1", legacy_curve_map([{0, 60}, {479, 62}]))

      patch = alive_patch(editor, :pitch)

      v2 =
        Schema.pitch_curve_v2_payload([
          %{offset_tick: 0, value: 60.0, handle_left: nil, handle_right: nil},
          %{offset_tick: 479, value: 63.0, handle_left: nil, handle_right: nil}
        ])

      assert {:ok, editor, %{payload_schema: "pitch_curve_v2", replaced_patch_id: replaced_id}} =
               Editor.replace_pin(editor, patch.id, v2)

      assert replaced_id == patch.id

      assert %{tamale_patch: %{payload: %{schema: "pitch_curve_v2"}}} =
               alive_patch(editor, :pitch)

      assert {:ok, editor} = Editor.undo(editor)
      assert %{tamale_patch: %{payload: %{format: :pitch_curve_v1}}} = alive_patch(editor, :pitch)
    end

    test "同 schema 替换更新内容", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch_curve(editor, "n1", handled_bezier())
      patch = alive_patch(editor, :pitch)

      v2 =
        Schema.pitch_curve_v2_payload([
          %{offset_tick: 0, value: 58.0, handle_left: nil, handle_right: nil},
          %{offset_tick: 479, value: 59.0, handle_left: nil, handle_right: nil}
        ])

      assert {:ok, editor, %{payload_schema: "pitch_curve_v2"}} =
               Editor.replace_pin(editor, patch.id, v2)

      assert %{tamale_patch: %{payload: %{points: [%{value: 58.0}, %{value: 59.0}]}}} =
               alive_patch(editor, :pitch)
    end

    test "v2 → legacy 降级被拒绝", %{editor: editor} do
      assert {:ok, editor} = Editor.mount_pitch_curve(editor, "n1", handled_bezier())
      patch = alive_patch(editor, :pitch)

      assert {:error, {:pin_schema_downgrade, "pitch_curve_v2", "pitch_curve_v1"}} =
               Editor.replace_pin(editor, patch.id, legacy_curve_map([{0, 60}, {479, 62}]))
    end
  end
end
