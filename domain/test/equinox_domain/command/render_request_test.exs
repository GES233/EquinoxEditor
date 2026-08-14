defmodule EquinoxDomain.Command.RenderRequestTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.TestFactory

  alias Coconut.Edit.{Patch, Workspace}
  alias EquinoxDomain.Command.RenderRequest
  alias EquinoxDomain.Port.{Channels.PhonemeTiming, Preset}
  alias EquinoxDomain.Score.{Project, Track, TrackMeta}

  # n1 [0,480) n2 [480,960) 粘连；n2→n3 空档 3 拍（1440）切开：
  # 前 1 拍归前窗、后 2 拍归后窗 → [0,1440) 与 [1440,2880)
  @notes [
    {"n1", 0, 480, %{pitch: 60, lyric: "あ"}},
    {"n2", 480, 960, %{pitch: 62, lyric: "い"}},
    {"n3", 2400, 2880, %{pitch: 64, lyric: "う"}}
  ]

  defp setup_project do
    {project, track_id} = project_with_track()
    project = insert_notes(project, track_id, @notes)
    {project, track_id}
  end

  defp attach_patch!(project, track_id, channel, anchor) do
    {:ok, tamale_patch} = Tamale.Patch.new(%{"note" => "base"}, %{"delta" => 1})

    {:ok, patch} =
      Patch.new(%{
        track_id: track_id,
        anchor: anchor,
        patch: tamale_patch,
        channel: channel
      })

    {:ok, workspace, _minted} = Workspace.attach_patch(project.workspace, patch)
    %{project | workspace: workspace}
  end

  defp at_version(project, track_id) do
    {:ok, track} = Project.fetch_track(project, track_id)
    track.space.version
  end

  defp slice!(project, track_id) do
    {:ok, windows} = Track.slice(project, track_id)
    windows
  end

  test "from_window：notes 带 span、time_range 与 tempo_segments" do
    {project, track_id} = setup_project()
    [w1, w2] = slice!(project, track_id)

    assert {:ok, req1} = RenderRequest.from_window(project, w1, tempo_map())
    assert req1.track_id == track_id
    assert req1.time_range == {0, 1440}
    assert req1.note_ids == ["n1", "n2"]

    assert [
             {"n1", %Coconut.Score.Note{lyric: "あ"}, {0, 480}},
             {"n2", %Coconut.Score.Note{lyric: "い"}, {480, 960}}
           ] = req1.notes

    assert [%{start_pos: 0} | _] = req1.tempo_segments

    assert {:ok, req2} = RenderRequest.from_window(project, w2, tempo_map())
    assert req2.time_range == {1440, 2880}
    assert req2.note_ids == ["n3"]
  end

  test "patch 过滤：Ordinal 按 refs ∩ note_ids，Metric 按 tick 区间相交" do
    {project, track_id} = setup_project()
    version = at_version(project, track_id)

    project =
      project
      |> attach_patch!(track_id, :phoneme_timing, %Tamale.Anchor.Ordinal{
        refs: ["n1"],
        at_version: version
      })
      |> attach_patch!(track_id, :phoneme_timing, %Tamale.Anchor.Ordinal{
        refs: ["n3"],
        at_version: version
      })
      |> attach_patch!(track_id, :phoneme_timing, %Tamale.Anchor.Metric{
        coord: :tick,
        from: 500,
        to: 700,
        at_version: version
      })
      # 跨两窗的 Metric 锚
      |> attach_patch!(track_id, :phoneme_timing, %Tamale.Anchor.Metric{
        coord: :tick,
        from: 1000,
        to: 2000,
        at_version: version
      })
      # 窗外 Metric 锚
      |> attach_patch!(track_id, :phoneme_timing, %Tamale.Anchor.Metric{
        coord: :tick,
        from: 5000,
        to: 6000,
        at_version: version
      })
      # Relative 锚按 ref 归属
      |> attach_patch!(track_id, :phoneme_timing, %Tamale.Anchor.Relative{
        ref: "n2",
        from_offset: 0,
        to_offset: 240,
        at_version: version
      })

    [w1, w2] = slice!(project, track_id)

    {:ok, req1} = RenderRequest.from_window(project, w1, tempo_map())
    anchors1 = Enum.map(req1.patches, fn patch -> anchor_shape(patch.anchor) end)

    assert Enum.count(anchors1) == 4
    assert {:ordinal, ["n1"]} in anchors1
    assert {:relative, "n2"} in anchors1
    assert {:metric, 500, 700} in anchors1
    assert {:metric, 1000, 2000} in anchors1

    {:ok, req2} = RenderRequest.from_window(project, w2, tempo_map())
    anchors2 = Enum.map(req2.patches, fn patch -> anchor_shape(patch.anchor) end)

    assert Enum.count(anchors2) == 2
    assert {:ordinal, ["n3"]} in anchors2
    assert {:metric, 1000, 2000} in anchors2
  end

  # 锚形状摘要（at_version 随写入推进，不参与断言）
  defp anchor_shape(%Tamale.Anchor.Ordinal{refs: refs}), do: {:ordinal, refs}
  defp anchor_shape(%Tamale.Anchor.Relative{ref: ref}), do: {:relative, ref}
  defp anchor_shape(%Tamale.Anchor.Metric{from: from, to: to}), do: {:metric, from, to}

  test "channels 从 patch + active preset 注册表派生；未注册 channel 不收录" do
    {project, track_id} = setup_project()
    version = at_version(project, track_id)

    # 侧表挂 preset：只注册 :phoneme_timing
    {:ok, preset} =
      Preset.new(name: "default", channels: %{phoneme_timing: PhonemeTiming})

    {:ok, meta} =
      TrackMeta.new(presets: %{"default" => preset}, active_preset: "default")

    {:ok, project} = Project.put_track_meta(project, track_id, meta)

    project =
      project
      |> attach_patch!(track_id, :phoneme_timing, %Tamale.Anchor.Ordinal{
        refs: ["n1"],
        at_version: version
      })
      |> attach_patch!(track_id, :pitch, %Tamale.Anchor.Ordinal{
        refs: ["n1"],
        at_version: version
      })

    [w1, _w2] = slice!(project, track_id)
    {:ok, req} = RenderRequest.from_window(project, w1, tempo_map())

    # :pitch 未注册 → 不收录（kernel check 阶段以 unknown_channel 上报）
    assert req.channels == %{phoneme_timing: PhonemeTiming}
    assert Enum.sort(Enum.map(req.patches, & &1.channel)) == [:phoneme_timing, :pitch]
  end

  test "无 preset 侧表时 channels 为空表" do
    {project, track_id} = setup_project()
    version = at_version(project, track_id)

    project =
      attach_patch!(project, track_id, :phoneme_timing, %Tamale.Anchor.Ordinal{
        refs: ["n1"],
        at_version: version
      })

    [w1, _w2] = slice!(project, track_id)
    {:ok, req} = RenderRequest.from_window(project, w1, tempo_map())

    assert req.channels == %{}
  end

  test "多轨工程按 note_ids 定位正确轨道" do
    {project, track_a} = setup_project()
    {:ok, project, _track} = Project.add_track(project, id: "Track_2", name: "和声")
    project = insert_notes(project, "Track_2", [{"m1", 0, 480, %{pitch: 67}}])

    {:ok, [wb]} = Track.slice(project, "Track_2")
    assert {:ok, req} = RenderRequest.from_window(project, wb, tempo_map())
    assert req.track_id == "Track_2"
    assert req.note_ids == ["m1"]

    [wa | _] = slice!(project, track_a)
    assert {:ok, req} = RenderRequest.from_window(project, wa, tempo_map())
    assert req.track_id == track_a
  end

  test "空 note_ids 的窗无法定位轨道" do
    {project, track_id} = setup_project()
    [w1 | _] = slice!(project, track_id)
    {:ok, empty_window} = EquinoxDomain.Windowing.Window.update(w1, note_ids: [])

    assert {:error, :cannot_locate_track} =
             RenderRequest.from_window(project, empty_window, tempo_map())
  end
end
