defmodule Neume.PitchCurve do
  @moduledoc """
  Pitch pin 的版本化曲线 payload 与宿主侧栅格化。

  曲线仍是 identity-base Patch。legacy `pitch_curve_v1` 的绝对 tick 既是
  曲线坐标，也是失效展示与 re-patch 定位信息；批次 E 的 `pitch_curve_v2`
  envelope 把 anchor 改为音符内相对 tick（`note_tick`），handle 保持相对
  anchor 的偏移语义，签 `score_region_v1` 底料（见
  `design-2026-09-pin-carriers` 批次 E）。Bezier 只描述 payload 的连续化
  方式，不改变 base 语义。
  """

  alias Coconut.Curve.Adapter.Bezier
  alias Coconut.Curve.ControlPoint
  alias Coconut.Score.TempoMap
  alias Neume.Pin.Schema

  @format :pitch_curve_v1
  @pitch_curve_v2 Schema.pitch_curve_v2()
  @note_tick Schema.note_tick()

  @type payload :: %{
          format: :pitch_curve_v1,
          adapter: :bezier,
          coord: :absolute_tick,
          value: :absolute_midi,
          points: [map()]
        }

  @doc "把 Coconut Bezier 容器降为可 Pickle 的 plain-map payload。"
  @spec from_bezier(Bezier.t()) :: {:ok, payload()} | {:error, term()}
  def from_bezier(%Bezier{points: points}) when is_list(points) do
    with {:ok, points} <- normalize_points(points) do
      {:ok,
       %{
         format: @format,
         adapter: :bezier,
         coord: :absolute_tick,
         value: :absolute_midi,
         points: points
       }}
    end
  end

  def from_bezier(other), do: {:error, {:invalid_pitch_curve, other}}

  @doc "兼容旧 `[[tick, midi]]` payload，并校验新版 Bezier envelope。"
  @spec normalize(term()) :: {:ok, list() | payload()} | {:error, term()}
  def normalize(points) when is_list(points) do
    case normalize_legacy(points) do
      {:ok, points} -> {:ok, points}
      {:error, _} -> {:error, {:invalid_pitch_points, points}}
    end
  end

  def normalize(%{
        format: @format,
        adapter: :bezier,
        coord: :absolute_tick,
        value: :absolute_midi,
        points: points
      }) do
    with {:ok, points} <- normalize_points(points) do
      {:ok,
       %{
         format: @format,
         adapter: :bezier,
         coord: :absolute_tick,
         value: :absolute_midi,
         points: points
       }}
    end
  end

  def normalize(other), do: {:error, {:invalid_pitch_curve_payload, other}}

  @doc """
  把绝对 tick 的 Bezier 曲线换算为 `pitch_curve_v2` envelope（批次 E）。

  入参为 `Coconut.Curve.Adapter.Bezier` struct 或 legacy `pitch_curve_v1`
  plain map；anchor 按 `start_tick`（锚定音符 span 起点）换算为音符内相对
  tick（`offset_tick`），handle 保持相对 anchor 的偏移语义不变。
  """
  @spec to_v2(Bezier.t() | payload(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def to_v2(curve, start_tick) when is_integer(start_tick) and start_tick >= 0 do
    with {:ok, %{adapter: :bezier, points: points}} <- normalize_absolute(curve) do
      {:ok,
       Schema.pitch_curve_v2_payload(
         Enum.map(points, fn point ->
           %{
             offset_tick: point.tick - start_tick,
             value: point.value,
             handle_left: point.handle_left,
             handle_right: point.handle_right
           }
         end)
       )}
    end
  end

  def to_v2(curve, start_tick),
    do: {:error, {:invalid_pitch_curve_v2_origin, curve, start_tick}}

  # 绝对 tick 输入归一：Bezier struct 先降为 legacy plain map，再走版本化校验。
  defp normalize_absolute(%Bezier{} = curve), do: from_bezier(curve)
  defp normalize_absolute(%{format: @format} = payload), do: normalize(payload)
  defp normalize_absolute(other), do: {:error, {:invalid_pitch_curve, other}}

  @doc "校验并规范 `pitch_curve_v2` envelope（批次 E）。"
  @spec normalize_v2(term()) :: {:ok, map()} | {:error, term()}
  def normalize_v2(%{
        schema: @pitch_curve_v2,
        coordinates: @note_tick,
        adapter: "bezier",
        points: points
      })
      when is_list(points) do
    with {:ok, points} <- normalize_v2_points(points) do
      {:ok, Schema.pitch_curve_v2_payload(points)}
    end
  end

  def normalize_v2(other), do: {:error, {:invalid_pitch_curve_v2, other}}

  @doc """
  返回 v2 envelope 的绝对 tick/MIDI anchor 点列（展示与 span 校验用）。

  `start_tick` 是锚定音符的 span 起点；越界 offset 原样平移，合法性判定
  归消费边界与 channel 语义（与点列 v2 lowering 同原则）。
  """
  @spec display_points_v2(term(), non_neg_integer()) ::
          {:ok, [[number()]]} | {:error, term()}
  def display_points_v2(payload, start_tick)
      when is_integer(start_tick) and start_tick >= 0 do
    with {:ok, %{points: points}} <- normalize_v2(payload) do
      {:ok, Enum.map(points, &[start_tick + &1.offset_tick, &1.value])}
    end
  end

  defp normalize_v2_points(points) do
    Enum.reduce_while(points, {:ok, []}, fn point, {:ok, acc} ->
      case normalize_v2_point(point) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :empty_pitch_curve}
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.sort_by(& &1.offset_tick)}
      {:error, _} = error -> error
    end
  end

  defp normalize_v2_point(%{offset_tick: offset, value: value} = point)
       when is_integer(offset) and is_number(value) do
    with {:ok, left} <- normalize_handle(Map.get(point, :handle_left)),
         {:ok, right} <- normalize_handle(Map.get(point, :handle_right)) do
      {:ok,
       %{
         offset_tick: offset,
         value: value * 1.0,
         handle_left: left,
         handle_right: right
       }}
    end
  end

  defp normalize_v2_point(point), do: {:error, {:invalid_pitch_control_point, point}}

  @doc "返回 payload 中用于展示和 span 校验的绝对 tick/MIDI 控制点。"
  @spec display_points(term()) :: {:ok, [[number()]]} | {:error, term()}
  def display_points(points) when is_list(points), do: normalize_legacy(points)

  def display_points(%{format: @format, adapter: :bezier, points: points}) do
    with {:ok, normalized} <- normalize_points(points) do
      {:ok, Enum.map(normalized, &[&1.tick, &1.value])}
    end
  end

  def display_points(other), do: {:error, {:invalid_pitch_curve_payload, other}}

  @doc "在给定绝对 tick 序列上栅格化 Bezier payload。"
  @spec rasterize_ticks(term(), [number()]) :: {:ok, [float()]} | {:error, term()}
  def rasterize_ticks(payload, ticks) when is_list(ticks) do
    with {:ok, %{adapter: :bezier, points: points}} <- normalize(payload) do
      curve = %Bezier{points: Enum.map(points, &to_control_point/1)}
      {:ok, for(<<value::float-native-32 <- Bezier.rasterize(curve, ticks)>>, do: value)}
    else
      {:ok, _legacy} -> {:error, :not_bezier_payload}
      {:error, _} = error -> error
    end
  end

  @doc """
  把 payload 投影为 worker 既有的 `[[seconds, midi]]` 输入。

  旧 payload 只做 tick→seconds；Bezier 在真实声学帧对应的绝对 tick 上由
  Coconut adapter 栅格化，再逐帧送入 worker，Python 不拥有第二套曲线语义。
  """
  @spec to_worker_points(term(), map(), map(), number(), number()) ::
          {:ok, [[number()]]} | {:error, term()}
  def to_worker_points(payload, note, snapshot, origin_sec, frame_rate) do
    with {:ok, normalized} <- normalize(payload),
         :ok <- validate_inside(normalized, note) do
      project(normalized, note, snapshot, origin_sec, frame_rate)
    end
  end

  defp project(points, _note, snapshot, origin_sec, _frame_rate) when is_list(points) do
    {:ok,
     Enum.map(points, fn [tick, midi] ->
       seconds = 0.5 + (tick_to_sec(snapshot, tick) - origin_sec)
       [seconds, midi]
     end)}
  end

  defp project(%{adapter: :bezier, points: points}, note, snapshot, origin_sec, frame_rate)
       when is_number(frame_rate) and frame_rate > 0 do
    first_frame = round((0.5 + note.start_sec - origin_sec) * frame_rate)
    last_frame = max(first_frame, round((0.5 + note.end_sec - origin_sec) * frame_rate) - 1)
    frames = Enum.to_list(first_frame..last_frame)

    ticks =
      Enum.map(frames, fn frame ->
        absolute_sec = origin_sec + frame / frame_rate - 0.5
        sec_to_tick(snapshot, absolute_sec)
      end)

    curve = %Bezier{points: Enum.map(points, &to_control_point/1)}
    values = for <<value::float-native-32 <- Bezier.rasterize(curve, ticks)>>, do: value

    {:ok,
     Enum.zip_with(frames, values, fn frame, midi ->
       [frame / frame_rate, midi * 1.0]
     end)}
  end

  defp project(%{adapter: :bezier}, _note, _snapshot, _origin_sec, frame_rate),
    do: {:error, {:invalid_frame_rate, frame_rate}}

  defp validate_inside(payload, note) do
    with {:ok, points} <- display_points(payload) do
      case Enum.find(points, fn [tick, _midi] ->
             tick < note.start_tick or tick >= note.end_tick
           end) do
        nil -> :ok
        [tick, _] -> {:error, {:pitch_point_outside_note, note.id, tick}}
      end
    end
  end

  defp normalize_legacy(points) do
    Enum.reduce_while(points, {:ok, []}, fn
      [tick, midi], {:ok, acc} when is_integer(tick) and is_number(midi) ->
        {:cont, {:ok, [[tick, midi * 1.0] | acc]}}

      _point, _acc ->
        {:halt, {:error, :invalid_point}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = error -> error
    end
  end

  defp normalize_points(points) do
    Enum.reduce_while(points, {:ok, []}, fn point, {:ok, acc} ->
      case normalize_point(point) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :empty_pitch_curve}
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.sort_by(& &1.tick)}
      {:error, _} = error -> error
    end
  end

  defp normalize_point(%ControlPoint{} = point) do
    normalize_point(%{
      tick: point.tick,
      value: point.value,
      handle_left: point.handle_left,
      handle_right: point.handle_right
    })
  end

  defp normalize_point(%{tick: tick, value: value} = point)
       when is_integer(tick) and tick >= 0 and is_number(value) do
    with {:ok, left} <- normalize_handle(Map.get(point, :handle_left)),
         {:ok, right} <- normalize_handle(Map.get(point, :handle_right)) do
      {:ok,
       %{
         tick: tick,
         value: value * 1.0,
         handle_left: left,
         handle_right: right
       }}
    end
  end

  defp normalize_point(point), do: {:error, {:invalid_pitch_control_point, point}}

  defp normalize_handle(nil), do: {:ok, nil}

  defp normalize_handle(%{tick: tick, value: value})
       when is_integer(tick) and is_number(value),
       do: {:ok, %{tick: tick, value: value * 1.0}}

  defp normalize_handle(handle), do: {:error, {:invalid_pitch_handle, handle}}

  defp to_control_point(point), do: struct(ControlPoint, point)

  defp tick_to_sec(%{tempo_map: nil, tpqn: tpqn}, tick), do: tick / (tpqn * 2.0)
  defp tick_to_sec(%{tempo_map: tempo_map}, tick), do: TempoMap.tick_to_sec(tempo_map, tick)

  defp sec_to_tick(%{tempo_map: nil, tpqn: tpqn}, sec), do: sec * tpqn * 2.0
  defp sec_to_tick(%{tempo_map: tempo_map}, sec), do: TempoMap.sec_to_tick(tempo_map, sec)
end
