defmodule EquinoxDomain.Port.Declarations.PhonemeTiming do
  @moduledoc """
  音素时序（`:phoneme_timing`）channel 的 Declaration 实现。

  本模块是 zongzi `declaration-projection-resolution` 决策在 phoneme timing
  channel 的落地：干预携带用户手调的音素时序偏移（delta），锚定挂载音符；
  结构死活由 Anchor 策略判定，语义有效性由本模块的 snapshot/resolve 判定。

  identity 为 adapter 持有的不透明标识（原 ADR-012 语义）——
  Domain 不理解其内部结构，只做透传与 Map 键比对。

  ## Payload 形状

      %{
        range: {start_tick, end_tick},   # 挂载音符的 tick 区间（on_rebase 维护）
        deltas: [
          %{identity: term(), onset_delta_ms: integer(), duration_delta_ms: integer()}
        ]
      }

  ## 投影形状

      %{identity => {onset_sec :: float(), duration_sec :: float()}}
  """

  @behaviour Zongzi.Intervention.Declaration

  alias Zongzi.Intervention
  alias Zongzi.Score.Note

  @channel :phoneme_timing

  @doc "本 Declaration 负责的 channel。"
  @spec channel() :: atom()
  def channel, do: @channel

  @impl true
  def scope(%Intervention{payload: %{range: range}}, _scope_ctx), do: range

  @impl true
  def snapshot(projection, %Intervention{} = int) do
    Map.take(projection, delta_identities(int.payload))
  end

  @impl true
  def resolve(%Intervention{} = int, fresh_projection) do
    ids = delta_identities(int.payload)
    current = Map.take(fresh_projection, ids)

    if current == int.snapshot do
      {:ok, apply_deltas(fresh_projection, int.payload.deltas)}
    else
      {:conflict, {:snapshot_mismatch, int.snapshot, current}}
    end
  end

  # 结构 rebase 存活后，用挂载音符的当前 tick 区间刷新 payload.range。
  # 非三元组锚、note 缺失等情况原样返回——结构死活由 strategy 判，这里不重复判。
  @impl true
  def on_rebase(
        %Intervention{anchor: {_prev, current, _next}, payload: %{} = payload} = int,
        _meta,
        _timeline,
        context
      ) do
    notes_by_seq = Map.get(context, :notes_by_seq) || %{}

    case Map.fetch(notes_by_seq, current) do
      {:ok, %Note{start_tick: start_tick, duration_tick: duration_tick}} ->
        range = {start_tick, start_tick + duration_tick}
        {:ok, %{int | payload: Map.put(payload, :range, range)}}

      :error ->
        {:ok, int}
    end
  end

  def on_rebase(%Intervention{} = int, _meta, _timeline, _context), do: {:ok, int}

  # ---- 内部 ----

  defp delta_identities(%{deltas: deltas}) when is_list(deltas) do
    Enum.map(deltas, & &1.identity)
  end

  # 移植自旧 Rebase.Phoneme.Timing.apply_deltas/2：
  # onset/duration 以秒为基准加 delta（毫秒换算），duration 下限 1ms，
  # 统一 round 到小数点后 4 位（snapshot 序列化的 round-trip 归一化），
  # 最后 merge 回全量投影。
  defp apply_deltas(projection, deltas) do
    resolved =
      Map.new(deltas, fn %{
                           identity: id,
                           onset_delta_ms: onset_delta,
                           duration_delta_ms: dur_delta
                         } ->
        {base_onset, base_dur} = Map.get(projection, id, {0.0, 0.100})

        resolved_onset = base_onset + onset_delta / 1000.0
        resolved_dur = max(base_dur + dur_delta / 1000.0, 0.001)

        {id, {Float.round(resolved_onset, 4), Float.round(resolved_dur, 4)}}
      end)

    Map.merge(projection, resolved)
  end
end
