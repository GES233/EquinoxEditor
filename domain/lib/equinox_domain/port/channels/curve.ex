defmodule EquinoxDomain.Port.Channels.Curve do
  @moduledoc """
  通用曲线 channel（`:curve`）——连续参数（pitch / energy / …）的
  `Coconut.Render.Channel` 实现。

  单模块单 atom，兑现「新参数零 coconut/tamale 代码」：参数名在 payload
  的 `param` 字段里，channel 本体与 kernel 都不感知具体参数（ADR-004，
  参数语义是 Hook 领地）。

  ## 锚纪律（v1）

  Ordinal（整音符，refs 合取）/ Relative（音符 + tick 偏移区间）——
  笔画挂在音符上、结构死活随音符；Metric 锚拒绝
  （`{:error, :unsupported_anchor}`），同 `PhonemeTiming` 先例。

  ## base 形状（digest 守卫）

  锚区音符的 canonical 投影列表，逐音符委派
  `PhonemeTiming.base_for/2`（单一实现纪律：挂载侧 `projection/2` 与
  check 侧 Adapter spec projection 都必须汇聚到 `base_for/1`，不允许
  平行实现）。曲线数据自身的完整性由 payload 携带（coconut `Pitch`
  channel 先例：digest 只守音符本体 + span，音符内容 / 时值变化使锚区
  笔画在 check 阶段判 conflict）。

  ## Payload 形状（plain map，无 struct——patch payload 的 Pickle 原样透传）

      %{
        param: :pitch,                                   # 参数名 atom
        adapter: "Elixir.Coconut.Curve.Adapter.Bezier",  # 字符串形模块名
        points: [
          %{tick: 0, value: 60.0, handle_left: nil,
            handle_right: %{tick: 80, value: 1.5}}
        ]
      }

  `tick` 为绝对 tick、严格升序；handle 是相对锚点的偏移，可 nil
  （adapter 的自动手柄规则接管）。payload 不进 digest，float 合法；
  构造入口是 `build_payload/3`（校验在此收口）。

  resolve 后的光栅化（控制点 → `%{param, start_tick, end_tick, stride,
  samples}`）在 kernel 侧（`Equinox.Kernel.CurveRaster`），由 Adapter 的
  arity-2 spec target 闭包触发；本模块的 `target/0` 只是契约兜底
  （静态落点），实际扇出按 payload `param` 路由。
  """

  @behaviour Coconut.Render.Channel

  alias Coconut.Edit.{Patch, Track, Workspace}
  alias Coconut.Score.Note
  alias EquinoxDomain.Port.Channels.PhonemeTiming

  @channel :curve

  @doc "本 channel 的标识 atom。"
  @spec channel() :: atom()
  def channel, do: @channel

  @impl true
  @doc "契约兜底的静态落点；实际落点由 Adapter spec 的 target 按 payload `param` 扇出。"
  def target, do: {:port, :synth, @channel}

  @impl true
  @doc "产出锚区音符集的 canonical base 列表（digest 输入）。"
  def projection(%Workspace{} = ws, %Patch{} = patch) do
    with {:ok, note_ids} <- anchor_note_ids(patch.anchor),
         {:ok, track} <- Workspace.fetch_track(ws, patch.track_id),
         {:ok, notes} <- fetch_notes(track, note_ids) do
      base_for(notes)
    end
  end

  @doc """
  由 `[{note, span}]` 构造 canonical base 列表——digest base 的**单一实现**。

  逐音符委派 `PhonemeTiming.base_for/2`；挂载侧（`projection/2`，
  workspace 粒度）与 check 侧（Adapter 供给的 spec projection，
  RenderRequest 粒度）都必须汇聚到本函数，不允许平行实现
  （见 `docs/engine-adapter-design.md` Channel 本体纪律）。
  """
  @spec base_for([{Note.t(), Track.span()}]) ::
          {:ok, [Tamale.Digest.canonical()]} | {:error, term()}
  def base_for(notes_with_spans) when is_list(notes_with_spans) do
    notes_with_spans
    |> Enum.reduce_while({:ok, []}, fn {%Note{} = note, span}, {:ok, acc} ->
      case PhonemeTiming.base_for(note, span) do
        {:ok, base} -> {:cont, {:ok, [base | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, bases} -> {:ok, Enum.reverse(bases)}
      {:error, _} = err -> err
    end
  end

  # ---- payload 构造（校验收口） ----

  @doc """
  构造曲线 patch 的 payload（plain map）。

  - `param` — 参数名 atom（`:pitch` / `:energy` / …，语义由 Hook 解释）；
  - `adapter` — `Coconut.Curve.Adapter` 实现模块（须导出 `rasterize/2` 与
    `span/1`），payload 内以字符串形存储（Pickle / JSON 往返安全）；
  - `points` — 控制点列表（至少一个），`%{tick, value, handle_left,
    handle_right}`：tick 非负整数、严格升序，value 数值，handle 为
    `%{tick: integer, value: number}` 或 nil。多余键被剥离。
  """
  @spec build_payload(atom(), module(), [map()]) :: {:ok, map()} | {:error, term()}
  def build_payload(param, adapter, points) when is_list(points) do
    with :ok <- check_param(param),
         :ok <- check_adapter(adapter),
         {:ok, points} <- normalize_points(points) do
      {:ok, %{param: param, adapter: Atom.to_string(adapter), points: points}}
    end
  end

  def build_payload(_param, _adapter, other), do: {:error, {:invalid_points, other}}

  defp check_param(param) when is_atom(param) and not is_nil(param), do: :ok
  defp check_param(other), do: {:error, {:invalid_param, other}}

  defp check_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :rasterize, 2) and
         function_exported?(adapter, :span, 1) do
      :ok
    else
      {:error, {:invalid_adapter, adapter}}
    end
  end

  defp check_adapter(other), do: {:error, {:invalid_adapter, other}}

  defp normalize_points([]), do: {:error, {:invalid_points, :empty}}

  defp normalize_points(points) do
    points
    |> Enum.reduce_while({:ok, []}, fn point, {:ok, acc} ->
      case normalize_point(point) do
        {:ok, point} -> {:cont, {:ok, [point | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> check_ascending(Enum.reverse(rev))
      {:error, _} = err -> err
    end
  end

  defp normalize_point(%{} = point) do
    with {:ok, tick} <- fetch_tick(point),
         {:ok, value} <- fetch_value(point),
         {:ok, handle_left} <- fetch_handle(point, :handle_left),
         {:ok, handle_right} <- fetch_handle(point, :handle_right) do
      {:ok, %{tick: tick, value: value, handle_left: handle_left, handle_right: handle_right}}
    end
  end

  defp normalize_point(other), do: {:error, {:invalid_points, {:bad_point, other}}}

  defp fetch_tick(point) do
    case Map.get(point, :tick) do
      tick when is_integer(tick) and tick >= 0 -> {:ok, tick}
      other -> {:error, {:invalid_points, {:bad_tick, other}}}
    end
  end

  defp fetch_value(point) do
    case Map.get(point, :value) do
      value when is_number(value) -> {:ok, value}
      other -> {:error, {:invalid_points, {:bad_value, other}}}
    end
  end

  defp fetch_handle(point, key) do
    case Map.get(point, key) do
      nil ->
        {:ok, nil}

      %{tick: tick, value: value} when is_integer(tick) and is_number(value) ->
        {:ok, %{tick: tick, value: value}}

      other ->
        {:error, {:invalid_points, {:bad_handle, key, other}}}
    end
  end

  # 时间函数要求严格升序（Bezier 的 x(t) 反解依赖单调性）
  defp check_ascending(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [%{tick: a}, %{tick: b}] -> a >= b end)
    |> case do
      nil -> {:ok, points}
      [%{tick: a}, %{tick: b}] -> {:error, {:invalid_points, {:ticks_not_ascending, a, b}}}
    end
  end

  # ---- 锚 → 音符集 ----

  defp anchor_note_ids(%Tamale.Anchor.Ordinal{refs: refs}), do: {:ok, refs}
  defp anchor_note_ids(%Tamale.Anchor.Relative{ref: ref}), do: {:ok, [ref]}
  defp anchor_note_ids(_other), do: {:error, :unsupported_anchor}

  defp fetch_notes(%Track{} = track, note_ids) do
    note_ids
    |> Enum.reduce_while({:ok, []}, fn note_id, {:ok, acc} ->
      with {:ok, note} <- fetch_note(track, note_id),
           {:ok, span} <- fetch_span(track, note_id) do
        {:cont, {:ok, [{note, span} | acc]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, notes} -> {:ok, Enum.reverse(notes)}
      {:error, _} = err -> err
    end
  end

  defp fetch_note(%Track{} = track, note_id) do
    case Map.fetch(track.elements_by_id, note_id) do
      {:ok, %Note{} = note} -> {:ok, note}
      {:ok, other} -> {:error, {:not_a_note, other}}
      :error -> {:error, {:note_not_found, note_id}}
    end
  end

  defp fetch_span(%Track{} = track, note_id) do
    case Track.latest_span(track, note_id) do
      {_, _} = span -> {:ok, span}
      nil -> {:error, {:span_not_found, note_id}}
    end
  end
end
