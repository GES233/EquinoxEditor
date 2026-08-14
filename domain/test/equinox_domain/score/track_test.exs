defmodule EquinoxDomain.Score.TrackTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.TestFactory

  alias EquinoxDomain.Score.Track
  alias EquinoxDomain.Windowing.Window

  test "notes/2 返回带 span 的视图；note/3 取单个" do
    {project, track_id} = project_with_track()

    project =
      insert_notes(project, track_id, [
        {"n1", 0, 480, %{pitch: 60, lyric: "あ"}},
        {"n2", 480, 960, %{pitch: 62, lyric: "い"}}
      ])

    assert {:ok, [{"n1", _, {0, 480}}, {"n2", _, {480, 960}}]} = Track.notes(project, track_id)

    assert {:ok, {"n2", %Coconut.Score.Note{lyric: "い"}, {480, 960}}} =
             Track.note(project, track_id, "n2")

    assert {:error, {:note_not_found, "n9"}} = Track.note(project, track_id, "n9")
    assert {:error, {:unknown_track, "Track_x"}} = Track.notes(project, "Track_x")
  end

  test "slice/3 代理 Windowing（含 slice_flag 修正）" do
    {project, track_id} = project_with_track()

    project =
      insert_notes(project, track_id, [
        # 3 拍空档（1440 tick）→ 默认切开
        {"n1", 0, 480, %{}},
        {"n2", 1920, 2400, %{}}
      ])

    assert {:ok,
            [
              %Window{start_tick: 0, end_tick: 960, note_ids: ["n1"]},
              %Window{start_tick: 960, end_tick: 2400, note_ids: ["n2"]}
            ]} =
             Track.slice(project, track_id)

    # extra_spans 透传：填平空档 → 一窗
    assert {:ok, [%Window{start_tick: 0, end_tick: 2400, note_ids: ["n1", "n2"]}]} =
             Track.slice(project, track_id, extra_spans: [{480, 1920}])
  end
end
