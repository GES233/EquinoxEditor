defmodule Equinox.Kernel.ChannelSpecs do
  @moduledoc """
  已知 channel atom → `Configurator.channel_spec()` 的共享构造器。

  projection 一律委派 domain channel 模块的单一实现（`base_for`）再经
  `Channel.stamp_base/2` 盖引擎版本戳（单一实现纪律）；target 按 channel
  语义绑定（曲线为 arity-2 扇出：借窗口 RenderRequest 的 tempo/tpqn
  上下文经 `CurveRaster` 光栅化，落点按 payload `param` 路由）。

  供 `MCPAdapter` 等 Adapter 实现复用；测试 stub（`StubEngineAdapter`）
  刻意内联同样逻辑作零件展示，不用本模块。
  """

  alias Equinox.Kernel.{Configurator, CurveRaster}
  alias EquinoxDomain.Command.RenderRequest
  alias EquinoxDomain.Port.Channel
  alias EquinoxDomain.Port.Channels.{Curve, PhonemeTiming}

  @doc """
  构造 channel spec。`:curve` 需 `opts[:timing]`：

  - `timing: %{frame_rate, hop}` — 帧网格光栅化（`CurveRaster`）；
  - `timing: :none` — 无帧网格引擎（拼接式）：控制点 payload **原样
    透传**，Hook 消费稀疏控制点（UTAU PBS/PBW/PBY 域）；
  - 缺省 — `{:error, :missing_timing}`（防配置笔误）。

  未知 channel 报 `{:error, {:unknown_channel, atom}}`。
  """
  @spec build(atom(), binary(), keyword()) ::
          {:ok, Configurator.channel_spec()} | {:error, term()}
  def build(channel, engine_key, opts \\ [])

  def build(:phoneme_timing, engine_key, _opts) do
    {:ok,
     %{
       projection: fn %RenderRequest{} = request, patch ->
         with {:ok, note_ids} <- anchor_note_ids(patch.anchor),
              {:ok, note, span} <- fetch_note(request, hd(note_ids)),
              {:ok, base} <- PhonemeTiming.base_for(note, span) do
           {:ok, Channel.stamp_base(base, engine_key)}
         end
       end,
       target: PhonemeTiming.target()
     }}
  end

  def build(:curve, engine_key, opts) do
    case Keyword.get(opts, :timing) do
      nil ->
        {:error, :missing_timing}

      :none ->
        {:ok,
         %{
           projection: curve_projection(engine_key),
           # 透传模态：Hook 直接消费控制点 payload（含 param/adapter/points）
           target: fn payload, _request -> [{{:port, :synth, payload.param}, payload}] end
         }}

      timing ->
        {:ok,
         %{
           projection: curve_projection(engine_key),
           target: fn payload, %RenderRequest{} = request ->
             {:ok, rasterized} =
               CurveRaster.rasterize(payload, request.tempo_segments, request.tpqn, timing)

             [{{:port, :synth, payload.param}, rasterized}]
           end
         }}
    end
  end

  def build(other, _engine_key, _opts), do: {:error, {:unknown_channel, other}}

  # 曲线 spec 的 check 侧投影（挂载/check 共用 `Curve.base_for/1` 单一实现，
  # 再盖引擎版本戳）
  defp curve_projection(engine_key) do
    fn %RenderRequest{} = request, patch ->
      with {:ok, note_ids} <- anchor_note_ids(patch.anchor),
           {:ok, notes} <- fetch_notes(request, note_ids),
           {:ok, base} <- Curve.base_for(notes) do
        {:ok, Channel.stamp_base(base, engine_key)}
      end
    end
  end

  # ---- 锚 / 音符查找（RenderRequest 粒度） ----

  defp anchor_note_ids(%Tamale.Anchor.Ordinal{refs: refs}), do: {:ok, refs}
  defp anchor_note_ids(%Tamale.Anchor.Relative{ref: ref}), do: {:ok, [ref]}
  defp anchor_note_ids(_other), do: {:error, :unsupported_anchor}

  defp fetch_note(%RenderRequest{notes: notes}, note_id) do
    case Enum.find(notes, fn {id, _note, _span} -> id == note_id end) do
      {_id, note, span} -> {:ok, note, span}
      nil -> {:error, {:note_not_found, note_id}}
    end
  end

  defp fetch_notes(%RenderRequest{} = request, note_ids) do
    note_ids
    |> Enum.reduce_while({:ok, []}, fn note_id, {:ok, acc} ->
      case fetch_note(request, note_id) do
        {:ok, note, span} -> {:cont, {:ok, [{note, span} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, notes} -> {:ok, Enum.reverse(notes)}
      {:error, _} = err -> err
    end
  end
end
