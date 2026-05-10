defmodule EquinoxDomain.Curve.Adapter.CatmullRom do
  @moduledoc "Catmull-Rom 曲线适配器（naive 参考实现）"

  use EquinoxDomain.Curve.Adapter

  @type t :: %__MODULE__{
          points: [ControlPoint.t()],
          tension: float()
        }
  defstruct points: [], tension: 0.5

  @impl true
  def new(attrs) do
    attrs = Map.new(attrs)
    struct!(__MODULE__, attrs)
  end

  defimpl Inner, for: __MODULE__ do
    def control_points(%{points: points}), do: points

    def span(%{points: []}), do: 0
    def span(%{points: points}), do: List.last(points).tick

    def rasterize(%{points: points, tension: tension}, tick_seq) do
      points = Enum.sort_by(points, & &1.tick)

      cond do
        points == [] ->
          for _ <- tick_seq, into: <<>>, do: <<0.0::float-32-native>>

        length(points) == 1 ->
          val = hd(points).value
          for _ <- tick_seq, into: <<>>, do: <<val::float-32-native>>

        true ->
          catmull_rasterize(points, tension, tick_seq)
      end
    end

    # ---- helpers ----

    defp catmull_rasterize(points, tension, tick_seq) do
      first_tick = hd(points).tick
      last_tick = List.last(points).tick
      padded = boundary_pad(points)

      for tick <- tick_seq, into: <<>> do
        value = sample_at(padded, tension, first_tick, last_tick, tick)
        <<value::float-32-native>>
      end
    end

    # 边界填充：复制首尾控制点，保证首尾段也有完整的 P0-P3
    defp boundary_pad([p | _] = points) do
      last = List.last(points)
      [p | points] ++ [last]
    end

    # 在给定 tick 处采样
    defp sample_at(points, tension, first_tick, last_tick, tick) do
      cond do
        tick <= first_tick -> hd(points).value
        tick >= last_tick -> List.last(points).value
        true -> interpolate_segment(points, tension, tick)
      end
    end

    # 找到 tick 所在段 [P_i, P_{i+1}]，做 Catmull-Rom 插值
    defp interpolate_segment([p0, p1, p2, p3 | _], tension, tick)
         when tick >= p1.tick and tick <= p2.tick do
      span = p2.tick - p1.tick
      t = if span == 0, do: 0.0, else: (tick - p1.tick) / span
      catmull_rom(p0.value, p1.value, p2.value, p3.value, t, tension)
    end

    defp interpolate_segment([_ | rest], tension, tick) do
      interpolate_segment(rest, tension, tick)
    end

    # Catmull-Rom 插值（带 tension）
    # 使用 Hermite 基：先算切线，再做三次 Hermite 插值
    # m_i = (1 - τ) * (P_{i+1} - P_{i-1}) / 2  (均匀参数化)
    defp catmull_rom(p0, p1, p2, p3, t, tension) do
      m1 = (1.0 - tension) * (p2 - p0) / 2.0
      m2 = (1.0 - tension) * (p3 - p1) / 2.0

      t2 = t * t
      t3 = t2 * t

      h00 = 2.0 * t3 - 3.0 * t2 + 1.0
      h10 = t3 - 2.0 * t2 + t
      h01 = -2.0 * t3 + 3.0 * t2
      h11 = t3 - t2

      h00 * p1 + h10 * m1 + h01 * p2 + h11 * m2
    end
  end
end
