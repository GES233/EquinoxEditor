defmodule EquinoxDomain.CurveTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Curve.{ControlPoint, Chunk, Cluster, Adapter}
  alias EquinoxDomain.Curve.Adapter.CatmullRom

  describe "ControlPoint" do
    test "new/1 创建控制点" do
      {:ok, cp} = ControlPoint.new(tick: 0, value: 0.5)
      assert cp.tick == 0
      assert cp.value == 0.5
    end
  end

  describe "Adapter.CatmullRom" do
    test "new/1 创建 CatmullRom container" do
      {:ok, container} = CatmullRom.new(points: [], tension: 0.5)
      assert container.points == []
      assert container.tension == 0.5
    end

    test "default 值" do
      {:ok, container} = CatmullRom.new(%{})
      assert container.points == []
      assert container.tension == 0.5
    end

    test "Inner.control_points/1 返回控制点列表" do
      {:ok, cp0} = ControlPoint.new(tick: 0, value: 0.0)
      {:ok, cp1} = ControlPoint.new(tick: 10, value: 1.0)
      {:ok, cp2} = ControlPoint.new(tick: 20, value: 0.0)
      pts = [cp0, cp1, cp2]

      {:ok, container} = CatmullRom.new(points: pts, tension: 0.5)
      assert Adapter.Inner.control_points(container) == pts
    end

    test "Inner.rasterize/2 空点列表返回全零" do
      {:ok, container} = CatmullRom.new(%{})
      result = Adapter.Inner.rasterize(container, 0..90//10)
      assert byte_size(result) == 10 * 4

      assert result ==
               <<0.0::float-32-native, 0.0::float-32-native, 0.0::float-32-native,
                 0.0::float-32-native, 0.0::float-32-native, 0.0::float-32-native,
                 0.0::float-32-native, 0.0::float-32-native, 0.0::float-32-native,
                 0.0::float-32-native>>
    end

    test "Inner.rasterize/2 单点返回常量" do
      {:ok, cp} = ControlPoint.new(tick: 0, value: 0.75)
      {:ok, container} = CatmullRom.new(points: [cp])
      result = Adapter.Inner.rasterize(container, 0..20//10)
      assert byte_size(result) == 3 * 4
      <<a::float-32-native, b::float-32-native, c::float-32-native>> = result
      assert_in_delta a, 0.75, 0.001
      assert_in_delta b, 0.75, 0.001
      assert_in_delta c, 0.75, 0.001
    end

    test "Inner.rasterize/2 线性段（tension=1.0 退化）" do
      {:ok, cp0} = ControlPoint.new(tick: 0, value: 0.0)
      {:ok, cp1} = ControlPoint.new(tick: 100, value: 1.0)
      pts = [cp0, cp1]

      {:ok, container} = CatmullRom.new(points: pts, tension: 1.0)
      result = Adapter.Inner.rasterize(container, [0, 50])

      assert byte_size(result) == 2 * 4
      <<s0::float-32-native, s1::float-32-native>> = result
      assert_in_delta s0, 0.0, 0.01
      assert_in_delta s1, 0.5, 0.01
    end

    test "Inner.rasterize/2 标准 Catmull-Rom（tension=0.5）" do
      {:ok, cp0} = ControlPoint.new(tick: 0, value: 0.0)
      {:ok, cp1} = ControlPoint.new(tick: 100, value: 1.0)
      {:ok, cp2} = ControlPoint.new(tick: 200, value: 0.0)
      pts = [cp0, cp1, cp2]

      {:ok, container} = CatmullRom.new(points: pts, tension: 0.5)
      result = Adapter.Inner.rasterize(container, [0, 100])

      assert byte_size(result) == 2 * 4
      <<s0::float-32-native, s1::float-32-native>> = result
      assert_in_delta s0, 0.0, 0.01
      assert s1 > 0.5
    end

    test "Inner.rasterize/2 边界外 clamp 到首尾值" do
      {:ok, cp0} = ControlPoint.new(tick: 50, value: 0.3)
      {:ok, cp1} = ControlPoint.new(tick: 150, value: 0.7)
      pts = [cp0, cp1]

      {:ok, container} = CatmullRom.new(points: pts)
      result = Adapter.Inner.rasterize(container, [0, 100])

      <<s0::float-32-native, s1::float-32-native>> = result
      assert_in_delta s0, 0.3, 0.01
      assert_in_delta s1, 0.5, 0.01
    end

    test "Inner.span/1 返回最后一个控制点的 tick" do
      {:ok, cp0} = ControlPoint.new(tick: 0, value: 0.0)
      {:ok, cp1} = ControlPoint.new(tick: 100, value: 1.0)
      {:ok, cp2} = ControlPoint.new(tick: 200, value: 0.0)
      pts = [cp0, cp1, cp2]

      {:ok, container} = CatmullRom.new(points: pts, tension: 0.5)
      assert Adapter.Inner.span(container) == 200
    end

    test "Inner.span/1 空曲线返回 0" do
      {:ok, container} = CatmullRom.new(%{})
      assert Adapter.Inner.span(container) == 0
    end

    test "Inner.span/1 单点返回该点 tick" do
      {:ok, cp} = ControlPoint.new(tick: 50, value: 0.5)
      {:ok, container} = CatmullRom.new(points: [cp])
      assert Adapter.Inner.span(container) == 50
    end
  end

  describe "Chunk" do
    test "new/1 创建 Chunk，关联 adapter/container" do
      {:ok, cp0} = ControlPoint.new(tick: 0, value: 0.0)
      {:ok, cp1} = ControlPoint.new(tick: 480, value: 1.0)
      pts = [cp0, cp1]

      {:ok, container} = CatmullRom.new(points: pts, tension: 0.5)

      {:ok, chunk} =
        Chunk.new(
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
      {:ok, container} = CatmullRom.new(%{})
      {:ok, chunk} = Chunk.new(adapter: CatmullRom, container: container, start_tick: 0)

      {:ok, moved} = Chunk.update(chunk, start_tick: 960)
      assert moved.start_tick == 960
      assert moved.id == chunk.id
    end

    test "update/2 拒绝修改 id" do
      {:ok, container} = CatmullRom.new(%{})
      {:ok, chunk} = Chunk.new(adapter: CatmullRom, container: container, start_tick: 0)

      assert Chunk.update(chunk, id: "fake") == {:error, :id_immutable}
    end
  end

  describe "Cluster" do
    test "new/1 创建 Cluster" do
      {:ok, channel} = Cluster.new(name: :pitch)
      assert channel.name == :pitch
      assert channel.chunks == []
      assert channel.extra == %{}
    end

    test "update/2 修改 Cluster 属性" do
      {:ok, cp} = ControlPoint.new(tick: 0, value: 0.5)
      {:ok, container} = CatmullRom.new(points: [cp])
      {:ok, chunk} = Chunk.new(adapter: CatmullRom, container: container, start_tick: 0)

      {:ok, ch} = Cluster.new(name: :pitch)
      {:ok, channel} = Cluster.update(ch, chunks: [chunk])

      assert channel.name == :pitch
      assert length(channel.chunks) == 1
      assert hd(channel.chunks).adapter == CatmullRom
    end

    test "多个 chunks，后面的覆盖前面的（z-order）" do
      {:ok, cp_a} = ControlPoint.new(tick: 0, value: 0.2)
      {:ok, cp_b} = ControlPoint.new(tick: 0, value: 0.8)

      {:ok, container_a} = CatmullRom.new(points: [cp_a])
      {:ok, container_b} = CatmullRom.new(points: [cp_b])

      {:ok, chunk_a} =
        Chunk.new(adapter: CatmullRom, container: container_a, start_tick: 0)

      {:ok, chunk_b} =
        Chunk.new(adapter: CatmullRom, container: container_b, start_tick: 0)

      {:ok, ch} = Cluster.new(name: :pitch)
      {:ok, channel} = Cluster.update(ch, chunks: [chunk_a, chunk_b])
      assert length(channel.chunks) == 2
      assert hd(Enum.reverse(channel.chunks)).container == container_b
    end
  end
end
