defmodule EquinoxUIShell.ProjectPresenterTest do
  use ExUnit.Case, async: true

  alias Equinox.Kernel.Graph
  alias EquinoxDomain.Score.{Project, Track}
  alias EquinoxUIShell.ProjectPresenter
  alias Zongzi.Score.Key.TwelveET
  alias Zongzi.Score.Tempo

  # 窗口规则（zongzi RestSplit3Beats）：gap >= 3 拍切开，前 1 拍归前片、后 2 拍归后片。
  # 夹具：音符 0..240 / 240..720 粘连成窗口 {0, 720}；音符 2400..2640 与前者
  # gap 1680 >= 1440 切开，窗口 {2400 - 960, 2640} = {1440, 2640}。

  setup do
    {:ok, project} =
      Project.new(
        id: "Project_test",
        name: "Presenter Fixture",
        tempo_map: [{0, %Tempo.Event{module: Tempo.Step, context: %{bpm: 120}}}]
      )

    {:ok, track} =
      Track.new(
        id: "Track_1",
        name: "Lead",
        gain: 0.8,
        pan: -0.5,
        metadata: %{
          "color" => "#aabbcc",
          "ui_state" => %{arranger_position: %{x: 50, y: 30}}
        }
      )

    {:ok, track, _n1} = Track.insert_note(track, note_attrs(0, 240, 60, "la"))
    {:ok, track, _n2} = Track.insert_note(track, note_attrs(240, 480, 62, "ha", "h"))

    {:ok, track, _n3} =
      Track.insert_note(track, note_attrs(2400, 240, 64, "far"))

    {:ok, track_empty} = Track.new(id: "Track_empty", name: "Empty", type: :external_audio)

    {:ok, project} = Project.add_track(project, track)
    {:ok, project} = Project.add_track(project, track_empty)

    graph = Graph.new()
    %{project: project, graphs: %{"Track_1" => graph}, graph: graph}
  end

  defp note_attrs(start_tick, duration_tick, midi, lyric, phoneme \\ nil) do
    {:ok, key} = TwelveET.new(midi)

    %{
      start_tick: start_tick,
      duration_tick: duration_tick,
      key: key,
      lyric: lyric,
      metadata: if(phoneme, do: %{"phoneme" => phoneme}, else: %{})
    }
  end

  describe "to_frontend/1" do
    test "工程级字段对齐 TS ProjectData", %{project: project, graphs: graphs} do
      data = ProjectPresenter.to_frontend(%{project: project, graphs: graphs})

      assert data.id == "Project_test"
      assert data.name == "Presenter Fixture"
      assert data.version == 1
      assert data.ticks_per_beat == 480
      assert data.tempo_map == [%{tick: 0, bpm: 120}]
      assert data.arranger_graph == nil
      assert data.extra == %{}
      assert Map.keys(data.tracks) |> Enum.sort() == ["Track_1", "Track_empty"]
    end

    test "轨级字段：type 字符串化、color/ui_state 从 metadata 还原、synth_graph 取自 graphs",
         %{project: project, graphs: graphs, graph: graph} do
      data = ProjectPresenter.to_frontend(%{project: project, graphs: graphs})
      track = data.tracks["Track_1"]

      assert track.id == "Track_1"
      assert track.project_id == "Project_test"
      assert track.type == "synth"
      assert track.name == "Lead"
      assert track.topology_ref == nil
      # edges 摊平为 list（MapSet 无 Jason Encoder，见 Presenter.graph_to_frontend/1）
      assert track.synth_graph == %{nodes: graph.nodes, edges: MapSet.to_list(graph.edges)}
      assert track.color == "#aabbcc"
      assert track.gain == 0.8
      assert track.pan == -0.5
      assert track.mute == false
      assert track.solo == false
      assert track.insert_fx_chain == []
      assert track.ui_state == %{arranger_position: %{x: 50, y: 30}}
      assert track.parameters == %{}
      assert track.extra == %{}

      empty = data.tracks["Track_empty"]
      assert empty.type == "external_audio"
      assert empty.synth_graph == nil
      assert empty.color == ""
      assert empty.ui_state == %{}
      assert empty.segments == %{}
    end

    test "窗口仿真为 SegmentData：id 为 w<start_tick>，音符转窗口相对 tick",
         %{project: project, graphs: graphs} do
      data = ProjectPresenter.to_frontend(%{project: project, graphs: graphs})
      segments = data.tracks["Track_1"].segments

      assert Map.keys(segments) |> Enum.sort() == ["w0", "w1440"]

      w0 = segments["w0"]
      assert w0.id == "w0"
      assert w0.track_id == "Track_1"
      assert w0.offset_tick == 0
      assert w0.curves == %{}
      assert w0.extra == %{}
      assert length(w0.notes) == 2

      [n1, n2] = w0.notes
      assert n1.start_tick == 0
      assert n1.duration_tick == 240
      assert n1.key == 60
      assert n1.lyric == "la"
      assert n1.phoneme == nil
      assert n1.extra == %{}

      assert n2.start_tick == 240
      assert n2.key == 62
      # phoneme 从 Note.metadata["phoneme"] 还原
      assert n2.phoneme == "h"

      w1 = segments["w1440"]
      assert w1.offset_tick == 1440
      assert [n3] = w1.notes
      # 窗口起点含归属的 2 拍空拍，音符 tick 仍为窗口相对
      assert n3.start_tick == 2400 - 1440
      assert n3.key == 64
    end

    test "产物可 Jason 编码（含 Graph struct 的 synth_graph）",
         %{project: project, graphs: graphs} do
      data = ProjectPresenter.to_frontend(%{project: project, graphs: graphs})
      assert json = Jason.encode!(data)
      assert is_binary(json)
    end
  end

  describe "window_id/1 与 parse_window_id/1" do
    test "双向转换" do
      assert ProjectPresenter.window_id(0) == "w0"
      assert ProjectPresenter.window_id(1440) == "w1440"
      assert ProjectPresenter.parse_window_id("w0") == {:ok, 0}
      assert ProjectPresenter.parse_window_id("w1440") == {:ok, 1440}

      assert {:ok, tick} = ProjectPresenter.parse_window_id(ProjectPresenter.window_id(960))
      assert tick == 960
    end

    test "非法 id 报错" do
      assert {:error, {:invalid_window_id, "seg_1"}} = ProjectPresenter.parse_window_id("seg_1")
      assert {:error, {:invalid_window_id, "w-5"}} = ProjectPresenter.parse_window_id("w-5")
      assert {:error, {:invalid_window_id, "w12x"}} = ProjectPresenter.parse_window_id("w12x")
      assert {:error, {:invalid_window_id, "w"}} = ProjectPresenter.parse_window_id("w")
      assert {:error, {:invalid_window_id, nil}} = ProjectPresenter.parse_window_id(nil)
    end
  end

  describe "ui_note_to_attrs/2" do
    test "相对 tick 还原绝对 tick、midi 转 TwelveET、phoneme 进 metadata、id 透传" do
      ui_note = %{
        "id" => "Note_ui_1",
        "start_tick" => 240,
        "duration_tick" => 480,
        "key" => 62,
        "lyric" => "ha",
        "phoneme" => "h",
        "extra" => %{"frontend_only" => true}
      }

      assert {:ok, attrs} = ProjectPresenter.ui_note_to_attrs(ui_note, 1440)

      assert attrs.start_tick == 1680
      assert attrs.duration_tick == 480
      assert attrs.key == %TwelveET{midi: 62}
      assert attrs.lyric == "ha"
      assert attrs.metadata == %{"phoneme" => "h"}
      assert attrs.id == "Note_ui_1"
      # domain Note 无 extra 字段，直接忽略
      refute Map.has_key?(attrs, :extra)
    end

    test "缺省值与可选字段" do
      assert {:ok, attrs} = ProjectPresenter.ui_note_to_attrs(%{}, 0)

      assert attrs.start_tick == 0
      assert attrs.duration_tick == 480
      assert attrs.key == %TwelveET{midi: 60}
      assert attrs.lyric == "la"
      assert attrs.metadata == %{}
      # 无 id 时不透传（由 Track.insert_note 自动生成）
      refute Map.has_key?(attrs, :id)
    end

    test "兼容前端 length_tick/pitch 别名" do
      ui_note = %{"start_tick" => 0, "length_tick" => 960, "pitch" => 67}

      assert {:ok, attrs} = ProjectPresenter.ui_note_to_attrs(ui_note, 480)

      assert attrs.start_tick == 480
      assert attrs.duration_tick == 960
      assert attrs.key == %TwelveET{midi: 67}
    end

    test "round trip：to_frontend 的音符经 ui_note_to_attrs 还原为原绝对位置",
         %{project: project, graphs: graphs} do
      data = ProjectPresenter.to_frontend(%{project: project, graphs: graphs})
      w1 = data.tracks["Track_1"].segments["w1440"]
      {:ok, window_start} = ProjectPresenter.parse_window_id(w1.id)

      # 前端数据经 JSON 往返是 string 键，模拟真实通路
      ui_note = w1.notes |> hd() |> Jason.encode!() |> Jason.decode!()

      assert {:ok, attrs} = ProjectPresenter.ui_note_to_attrs(ui_note, window_start)

      assert attrs.start_tick == 2400
      assert attrs.duration_tick == 240
      assert attrs.key == %TwelveET{midi: 64}
    end

    test "非法 key 报错" do
      assert {:error, _} = ProjectPresenter.ui_note_to_attrs(%{"key" => "not-a-number"}, 0)
    end
  end
end
