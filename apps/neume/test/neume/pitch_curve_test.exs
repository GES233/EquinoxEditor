defmodule Neume.PitchCurveTest do
  use ExUnit.Case, async: true

  alias Coconut.Curve.Adapter.Bezier
  alias Coconut.Curve.ControlPoint
  alias Coconut.Render.Engine.Snapshot
  alias Neume.PitchCurve

  test "Bezier 容器降为版本化 plain payload" do
    curve = %Bezier{
      points: [
        %ControlPoint{tick: 0, value: 60.0, handle_right: %{tick: 120, value: 1.0}},
        %ControlPoint{tick: 480, value: 64.0, handle_left: %{tick: -120, value: -1.0}}
      ]
    }

    assert {:ok, payload} = PitchCurve.from_bezier(curve)
    assert payload.format == :pitch_curve_v1
    assert payload.adapter == :bezier
    assert payload.coord == :absolute_tick
    assert payload.value == :absolute_midi
    assert Coconut.Pickle.pickle_conform?(payload)
    assert {:ok, [[0, 60.0], [480, 64.0]]} = PitchCurve.display_points(payload)
  end

  test "按真实帧 tick 栅格化，曲线中段不是端点线性平均" do
    curve = %Bezier{
      points: [
        %ControlPoint{tick: 0, value: 60.0, handle_right: %{tick: 160, value: 6.0}},
        %ControlPoint{tick: 479, value: 64.0, handle_left: %{tick: -160, value: 6.0}}
      ]
    }

    assert {:ok, payload} = PitchCurve.from_bezier(curve)

    snapshot = %Snapshot{tempo_map: nil, tpqn: 480}
    note = %{id: "n1", start_tick: 0, end_tick: 480, start_sec: 0.0, end_sec: 0.5}

    assert {:ok, points} = PitchCurve.to_worker_points(payload, note, snapshot, 0.0, 10.0)
    assert length(points) == 5
    assert [0.7, middle] = Enum.at(points, 2)
    assert middle > 64.0
  end

  test "旧折线 payload 保持兼容并校验 note span" do
    snapshot = %Snapshot{tempo_map: nil, tpqn: 480}
    note = %{id: "n1", start_tick: 0, end_tick: 480, start_sec: 0.0, end_sec: 0.5}

    assert {:ok, [[0.5, 60.0], [0.75, 62.0]]} =
             PitchCurve.to_worker_points([[0, 60], [240, 62]], note, snapshot, 0.0, 10.0)

    assert {:error, {:pitch_point_outside_note, "n1", 480}} =
             PitchCurve.to_worker_points([[480, 62]], note, snapshot, 0.0, 10.0)
  end
end
