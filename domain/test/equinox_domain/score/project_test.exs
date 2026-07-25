defmodule EquinoxDomain.Score.ProjectTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Score.{Project, Track}
  alias Zongzi.Score.Key.TwelveET
  alias Zongzi.Util.ID

  setup do
    {:ok, project} = Project.new(id: ID.generate_id("Project_"), name: "测试工程")
    %{project: project}
  end

  defp new_track(name \\ "轨") do
    {:ok, track} =
      Track.new(id: ID.generate_id("Track_"), project_id: "Project_别处", name: name)

    track
  end

  describe "add_track/2" do
    test "挂载成功且 project_id 对齐为工程 id", %{project: project} do
      track = new_track()

      assert {:ok, project} = Project.add_track(project, track)
      assert {:ok, stored} = Project.get_track(project, track.id)
      assert stored.project_id == project.id
      assert Project.list_tracks(project) |> Enum.map(& &1.id) == [track.id]
    end

    test "track id 冲突报 already_exists", %{project: project} do
      track = new_track()

      assert {:ok, project} = Project.add_track(project, track)
      assert {:error, {:already_exists, id}} = Project.add_track(project, track)
      assert id == track.id
    end
  end

  describe "remove_track/2" do
    test "移除存在的 Track", %{project: project} do
      track = new_track()

      assert {:ok, project} = Project.add_track(project, track)
      assert {:ok, project} = Project.remove_track(project, track.id)
      assert Project.list_tracks(project) == []
    end

    test "移除不存在的 Track 报 track_not_found（不静默）", %{project: project} do
      assert {:error, {:track_not_found, "Track_不存在"}} =
               Project.remove_track(project, "Track_不存在")
    end
  end

  describe "get_track/2" do
    test "取不到报 track_not_found", %{project: project} do
      assert {:error, {:track_not_found, "Track_不存在"}} =
               Project.get_track(project, "Track_不存在")
    end
  end

  describe "update_track/3" do
    test "整体替换", %{project: project} do
      track = new_track("旧名")

      assert {:ok, project} = Project.add_track(project, track)
      assert {:ok, renamed} = Track.update(track, %{name: "新名"})
      assert {:ok, project} = Project.update_track(project, track.id, renamed)
      assert {:ok, %{name: "新名"}} = Project.get_track(project, track.id)
    end

    test "updater 函数", %{project: project} do
      track = new_track("旧名")

      assert {:ok, project} = Project.add_track(project, track)

      assert {:ok, project} =
               Project.update_track(project, track.id, fn old ->
                 {:ok, updated} = Track.update(old, %{gain: 0.5})
                 updated
               end)

      assert {:ok, %{gain: 0.5}} = Project.get_track(project, track.id)
    end

    test "更新不存在的 Track 报 track_not_found", %{project: project} do
      track = new_track()

      assert {:error, {:track_not_found, _}} = Project.update_track(project, track.id, track)

      assert {:error, {:track_not_found, _}} =
               Project.update_track(project, track.id, fn old -> old end)
    end
  end

  describe "list_tracks/1" do
    test "空工程返回空列表", %{project: project} do
      assert Project.list_tracks(project) == []
    end
  end

  describe "dump/load 含 tracks 的 round trip" do
    test "CRUD 之后序列化往返保持一致", %{project: project} do
      {:ok, key} = TwelveET.new(60)
      track = new_track("主唱")

      {:ok, track, _note} =
        Track.insert_note(track, start_tick: 0, duration_tick: 480, key: key, lyric: "a")

      assert {:ok, project} = Project.add_track(project, track)

      assert {:ok, project} =
               Project.update_track(project, track.id, fn old ->
                 {:ok, updated} = Track.update(old, %{metadata: %{"color" => "#FFFFFF"}})
                 updated
               end)

      assert {:ok, dump} = Project.dump(project)
      assert {:ok, loaded} = Project.load(dump)

      assert loaded.id == project.id
      assert {:ok, loaded_track} = Project.get_track(loaded, track.id)
      assert loaded_track.metadata == %{"color" => "#FFFFFF"}
      assert Track.active_notes(loaded_track) |> length() == 1
    end
  end
end
