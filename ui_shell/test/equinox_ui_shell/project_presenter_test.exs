defmodule EquinoxUIShell.ProjectPresenterTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{History, Operations.InsertNote}
  alias Coconut.Score.Key.TwelveET
  alias Equinox.Kernel.Graph
  alias EquinoxDomain.Score.{Project, TrackMeta}
  alias EquinoxUIShell.ProjectPresenter

  # 窗口规则（EquinoxDomain.Windowing，移植 RestSplit3Beats）：
  # gap >= 3 拍切开，前 1 拍归前片、后 2 拍归后片。
  # 夹具：音符 0..240 / 240..720 粘连成窗口 {0, 1200}（含归属的 1 拍空拍）；
  # 音符 2400..2640 与前者 gap 1680 >= 1440 切开，窗口 {2400 - 960, 2640} = {1440, 2640}。

  setup do
    {:ok, project} =
      Project.new(id: "Project_test", metadata: %{name: "Presenter Fixture"})

    {:ok, project, _track} = Project.add_track(project, id: "Track_1", name: "Lead")
    {:ok, project, _empty} = Project.add_track(project, id: "Track_empty", name: "Empty")

    {:ok, project} =
      seed_elements(project, [
        # tempo 全局轨：Step 120 事件（cast 时归一化为 milli-bpm）
        {"global:tempo", "Tempo_1", :head, {0, 480}, %{bpm: 120}},
        {"Track_1", "Note_1", :head, {0, 240}, %{pitch: twelve_et(60), lyric: "la"}},
        {"Track_1", "Note_2", "Note_1", {240, 720},
         %{pitch: twelve_et(62), lyric: "ha", phoneme: "h"}},
        {"Track_1", "Note_3", "Note_2", {2400, 2640}, %{pitch: twelve_et(64), lyric: "far"}}
      ])

    # 混音 / color / ui_state 属 equinox 侧表（TrackMeta，不进 History）
    {:ok, meta} =
      TrackMeta.new(
        gain: 0.8,
        pan: -0.5,
        metadata: %{"color" => "#aabbcc"},
        ui_state: %{arranger_position: %{x: 50, y: 30}}
      )

    {:ok, project} = Project.put_track_meta(project, "Track_1", meta)

    graph = Graph.new()
    %{project: project, graphs: %{"Track_1" => graph}, graph: graph}
  end

  defp twelve_et(midi) do
    {:ok, key} = TwelveET.new(midi)
    key
  end

  # 经 coconut History 逐条 apply InsertNote 手势，返回 workspace 已推进的 project
  # （与 kernel overall_test 夹具同款模式）
  defp seed_elements(%Project{} = project, inserts) do
    hist = History.new(project.workspace)

    Enum.reduce_while(inserts, {:ok, hist}, fn {track_id, note_id, after_id, span, attrs},
                                               {:ok, hist} ->
      req = %InsertNote{
        track_id: track_id,
        note_id: note_id,
        after_id: after_id,
        span: span,
        attrs: attrs
      }

      case History.apply(hist, req) do
        {:ok, hist} -> {:cont, {:ok, hist}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, hist} -> {:ok, %{project | workspace: History.current(hist).workspace}}
      {:error, _} = err -> err
    end
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

    test "轨级字段：type 由 module 推导、color/ui_state 从 TrackMeta 还原、synth_graph 取自 graphs",
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
      # coconut 时代 kernel 只造 Vocal 轨，type 恒推导为 "synth"（无 external_audio）
      assert empty.type == "synth"
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
      assert n1.id == "Note_1"
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
    test "相对 tick 还原绝对 tick、midi 转 TwelveET、phoneme 平铺进 attrs" do
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
      # phoneme 平铺：kernel 经 coconut `Note.from_element/2` 落入 metadata["phoneme"]
      assert attrs.phoneme == "h"
      # id 不透传（整窗替换走 Diff，id 由 kernel 重铸）；extra 直接忽略
      refute Map.has_key?(attrs, :id)
      refute Map.has_key?(attrs, :extra)
    end

    test "缺省值与可选字段" do
      assert {:ok, attrs} = ProjectPresenter.ui_note_to_attrs(%{}, 0)

      assert attrs.start_tick == 0
      assert attrs.duration_tick == 480
      assert attrs.key == %TwelveET{midi: 60}
      assert attrs.lyric == "la"
      # 无 phoneme 时不产出该键（避免写入空 metadata）
      refute Map.has_key?(attrs, :phoneme)
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
