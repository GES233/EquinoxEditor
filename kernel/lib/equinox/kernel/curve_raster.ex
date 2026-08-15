defmodule Equinox.Kernel.CurveRaster do
  @moduledoc """
  曲线光栅化 helper——resolve 后的控制点 payload → 帧网格采样
  `%{param, start_tick, end_tick, stride, samples}`（Hook 契约形状，
  `samples` 为 float32-native binary）。

  由 Adapter 的 arity-2 spec target 闭包调用（kernel 不感知参数名，
  ADR-004）：帧网格声明（`frame_rate` / `hop`）来自 Adapter 的
  `timing_spec`，tick↔秒换算用窗口 RenderRequest 的 `tempo_segments` +
  `tpqn`（compiled_event 自带 `start_sec` / `strategy`，切片内直接换算，
  无需完整 TempoMap）。光栅采样委派 coconut 曲线 adapter 的
  `rasterize/2`。

  float 纪律：帧网格换算与采样输出是 float 世界，但绝不进 digest——
  digest base 是 channel 的 canonical 投影（`Port.Channels.Curve`），
  与本模块无涉。
  """

  alias Coconut.Curve.ControlPoint
  alias Coconut.Score.Tempo
  alias Coconut.Score.TempoMap

  @typedoc "帧网格声明（Adapter `timing_spec` 的约定键）。"
  @type timing :: %{frame_rate: number(), hop: pos_integer()}

  @doc """
  把曲线 payload 光栅化到帧网格。

  - `payload` — `EquinoxDomain.Port.Channels.Curve.build_payload/3` 的产物
    （`%{param, adapter（字符串形模块名）, points}`，points 已按 tick 升序）；
  - `tempo_segments` — 窗口 RenderRequest 的 tempo 切片；
  - `tpqn` — RenderRequest 的 tpqn；
  - `timing` — `%{frame_rate, hop}`（帧率 fps / 帧移采样数；帧周期 =
    `hop / frame_rate` 秒）。

  帧序列覆盖 `[start_tick, end_tick]`（首末控制点）：帧 k 位于
  `start_sec + k * hop / frame_rate` 秒，末帧不超过 end_sec；零时长曲线
  出单帧。采样序列换算回绝对 tick 后交 coconut adapter 光栅化。
  """
  @spec rasterize(map(), [TempoMap.compiled_event()], pos_integer(), timing()) ::
          {:ok, map()} | {:error, term()}
  def rasterize(%{param: param, adapter: adapter, points: points}, tempo_segments, tpqn, timing)
      when is_list(points) and points != [] and is_integer(tpqn) and tpqn > 0 do
    with {:ok, adapter_module} <- cast_adapter(adapter),
         {:ok, frame_rate, hop} <- fetch_timing(timing),
         {:ok, segment} <- first_segment(tempo_segments) do
      start_tick = hd(points).tick
      end_tick = List.last(points).tick

      start_sec = tick_to_sec(tempo_segments, segment, tpqn, start_tick)
      end_sec = tick_to_sec(tempo_segments, segment, tpqn, end_tick)

      tick_seq = frame_ticks(tempo_segments, segment, tpqn, start_sec, end_sec, frame_rate, hop)

      samples =
        adapter_module.rasterize(build_container(adapter_module, points), tick_seq)

      {:ok,
       %{param: param, start_tick: start_tick, end_tick: end_tick, stride: hop, samples: samples}}
    end
  end

  def rasterize(other, _segments, _tpqn, _timing), do: {:error, {:invalid_curve_payload, other}}

  # ---- 输入归一 ----

  # payload 里 adapter 是字符串形模块名（Pickle/JSON 往返安全）；容忍 atom
  defp cast_adapter(adapter) when is_atom(adapter), do: check_adapter(adapter)

  defp cast_adapter(adapter) when is_binary(adapter) do
    adapter
    |> String.to_existing_atom()
    |> check_adapter()
  rescue
    ArgumentError -> {:error, {:invalid_adapter, adapter}}
  end

  defp cast_adapter(other), do: {:error, {:invalid_adapter, other}}

  defp check_adapter(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :rasterize, 2) do
      {:ok, module}
    else
      {:error, {:invalid_adapter, module}}
    end
  end

  defp fetch_timing(%{frame_rate: frame_rate, hop: hop})
       when is_number(frame_rate) and frame_rate > 0 and is_integer(hop) and hop > 0,
       do: {:ok, frame_rate * 1.0, hop}

  defp fetch_timing(other), do: {:error, {:invalid_timing_spec, other}}

  defp first_segment([segment | _]), do: {:ok, segment}
  defp first_segment([]), do: {:error, :empty_tempo_segments}

  # ---- 帧网格 ↔ tick 换算（切片内：start_sec + strategy 局部换算） ----

  # 帧时刻序列（秒）：start_sec 起、步长 hop/frame_rate、不超过 end_sec；
  # 零时长出单帧（起点）。再逐帧换算回绝对 tick
  defp frame_ticks(segments, first, tpqn, start_sec, end_sec, frame_rate, hop) do
    period = hop / frame_rate
    n_frames = max(1, floor((end_sec - start_sec) / period) + 1)

    for k <- 0..(n_frames - 1) do
      sec_to_tick(segments, first, tpqn, start_sec + k * period)
    end
  end

  defp tick_to_sec(segments, first, tpqn, tick) do
    segment = find_by_tick(segments, first, tick)
    segment.start_sec + Tempo.tick_to_sec(segment.strategy, tick - segment.start_pos, tpqn)
  end

  defp sec_to_tick(segments, first, tpqn, sec) do
    segment = find_by_sec(segments, first, tpqn, sec)
    segment.start_pos + Tempo.sec_to_tick(segment.strategy, sec - segment.start_sec, tpqn)
  end

  # 切片缺头（窗口起点落在段中间时 slice 仍从覆盖段起）或越界时回落
  # 首/末段——换算公式对段外输入依然成立（同一 strategy 外推）
  defp find_by_tick(segments, first, tick) do
    Enum.find(segments, first, fn segment ->
      tick >= segment.start_pos and
        (not is_integer(segment.end_pos) or tick < segment.end_pos)
    end)
  end

  defp find_by_sec(segments, first, tpqn, sec) do
    Enum.find(segments, first, fn segment ->
      duration = Tempo.duration_sec(segment.strategy, tpqn)
      sec >= segment.start_sec and (duration == :infinity or sec < segment.start_sec + duration)
    end)
  end

  # ---- 控制点 → coconut adapter container ----

  defp build_container(adapter_module, points) do
    struct(adapter_module, points: Enum.map(points, &build_point/1))
  end

  defp build_point(%{tick: tick, value: value, handle_left: left, handle_right: right}) do
    %ControlPoint{
      tick: tick,
      value: value * 1.0,
      handle_left: build_handle(left),
      handle_right: build_handle(right)
    }
  end

  defp build_handle(nil), do: nil

  defp build_handle(%{tick: tick, value: value}),
    do: %{tick: tick, value: value * 1.0}
end
