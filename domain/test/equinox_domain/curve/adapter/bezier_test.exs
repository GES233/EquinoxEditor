defmodule EquinoxDomain.Curve.Adapter.BezierTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Curve.{ControlPoint, Adapter}
  alias Adapter.{Bezier, Inner}

  # helpers — new/1 returns {:ok, _}

  defp pt(tick, value) do
    {:ok, cp} = ControlPoint.new(tick: tick, value: value)
    cp
  end

  defp pt(tick, value, hl, hr) do
    {:ok, cp} = ControlPoint.new(
      tick: tick, value: value, handle_left: hl, handle_right: hr
    )
    cp
  end

  defp h(tick, value), do: %{tick: tick, value: value}

  defp build(points) do
    {:ok, bez} = Bezier.new(points: points)
    bez
  end

  defp decode(bin) do
    for <<v::float-32-native <- bin>>, do: v
  end

  # ---- empty ----

  test "empty curve produces all zeros" do
    bez = build([])
    assert Inner.span(bez) == 0
    assert Inner.control_points(bez) == []
    got = decode(Inner.rasterize(bez, 0..4))
    assert got == [0.0, 0.0, 0.0, 0.0, 0.0]
  end

  # ---- single point ----

  test "single point produces constant value" do
    bez = build([pt(100, 3.5)])
    assert Inner.span(bez) == 100
    got = decode(Inner.rasterize(bez, 0..200))
    assert Enum.all?(got, &(&1 == 3.5))
  end

  # ---- two-point default handles ----

  test "two points default handles produce smooth monotonic curve" do
    bez = build([pt(0, 0.0), pt(300, 1.0)])
    got = decode(Inner.rasterize(bez, 0..300))
    assert hd(got) == 0.0
    assert List.last(got) == 1.0
    for i <- 1..300 do
      assert Enum.at(got, i) >= Enum.at(got, i - 1)
    end
  end

  # ---- custom handles ----

  test "custom right handle pulls curve up early" do
    bez = build([pt(0, 0.0, nil, h(100, 0.8)), pt(300, 1.0)])
    got = decode(Inner.rasterize(bez, 0..300))
    mid = Enum.at(got, 150)
    # CP1=(100,0.8) lifts early section above linear midpoint 0.5
    assert mid > 0.6
  end

  test "custom left handle with negative value delta pulls curve down" do
    # left handle of second point with negative value offset pulls curve down
    bez = build([pt(0, 0.0), pt(300, 1.0, h(-100, -0.5), nil)])
    got = decode(Inner.rasterize(bez, 0..300))
    mid = Enum.at(got, 150)
    # CP2=(200, 0.5) drags midpoint below 0.5
    assert mid < 0.45
  end

  test "asymmetric handles create early rise, late settle" do
    bez = build([
      pt(0, 0.0, nil, h(50, 0.9)),
      pt(300, 1.0, h(-50, 0.1), nil)
    ])
    got = decode(Inner.rasterize(bez, 0..300))
    assert hd(got) == 0.0
    assert List.last(got) == 1.0
    early = Enum.at(got, 60)
    late  = Enum.at(got, 240)
    assert early > 0.3
    # late section ~1.02 due to handle offsets — still near 1.0
    assert_in_delta late, 1.0, 0.05
  end

  # ---- boundaries ----

  test "ticks before first point clamp to first value" do
    bez = build([pt(100, 2.0), pt(200, 4.0)])
    got = decode(Inner.rasterize(bez, 0..99))
    assert Enum.all?(got, &(&1 == 2.0))
  end

  test "ticks after last point clamp to last value" do
    bez = build([pt(100, 2.0), pt(200, 4.0)])
    got = decode(Inner.rasterize(bez, 201..300))
    assert Enum.all?(got, &(&1 == 4.0))
  end

  # ---- multiple segments ----

  test "three points make two segments with peak at middle" do
    bez = build([pt(0, 0.0), pt(100, 5.0), pt(200, 1.0)])
    assert Inner.span(bez) == 200
    got = decode(Inner.rasterize(bez, 0..200))
    assert hd(got) == 0.0
    mid = Enum.at(got, 100)
    assert_in_delta mid, 5.0, 0.01
    assert List.last(got) == 1.0
  end

  # ---- determinism ----

  test "rasterize is deterministic" do
    bez = build([pt(0, 0.0), pt(100, 3.0), pt(200, 1.0)])
    a = Inner.rasterize(bez, 0..200)
    b = Inner.rasterize(bez, 0..200)
    assert a == b
  end

  # ---- degenerate ----

  test "two points at same tick" do
    bez = build([pt(100, 2.0), pt(100, 3.0)])
    got = decode(Inner.rasterize(bez, 0..200))
    assert Enum.at(got, 50) == 2.0
    assert Enum.at(got, 150) == 3.0
  end

  # ---- Channel integration ----

  test "Bezier works inside Chunk + Channel" do
    alias EquinoxDomain.Curve.{Chunk, Channel}
    {:ok, container} = Bezier.new(points: [pt(0, 0.0), pt(100, 1.0)])
    {:ok, chunk} = Chunk.new(adapter: Bezier, container: container, start_tick: 0)
    {:ok, channel} = Channel.new(name: :test, chunks: [chunk])
    assert channel.name == :test
    assert hd(channel.chunks).adapter == Bezier
  end
end
