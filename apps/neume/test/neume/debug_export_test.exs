defmodule Neume.DebugExportTest do
  @moduledoc """
  调试导出（mock 管线，确定性帧网）：schema、span 裁剪、pin 锚点投影。
  """

  use ExUnit.Case, async: true

  alias Neume.Editor

  setup do
    {:ok, editor} =
      Editor.new(
        project_id: "project-export",
        workspace_id: "workspace-export",
        ticks_per_frame: 10
      )

    {:ok, editor: editor}
  end

  defp two_notes(editor) do
    {:ok, editor} =
      Editor.insert_note(editor, "n1", :head, {0, 480}, %{pitch: 60, lyric: "la"})

    {:ok, editor} =
      Editor.insert_note(editor, "n2", :head, {480, 960}, %{pitch: 62, lyric: "li"})

    editor
  end

  defp export(editor, path, opts \\ []) do
    assert {:ok, _editor, ^path} = Editor.export_debug(editor, path, opts)
    Jason.decode!(File.read!(path))
  end

  @tag tmp_dir: true
  test "导出 schema：meta/notes/frames/phonemes 在歌曲绝对帧轴上", %{
    editor: editor,
    tmp_dir: tmp_dir
  } do
    editor = two_notes(editor)
    data = export(editor, Path.join(tmp_dir, "d.debug.json"))

    assert data["meta"]["format"] == "neume-debug/1"
    assert [%{"tick" => 0, "bpm" => bpm}] = data["meta"]["tempos"]
    assert_in_delta bpm, 120.0, 0.001
    assert data["meta"]["tpqn"] == 480
    assert data["meta"]["frame_rate"] == 96.0
    assert_in_delta data["meta"]["total_sec"], 1.0, 0.0001

    assert [
             %{"id" => "n1", "midi" => 60.0, "lyric" => "la", "rest" => false},
             %{"id" => "n2", "midi" => 62.0, "lyric" => "li"}
           ] = data["notes"]

    # 120bpm 下 480 ticks = 0.5s；mock 帧网 48 帧/拍 → 96fps、48 帧/音符
    assert length(data["frames"]["midi"]) == 96
    assert Enum.uniq(Enum.take(data["frames"]["midi"], 48)) == [60.0]
    assert Enum.uniq(Enum.take(data["frames"]["midi"], -48)) == [62.0]

    f0_head = hd(data["frames"]["f0_hz"])
    assert_in_delta f0_head, 261.63, 0.01

    # mock G2P 按字素拆分："la"→l,a / "li"→l,i；边界落在绝对帧轴
    assert [%{"label" => "l"}, %{"label" => "a"}, %{"label" => "l"}, %{"label" => "i"}] =
             data["phonemes"]

    assert data["meta"]["patches"] == []
    assert data["curves"] == []
    assert data["frames_raw"] == nil
  end

  @tag tmp_dir: true
  test "span 裁剪 notes/frames/phonemes，meta 记录区间", %{editor: editor, tmp_dir: tmp_dir} do
    editor = two_notes(editor)
    data = export(editor, Path.join(tmp_dir, "d.debug.json"), span: {480, 960})

    assert [%{"id" => "n2"}] = data["notes"]
    assert data["meta"]["span"]["start_tick"] == 480
    assert data["meta"]["span"]["end_tick"] == 960
    assert_in_delta data["meta"]["span"]["start_sec"], 0.5, 0.0001

    assert data["meta"]["frames_origin_frame"] == 48
    assert length(data["frames"]["midi"]) == 48
    assert Enum.uniq(data["frames"]["midi"]) == [62.0]
    assert [%{"label" => "l"}, %{"label" => "i"}] = data["phonemes"]
  end

  @tag tmp_dir: true
  test "pin 锚点投影进 meta.patches，pitch pin 控制点进 curves", %{
    editor: editor,
    tmp_dir: tmp_dir
  } do
    editor = two_notes(editor)

    assert {:ok, editor} =
             Editor.mount_pitch(editor, "n1", [[0, 60.0], [240, 61.0], [479, 59.5]])

    data = export(editor, Path.join(tmp_dir, "d.debug.json"))

    assert [
             %{
               "channel" => "pitch",
               "anchor" => %{"kind" => "ordinal", "refs" => ["n1"], "adjacent" => false},
               "span_ticks" => [0, 480],
               "payload" => [[0, 60.0], [240, 61.0], [479, 59.5]]
             }
           ] = data["meta"]["patches"]

    # 控制点按绝对 MIDI 原样投影，与真实消费链契约一致。
    assert [
             %{
               "kind" => "pitch_midi",
               "points" => [
                 %{"tick" => 0, "value" => 60.0},
                 %{"tick" => 240, "value" => 61.0},
                 %{"tick" => 479, "value" => 59.5}
               ]
             }
           ] = data["curves"]
  end

  @tag tmp_dir: true
  test "Bezier payload 保留 handle，curves 投影兼容控制点", %{
    editor: editor,
    tmp_dir: tmp_dir
  } do
    editor = two_notes(editor)

    curve = %Coconut.Curve.Adapter.Bezier{
      points: [
        %Coconut.Curve.ControlPoint{
          tick: 0,
          value: 60.0,
          handle_right: %{tick: 120, value: 1.0}
        },
        %Coconut.Curve.ControlPoint{
          tick: 479,
          value: 62.0,
          handle_left: %{tick: -120, value: -1.0}
        }
      ]
    }

    assert {:ok, editor} = Editor.mount_pitch_curve(editor, "n1", curve)
    data = export(editor, Path.join(tmp_dir, "bezier.debug.json"))

    assert [%{"payload" => payload}] = data["meta"]["patches"]
    assert payload["format"] == "pitch_curve_v1"

    assert get_in(payload, ["points", Access.at(0), "handle_right"]) == %{
             "tick" => 120,
             "value" => 1.0
           }

    assert [%{"points" => [%{"tick" => 0}, %{"tick" => 479}]}] = data["curves"]
  end

  @tag tmp_dir: true
  test "span 之外的 pin 不进 curves 和 meta.patches", %{editor: editor, tmp_dir: tmp_dir} do
    editor = two_notes(editor)

    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[0, 50]])

    data = export(editor, Path.join(tmp_dir, "d.debug.json"), span: {480, 960})

    assert data["meta"]["patches"] == []
    assert data["curves"] == []
  end

  @tag tmp_dir: true
  test "raw?: true 附带无干预对照", %{editor: editor, tmp_dir: tmp_dir} do
    editor = two_notes(editor)

    assert {:ok, editor} = Editor.mount_pitch(editor, "n1", [[0, 50]])

    data = export(editor, Path.join(tmp_dir, "d.debug.json"), raw?: true)

    # mock 的 analyze 不消费 pins，raw 与 effective 一致；关键是 schema 在场
    assert %{"midi" => _, "f0_hz" => _} = data["frames_raw"]
    assert [_ | _] = data["phonemes_raw"]
  end
end
