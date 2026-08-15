defmodule EquinoxDomain.Port.Channels.CurveTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.TestFactory

  alias Coconut.Curve.Adapter.CatmullRom
  alias Coconut.Edit.{Command, History}
  alias EquinoxDomain.Command.{AdoptRequest, RenderRequest}
  alias EquinoxDomain.Port.{Channels.Curve, Channels.PhonemeTiming, Preset}
  alias EquinoxDomain.Score.{Project, Track, TrackMeta}

  @notes [
    {"n1", 0, 480, %{pitch: 60, lyric: "あ"}},
    {"n2", 480, 960, %{pitch: 62, lyric: "い"}}
  ]

  defp setup do
    {project, track_id} = project_with_track()
    project = insert_notes(project, track_id, @notes)
    {:ok, track} = Project.fetch_track(project, track_id)
    {project, track_id, track.space.version}
  end

  defp shell_patch(track_id, anchor) do
    %Coconut.Edit.Patch{
      id: nil,
      track_id: track_id,
      anchor: anchor,
      patch: nil,
      channel: :curve
    }
  end

  defp points do
    [
      %{tick: 0, value: 60.0, handle_left: nil, handle_right: nil},
      %{tick: 480, value: 62.5, handle_left: nil, handle_right: nil}
    ]
  end

  test "channel/0 与 target/0（契约兜底静态落点）" do
    assert Curve.channel() == :curve
    assert Curve.target() == {:port, :synth, :curve}
  end

  describe "projection/2 + base_for/1" do
    test "Ordinal 锚（多 refs）产出逐音符 canonical base 列表" do
      {project, track_id, version} = setup()

      patch =
        shell_patch(track_id, %Tamale.Anchor.Ordinal{refs: ["n1", "n2"], at_version: version})

      assert {:ok, [b1, b2]} = Curve.projection(project.workspace, patch)
      assert %{"note" => %{"lyric" => "あ"}, "span" => [0, 480]} = b1
      assert %{"note" => %{"lyric" => "い"}, "span" => [480, 960]} = b2

      # canonical 纪律：digest 直接可算
      assert {:ok, digest} = Tamale.Digest.digest([b1, b2])
      assert is_binary(digest)
    end

    test "Relative 锚取 ref 音符" do
      {project, track_id, version} = setup()

      patch =
        shell_patch(track_id, %Tamale.Anchor.Relative{
          ref: "n2",
          from_offset: 0,
          to_offset: 240,
          at_version: version
        })

      assert {:ok, [%{"span" => [480, 960]}]} = Curve.projection(project.workspace, patch)
    end

    test "与 PhonemeTiming.base_for/2 逐音符一致（单一实现对拍）" do
      {project, track_id, version} = setup()
      {:ok, {"n1", note, span}} = Track.note(project, track_id, "n1")

      patch =
        shell_patch(track_id, %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: version})

      assert {:ok, [base]} = Curve.projection(project.workspace, patch)
      assert {:ok, ^base} = PhonemeTiming.base_for(note, span)
      assert {:ok, [^base]} = Curve.base_for([{note, span}])
    end

    test "错误路径：Metric 锚拒绝；音符不存在" do
      {project, track_id, version} = setup()

      metric = shell_patch(track_id, %Tamale.Anchor.Metric{coord: :tick, from: 0, to: 480})
      assert {:error, :unsupported_anchor} = Curve.projection(project.workspace, metric)

      missing =
        shell_patch(track_id, %Tamale.Anchor.Ordinal{refs: ["n9"], at_version: version})

      assert {:error, {:note_not_found, "n9"}} = Curve.projection(project.workspace, missing)
    end
  end

  describe "build_payload/3" do
    test "合法输入：adapter 存字符串形、多余键剥离" do
      assert {:ok, payload} =
               Curve.build_payload(:pitch, CatmullRom, [
                 %{tick: 0, value: 60.0, handle_left: nil, handle_right: nil, junk: 1},
                 %{
                   tick: 240,
                   value: 61.0,
                   handle_left: %{tick: -40, value: 0.5},
                   handle_right: nil
                 }
               ])

      assert payload.param == :pitch
      assert payload.adapter == "Elixir.Coconut.Curve.Adapter.CatmullRom"

      assert [%{tick: 0, value: 60.0, handle_left: nil, handle_right: nil}, second] =
               payload.points

      assert second == %{
               tick: 240,
               value: 61.0,
               handle_left: %{tick: -40, value: 0.5},
               handle_right: nil
             }
    end

    test "校验矩阵：param / adapter / points" do
      assert {:error, {:invalid_param, "pitch"}} =
               Curve.build_payload("pitch", CatmullRom, points())

      assert {:error, {:invalid_adapter, NotAModule}} =
               Curve.build_payload(:pitch, NotAModule, points())

      assert {:error, {:invalid_points, :empty}} =
               Curve.build_payload(:pitch, CatmullRom, [])

      assert {:error, {:invalid_points, {:bad_tick, -1}}} =
               Curve.build_payload(:pitch, CatmullRom, [
                 %{tick: -1, value: 60.0, handle_left: nil, handle_right: nil}
               ])

      assert {:error, {:invalid_points, {:bad_value, "high"}}} =
               Curve.build_payload(:pitch, CatmullRom, [
                 %{tick: 0, value: "high", handle_left: nil, handle_right: nil}
               ])

      assert {:error, {:invalid_points, {:bad_handle, :handle_left, 1}}} =
               Curve.build_payload(:pitch, CatmullRom, [
                 %{tick: 0, value: 60.0, handle_left: 1, handle_right: nil}
               ])

      assert {:error, {:invalid_points, {:ticks_not_ascending, 240, 240}}} =
               Curve.build_payload(:pitch, CatmullRom, [
                 %{tick: 0, value: 60.0, handle_left: nil, handle_right: nil},
                 %{tick: 240, value: 61.0, handle_left: nil, handle_right: nil},
                 %{tick: 240, value: 62.0, handle_left: nil, handle_right: nil}
               ])
    end
  end

  test "AdoptRequest 挂载 + Preset 注册 + from_window 过滤全链路" do
    {project, track_id, _version} = setup()
    {:ok, payload} = Curve.build_payload(:pitch, CatmullRom, points())

    # 挂载（Ordinal 锚 n1）
    {:ok, patch} =
      AdoptRequest.build_patch(project.workspace, Curve, %{
        track_id: track_id,
        anchor: {:ordinal, ["n1"]},
        payload: payload
      })

    assert patch.channel == :curve

    hist = History.new(project.workspace)
    {:ok, hist} = History.run(hist, Command.attach_patches([patch]))
    project = %{project | workspace: History.current(hist).workspace}

    # Preset 注册 :curve → from_window 收录进 channels
    {:ok, preset} =
      Preset.new(name: "default", channels: %{curve: Curve}, artifact: [:curve])

    {:ok, meta} = TrackMeta.new(presets: %{"default" => preset}, active_preset: "default")
    {:ok, project} = Project.put_track_meta(project, track_id, meta)

    [window | _] = slice!(project, track_id)
    assert {:ok, req} = RenderRequest.from_window(project, window, tempo_map())
    assert req.channels == %{curve: Curve}
    assert [%{channel: :curve, patch: %{payload: ^payload}}] = req.patches
  end

  defp slice!(project, track_id) do
    {:ok, windows} = Track.slice(project, track_id)
    windows
  end
end
