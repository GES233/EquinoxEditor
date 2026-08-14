defmodule EquinoxDomain.Score.ProjectTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.TestFactory

  alias Coconut.Edit.Workspace
  alias EquinoxDomain.PickleTestHelper
  alias EquinoxDomain.Score.{Project, TrackMeta}

  describe "new/1" do
    test ":id 必填；workspace 缺省自动新建" do
      assert {:error, {:missing_id, _}} = Project.new(%{})

      {:ok, project} = Project.new(id: "Project_1")
      assert project.id == "Project_1"
      assert %Workspace{} = project.workspace
      assert project.tracks_meta == %{}
      assert project.metadata == %{}
    end
  end

  describe "轨道结构与侧表" do
    test "add_track 建 Vocal 轨并初始化 TrackMeta" do
      {:ok, project} = Project.new(id: "Project_1")
      assert {:ok, project, track} = Project.add_track(project, id: "Track_1", name: "主唱")

      assert track.module == Coconut.Edit.Track.Vocal
      assert {:ok, ^track} = Project.fetch_track(project, "Track_1")
      assert {:ok, %TrackMeta{gain: 1.0, mute: false}} = Project.track_meta(project, "Track_1")

      # 重复 id
      assert {:error, {:track_id_taken, "Track_1"}} =
               Project.add_track(project, id: "Track_1")
    end

    test "remove_track 连侧表一起移除；不存在报错" do
      {project, track_id} = project_with_track()

      assert {:ok, project} = Project.remove_track(project, track_id)
      assert {:error, {:unknown_track, ^track_id}} = Project.fetch_track(project, track_id)
      assert {:error, {:unknown_track_meta, ^track_id}} = Project.track_meta(project, track_id)

      assert {:error, {:unknown_track, ^track_id}} = Project.remove_track(project, track_id)
    end

    test "put_track_meta 校验轨道存在与 meta 合法" do
      {project, track_id} = project_with_track()
      {:ok, meta} = TrackMeta.new(gain: 0.8, mute: true)

      assert {:ok, project} = Project.put_track_meta(project, track_id, meta)
      assert {:ok, ^meta} = Project.track_meta(project, track_id)

      assert {:error, {:unknown_track, "Track_x"}} =
               Project.put_track_meta(project, "Track_x", meta)
    end
  end

  describe "查询代理" do
    test "tempo_map：默认空 tempo 轨报 missing_tempo_track" do
      {project, _track_id} = project_with_track()
      assert {:error, :missing_tempo_track} = Project.tempo_map(project)
    end

    test "time_sig_map：默认 [{1, {4, 4}}] 可编译" do
      {project, _track_id} = project_with_track()
      assert {:ok, %Coconut.Score.TimeSigMap{}} = Project.time_sig_map(project)
    end

    test "view 返回带 span 的音符视图（按 {start, id} 排序）" do
      {project, track_id} = project_with_track()

      project =
        insert_notes(project, track_id, [
          {"n2", 480, 960, %{pitch: 62, lyric: "い"}},
          {"n1", 0, 480, %{pitch: 60, lyric: "あ"}}
        ])

      assert {:ok,
              [
                {"n1", %Coconut.Score.Note{lyric: "あ"}, {0, 480}},
                {"n2", %Coconut.Score.Note{lyric: "い"}, {480, 960}}
              ]} =
               Project.view(project, track_id)
    end
  end

  describe "dump/load 往返" do
    test "空工程往返" do
      {:ok, project} = Project.new(id: "Project_1", metadata: %{"title" => "demo"})

      {:ok, dumped} = Project.dump(project)
      PickleTestHelper.assert_plain!(dumped)
      assert dumped.version == 1

      assert {:ok, loaded} = Project.load(dumped)
      assert loaded.id == project.id
      assert loaded.metadata == project.metadata
      assert loaded.workspace == project.workspace
      assert loaded.tracks_meta == project.tracks_meta
    end

    test "含音符与 patch 的工程往返" do
      {project, track_id} = project_with_track()

      project =
        insert_notes(project, track_id, [
          {"n1", 0, 480, %{pitch: 60, lyric: "あ"}},
          {"n2", 480, 960, %{pitch: 62, lyric: "い"}}
        ])

      # 挂一条 phoneme_timing patch（经 AdoptRequest 构造 + Workspace 挂载）
      {:ok, patch} =
        EquinoxDomain.Command.AdoptRequest.build_patch(
          project.workspace,
          EquinoxDomain.Port.Channels.PhonemeTiming,
          %{
            track_id: track_id,
            anchor: {:ordinal, ["n1"]},
            payload: %{
              deltas: [%{identity: "ph_1", onset_delta_ms: 12, duration_delta_ms: -30}]
            }
          }
        )

      {:ok, workspace, _minted} = Workspace.attach_patch(project.workspace, patch)
      project = %{project | workspace: workspace}

      # 侧表写入自定义 meta
      {:ok, meta} = TrackMeta.new(gain: 0.75, pan: -0.2, solo: true)
      {:ok, project} = Project.put_track_meta(project, track_id, meta)

      {:ok, dumped} = Project.dump(project)
      PickleTestHelper.assert_plain!(dumped)

      assert {:ok, loaded} = Project.load(dumped)
      assert loaded.workspace == project.workspace
      assert loaded.tracks_meta == project.tracks_meta
    end

    test "load 拒绝非 map 输入" do
      assert {:error, {:invalid_project_dump, _}} = Project.load("bogus")
    end
  end
end
