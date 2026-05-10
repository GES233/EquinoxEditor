defmodule EquinoxDomain.CurveTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Curve.{ControlPoint, Chunk, Channel, Adapter}
  alias EquinoxDomain.Curve.Adapter.CatmullRom

  describe "ControlPoint" do
    test "new/1 创建控制点" do
      cp = ControlPoint.new(tick: 0, value: 0.5)
      assert cp.tick == 0
      assert cp.value == 0.5
    end
  end

  describe "Adapter.CatmullRom" do
    test "new/1 创建 CatmullRom container" do
      container = CatmullRom.new(points: [], tension: 0.5)
      assert container.points == []
      assert container.tension == 0.5
    end

    test "default 值" do
      container = CatmullRom.new(%{})
      assert container.points == []
      assert container.tension == 0.5
    end

    test "Inner.control_points/1 返回控制点列表" do
      pts = [
        ControlPoint.new(tick: 0, value: 0.0),
        ControlPoint.new(tick: 10, value: 1.0),
        ControlPoint.new(tick: 20, value: 0.0)
      ]

      container = CatmullRom.new(points: pts, tension: 0.5)
      assert Adapter.Inner.control_points(container) == pts
    end

    test "Inner.rasterize/2 空点列表返回全零" do
      container = CatmullRom.new(%{})
      result = Adapter.Inner.rasterize(container, 0..90//10)
      assert byte_size(result) == 10 * 4
      assert result == <<0.0::float-32-native, 0.0::float-32-native, 0.0::float-32-native,
                         0.0::float-32-native, 0.0::float-32-native, 0.0::float-32-native,
                         0.0::float-32-native, 0.0::float-32-native, 0.0::float-32-native,
                         0.0::float-32-native>>
    end

    test "Inner.rasterize/2 单点返回常量" do
      container = CatmullRom.new(points: [ControlPoint.new(tick: 0, value: 0.75)])
      result = Adapter.Inner.rasterize(container, 0..20//10)
      assert byte_size(result) == 3 * 4
      <<a::float-32-native, b::float-32-native, c::float-32-native>> = result
      assert_in_delta a, 0.75, 0.001
      assert_in_delta b, 0.75, 0.001
      assert_in_delta c, 0.75, 0.001
    end

    test "Inner.rasterize/2 线性段（tension=1.0 退化）" do
      pts = [
        ControlPoint.new(tick: 0, value: 0.0),
        ControlPoint.new(tick: 100, value: 1.0)
      ]

      container = CatmullRom.new(points: pts, tension: 1.0)
      result = Adapter.Inner.rasterize(container, [0, 50])

      # 2 个样本：tick=0 和 tick=50
      # tension=1.0 → 切线归零，Hermite S 曲线
      # tick=0: P=0.0, tick=50: P=(2*0.125-3*0.25+1)*0 + (0.125-0.25)*(1-0)/2*0 + (-0.25+0.75)*1 = 0.5
      assert byte_size(result) == 2 * 4
      <<s0::float-32-native, s1::float-32-native>> = result
      assert_in_delta s0, 0.0, 0.01
      assert_in_delta s1, 0.5, 0.01
    end

    test "Inner.rasterize/2 标准 Catmull-Rom（tension=0.5）" do
      pts = [
        ControlPoint.new(tick: 0, value: 0.0),
        ControlPoint.new(tick: 100, value: 1.0),
        ControlPoint.new(tick: 200, value: 0.0)
      ]

      container = CatmullRom.new(points: pts, tension: 0.5)
      result = Adapter.Inner.rasterize(container, [0, 100])

      # 2 个样本：tick=0 和 tick=100
      assert byte_size(result) == 2 * 4
      <<s0::float-32-native, s1::float-32-native>> = result
      assert_in_delta s0, 0.0, 0.01
      # 中点应 > 0.5（Catmull-Rom 过冲特性）
      assert s1 > 0.5
    end

    test "Inner.rasterize/2 边界外 clamp 到首尾值" do
      pts = [
        ControlPoint.new(tick: 50, value: 0.3),
        ControlPoint.new(tick: 150, value: 0.7)
      ]

      container = CatmullRom.new(points: pts)
      result = Adapter.Inner.rasterize(container, [0, 100])

      # tick=0 (clamp to first) 和 tick=100 (中点)
      <<s0::float-32-native, s1::float-32-native>> = result
      assert_in_delta s0, 0.3, 0.01
      assert_in_delta s1, 0.5, 0.01
    end
test "Inner.span/1 返回最后一个控制点的 tick" do
      pts = [
        ControlPoint.new(tick: 0, value: 0.0),
        ControlPoint.new(tick: 100, value: 1.0),
        ControlPoint.new(tick: 200, value: 0.0)
      ]

      container = CatmullRom.new(points: pts, tension: 0.5)
      assert Adapter.Inner.span(container) == 200
    end

    test "Inner.span/1 空曲线返回 0" do
      container = CatmullRom.new(%{})
      assert Adapter.Inner.span(container) == 0
    end

    test "Inner.span/1 单点返回该点 tick" do
      container = CatmullRom.new(points: [ControlPoint.new(tick: 50, value: 0.5)])
      assert Adapter.Inner.span(container) == 50
    end

  end

  describe "Chunk" do
    test "new/1 创建 Chunk，关联 adapter/container" do
      pts = [
        ControlPoint.new(tick: 0, value: 0.0),
        ControlPoint.new(tick: 480, value: 1.0)
      ]

      container = CatmullRom.new(points: pts, tension: 0.5)
      chunk = Chunk.new(
        adapter: CatmullRom,
        container: container,
        start_tick: 960
      )

      assert is_binary(chunk.id)
      assert String.starts_with?(chunk.id, "CurveChunk_")
      assert chunk.adapter == CatmullRom
      assert chunk.container == container
      assert chunk.start_tick == 960
      assert chunk.rasterized == nil
      assert chunk.extra == %{}
    end

    test "update/2 修改 Chunk 属性（id 不可变）" do
      container = CatmullRom.new(%{})
      chunk = Chunk.new(adapter: CatmullRom, container: container, start_tick: 0)

      {:ok, moved} = Chunk.update(chunk, start_tick: 960)
      assert moved.start_tick == 960
      assert moved.id == chunk.id
    end

    test "update/2 拒绝修改 id" do
      container = CatmullRom.new(%{})
      chunk = Chunk.new(adapter: CatmullRom, container: container, start_tick: 0)

      assert Chunk.update(chunk, id: "fake") == {:error, :id_immutable}
    end
  end

  describe "Channel" do
    test "new/1 创建 Channel" do
      channel = Channel.new(name: :pitch)
      assert channel.name == :pitch
      assert channel.chunks == []
      assert channel.extra == %{}
    end

    test "update/2 修改 Channel 属性" do
      pts = [ControlPoint.new(tick: 0, value: 0.5)]
      container = CatmullRom.new(points: pts)
      chunk = Chunk.new(adapter: CatmullRom, container: container, start_tick: 0)

      channel =
        Channel.new(name: :pitch)
        |> Channel.update(chunks: [chunk])

      assert channel.name == :pitch
      assert length(channel.chunks) == 1
      assert hd(channel.chunks).adapter == CatmullRom
    end

    test "多个 chunks，后面的覆盖前面的（z-order）" do
      pts_a = [ControlPoint.new(tick: 0, value: 0.2)]
      pts_b = [ControlPoint.new(tick: 0, value: 0.8)]

      chunk_a = Chunk.new(adapter: CatmullRom, container: CatmullRom.new(points: pts_a),
                          start_tick: 0)
      chunk_b = Chunk.new(adapter: CatmullRom, container: CatmullRom.new(points: pts_b),
                          start_tick: 0)

      channel = Channel.update(Channel.new(name: :pitch), chunks: [chunk_a, chunk_b])
      assert length(channel.chunks) == 2
      # 第二个覆盖第一个（z-order）
      assert hd(Enum.reverse(channel.chunks)).container == chunk_b.container
    end
  end
end
