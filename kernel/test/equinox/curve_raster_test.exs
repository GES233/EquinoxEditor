defmodule Equinox.Kernel.CurveRasterTest do
  use ExUnit.Case, async: true

  alias Coconut.Curve.Adapter.CatmullRom
  alias Coconut.Score.{Tempo, TempoMap}
  alias Equinox.Kernel.CurveRaster
  alias EquinoxDomain.Port.Channels.Curve

  # 120bpm / tpqn 480：480 ticks = 0.5s
  defp segments(start_tick, end_tick) do
    {:ok, tempo_map} =
      TempoMap.compile([{0, %Tempo.Event{module: Tempo.Step, context: %{bpm: 120.0}}}],
        tpqn: 480
      )

    TempoMap.slice(tempo_map, start_tick, end_tick)
  end

  defp payload(points) do
    {:ok, payload} = Curve.build_payload(:pitch, CatmullRom, points)
    payload
  end

  defp point(tick, value), do: %{tick: tick, value: value, handle_left: nil, handle_right: nil}

  defp decode_f32(samples) do
    for <<value::float-32-native <- samples>>, do: value
  end

  test "帧网格光栅化：120bpm 下 tick ↔ 秒换算 + CatmullRom 采样" do
    # 0..960 ticks = 1s；frame_rate 100 / hop 50 → 帧周期 0.5s → 3 帧（0/480/960）
    payload = payload([point(0, 60.0), point(960, 62.5)])

    assert {:ok, rasterized} =
             CurveRaster.rasterize(payload, segments(0, 960), 480, %{frame_rate: 100, hop: 50})

    assert rasterized.param == :pitch
    assert rasterized.start_tick == 0
    assert rasterized.end_tick == 960
    assert rasterized.stride == 50
    assert byte_size(rasterized.samples) == 3 * 4

    assert [v0, v1, v2] = decode_f32(rasterized.samples)
    assert_in_delta v0, 60.0, 0.01
    assert_in_delta v1, 61.25, 0.01
    assert_in_delta v2, 62.5, 0.01
  end

  test "零时长曲线出单帧" do
    payload = payload([point(480, 61.0)])

    assert {:ok, rasterized} =
             CurveRaster.rasterize(payload, segments(0, 960), 480, %{frame_rate: 100, hop: 50})

    assert [v] = decode_f32(rasterized.samples)
    assert_in_delta v, 61.0, 0.01
  end

  test "tempo 变化影响帧 tick 换算（60bpm：480 ticks = 1s）" do
    {:ok, tempo_map} =
      TempoMap.compile([{0, %Tempo.Event{module: Tempo.Step, context: %{bpm: 60.0}}}], tpqn: 480)

    segments = TempoMap.slice(tempo_map, 0, 480)
    payload = payload([point(0, 60.0), point(480, 62.0)])

    # 0..480 ticks = 1s；帧周期 0.5s → 3 帧，tick 0/240/480
    assert {:ok, rasterized} =
             CurveRaster.rasterize(payload, segments, 480, %{frame_rate: 100, hop: 50})

    assert [v0, v1, v2] = decode_f32(rasterized.samples)
    assert_in_delta v0, 60.0, 0.01
    assert_in_delta v1, 61.0, 0.01
    assert_in_delta v2, 62.0, 0.01
  end

  test "错误路径：非法 adapter / timing / 空切片 / 非法 payload" do
    payload = payload([point(0, 60.0), point(480, 61.0)])

    assert {:error, {:invalid_adapter, "Elixir.No.Such"}} =
             CurveRaster.rasterize(
               %{payload | adapter: "Elixir.No.Such"},
               segments(0, 480),
               480,
               %{
                 frame_rate: 100,
                 hop: 50
               }
             )

    assert {:error, {:invalid_timing_spec, _}} =
             CurveRaster.rasterize(payload, segments(0, 480), 480, %{frame_rate: 0, hop: 50})

    assert {:error, :empty_tempo_segments} =
             CurveRaster.rasterize(payload, [], 480, %{frame_rate: 100, hop: 50})

    assert {:error, {:invalid_curve_payload, _}} =
             CurveRaster.rasterize(%{param: :pitch}, segments(0, 480), 480, %{
               frame_rate: 100,
               hop: 50
             })
  end
end
