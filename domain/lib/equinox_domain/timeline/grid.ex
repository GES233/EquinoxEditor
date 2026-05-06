defmodule EquinoxDomain.Timeline.Grid do
  @moduledoc """
  时间线网格与量化（吸附）工具。

  负责将任意给定的游离 Tick 吸附到最近的网格线上。
  """

  # 就留个模块在这里，因为实际执行的通常是 UI 端
  # 不会波及到后台
  # 但作为编辑器语义上的功能，在这里说一下

  alias EquinoxDomain.Timeline.Tick

  @type grid_type ::
          :quarter
          | :eighth
          | :sixteenth
          | {:triplet, 4}
          | {:triplet, 8}
          | :none

  @type grid_strategy :: :nearest | :floor | :ceil

  @doc """
  将自由刻度 `raw_tick` 吸附到指定的 `grid_type` 上。

  可选 `strategy` 为 `:nearest` (四舍五入，默认), `:floor` (向下取整), `:ceil` (向上取整)。
  """
  @spec snap_tick(Tick.numeric_tick(), grid_type(), grid_strategy()) :: Tick.numeric_tick()
  def snap_tick(raw_tick, grid_type, strategy \\ :nearest)

  def snap_tick(raw_tick, :none, _strategy), do: raw_tick

  def snap_tick(raw_tick, grid_type, strategy) when raw_tick >= 0 do
    step = ticks_per_step(grid_type)

    case strategy do
      :nearest ->
        round(raw_tick / step) * step

      :floor ->
        div(raw_tick, step) * step

      :ceil ->
        # ceil 的手写实现
        rem = rem(raw_tick, step)
        if rem == 0, do: raw_tick, else: raw_tick + step - rem
    end
  end

  @doc "计算某种网格单位跨越的 Tick 数"
  @spec ticks_per_step(grid_type()) :: pos_integer()
  def ticks_per_step(:quarter), do: Tick.ticks_per_quarter_note()
  def ticks_per_step(:eighth), do: div(Tick.ticks_per_quarter_note(), 2)
  def ticks_per_step(:sixteenth), do: div(Tick.ticks_per_quarter_note(), 4)
  def ticks_per_step({:triplet, 4}), do: div(Tick.ticks_per_quarter_note() * 2, 3)
  def ticks_per_step({:triplet, 8}), do: div(Tick.ticks_per_quarter_note(), 3)

  @doc "保持音符绝对长度「被吸附」的相对吸附。"
  @spec snap_tick_relative(Tick.numeric_tick(), Tick.numeric_tick(), grid_type()) ::
          Tick.numeric_tick()
  def snap_tick_relative(raw_tick, original_tick, grid_type) do
    step = ticks_per_step(grid_type)

    delta_tick = raw_tick - original_tick

    snapped_delta = round(delta_tick / step) * step

    original_tick + snapped_delta
  end
end
