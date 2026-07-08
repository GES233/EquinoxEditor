defmodule EquinoxDomain.Rebase.Phoneme.Timing do
  @moduledoc """
  SVS 编辑中的音素时序修正量。

  携带用户手调的时序偏移，以引擎 adapter 生成的音素 identity 为锚。

  内部包装 `EquinoxDomain.Rebase.Patch` 实现调和。
  """

  alias EquinoxDomain.Rebase.Patch

  @type identity :: Patch.identity()
  @type delta_ms :: integer()

  @type t :: %__MODULE__{
          identity: identity(),
          onset_delta_ms: delta_ms(),
          duration_delta_ms: delta_ms()
        }

  defstruct [identity: nil, onset_delta_ms: 0, duration_delta_ms: 0]

  # ── 与泛型 Patch 互转 ──────────────────────────────

  @doc "将 Timing 修正量列表转为泛型 Patch 列表。"
  @spec to_patches([t()]) :: [Patch.t()]
  def to_patches(deltas) do
    Enum.map(deltas, fn %__MODULE__{identity: id} = d ->
      Patch.new(id, %{onset_delta_ms: d.onset_delta_ms, duration_delta_ms: d.duration_delta_ms})
    end)
  end

  @doc "将存活的 Patch 列表转回 Timing 修正量。"
  @spec from_patches([Patch.t()]) :: [t()]
  def from_patches(patches) do
    Enum.map(patches, fn %Patch{identity: id, data: data} ->
      %__MODULE__{
        identity: id,
        onset_delta_ms: Map.get(data, :onset_delta_ms, 0),
        duration_delta_ms: Map.get(data, :duration_delta_ms, 0)
      }
    end)
  end

  # ── 直接调和 ────────────────────────────────────────

  @doc """
  将时序修正量与新的 identity 列表调和。

      iex> deltas = [
      ...>   %EquinoxDomain.Rebase.Phoneme.Timing{identity: "C", onset_delta_ms: 5},
      ...>   %EquinoxDomain.Rebase.Phoneme.Timing{identity: "V1", onset_delta_ms: -3}
      ...> ]
      iex> {:ok, surviving, conflicts} = EquinoxDomain.Rebase.Phoneme.Timing.reconcile(deltas, ["C", "V3"])
      iex> hd(surviving).identity
      "C"
      iex> hd(conflicts).identity
      "V1"
  """
  @spec reconcile([t()], [identity()]) :: {:ok, [t()], [EquinoxDomain.Rebase.Conflict.t()]}
  def reconcile(deltas, new_identities) do
    patches = to_patches(deltas)
    {:ok, surviving, conflicts} = EquinoxDomain.Rebase.reconcile(patches, new_identities)
    {:ok, from_patches(surviving), conflicts}
  end

  # ── 投影应用 ────────────────────────────────────────

  @doc """
  将时序修正量应用到引擎的 base projection 上。

  `base_timing` 格式为 `%{identity => {onset_sec, duration_sec}}`。

      iex> base = %{"C" => {0.0, 0.05}, "V" => {0.05, 0.10}}
      iex> deltas = [%EquinoxDomain.Rebase.Phoneme.Timing{identity: "V", onset_delta_ms: 20}]
      iex> EquinoxDomain.Rebase.Phoneme.Timing.apply_deltas(base, deltas)["V"]
      {0.07, 0.10}
  """
  @spec apply_deltas(%{identity() => {float(), float()}}, [t()]) ::
          %{identity() => {float(), float()}}
  def apply_deltas(base_timing, deltas) do
    delta_map =
      Map.new(deltas, fn %__MODULE__{
                            identity: id,
                            onset_delta_ms: onset_delta,
                            duration_delta_ms: dur_delta
                          } ->
        {base_onset, base_dur} = Map.get(base_timing, id, {0.0, 0.100})

        resolved_onset = base_onset + onset_delta / 1000.0
        resolved_dur = max(base_dur + dur_delta / 1000.0, 0.001)

        {id, {Float.round(resolved_onset, 4), Float.round(resolved_dur, 4)}}
      end)

    Map.merge(base_timing, delta_map)
  end
end
