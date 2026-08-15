defmodule EquinoxDomain.Port.Channels.PhonemeTiming do
  @moduledoc """
  音素时序（`:phoneme_timing`）channel 的 `Coconut.Render.Channel` 实现。

  由旧 Declaration（`Port.Declarations.PhonemeTiming`）改写：
  干预（`Coconut.Edit.Patch`）携带用户手调的音素时序偏移（delta），
  锚定挂载音符；结构死活由 tamale transport 判定，语义有效性由
  `Tamale.Patch.resolve/2` 的 digest 零容差比对判定。

  identity 为 adapter 持有的不透明标识（原 ADR-012 语义）——
  Domain 不理解其内部结构，只做透传。

  ## Payload 形状（delta 语义沿用旧 Declaration）

      %{
        deltas: [
          %{identity: term(), onset_delta_ms: integer(), duration_delta_ms: integer()}
        ]
      }

  resolve 成功的产物即 payload 本体（coconut 模型：`Tamale.Patch.resolve/2`
  只判 digest 并原样返回 payload）；把 delta 施加到引擎新鲜投影上
  （onset/duration 以秒为基准加毫秒偏移、duration 下限 1ms、round 4 位）
  是消费方（kernel / 引擎 Hook）的职责，Domain 不再代算。

  ## 投影形状（digest base）

      %{"note" => Note.to_canonical/1 产物, "span" => [start_tick, end_tick]}

  digest 输入必须是 canonical term（无 float / struct / tuple——
  `Tamale.Digest` 拒绝），归一化职责在本模块：`canonicalize/1` 递归把
  float 转十进制字符串、atom 转字符串、tuple 转 list。
  歌词 / 音高 / span 变化都会使 base 变化，从而在 check 阶段判
  `:base_changed` 冲突——这正是旧 snapshot 比对语义在 workspace
  投影可达范围内的对应物（引擎侧音素投影本身不在 workspace 内，
  其守卫由 kernel check 阶段的投影补充）。
  """

  @behaviour Coconut.Render.Channel

  alias Coconut.Edit.{Patch, Track, Workspace}
  alias Coconut.Score.Note

  @channel :phoneme_timing

  @doc "本 channel 的标识 atom。"
  @spec channel() :: atom()
  def channel, do: @channel

  @impl true
  @doc "产出锚定音符的 canonical base slice（digest 输入）。"
  def projection(%Workspace{} = ws, %Patch{} = patch) do
    with {:ok, note_id} <- anchor_note_id(patch.anchor),
         {:ok, track} <- Workspace.fetch_track(ws, patch.track_id),
         {:ok, %Note{} = note} <- fetch_note(track, note_id),
         {:ok, {start_tick, end_tick}} <- fetch_span(track, note_id) do
      base_for(note, {start_tick, end_tick})
    end
  end

  @doc """
  由音符 + span 直接构造 canonical base——digest base 的**单一实现**。

  挂载侧（`projection/2`，workspace 粒度）与 check 侧（EngineAdapter
  供给的 spec projection，RenderRequest 粒度）都必须汇聚到本函数，
  不允许平行实现（见 `docs/engine-adapter-design.md` Channel 本体纪律）。
  """
  @spec base_for(Note.t(), {integer(), integer()}) ::
          {:ok, Tamale.Digest.canonical()} | {:error, term()}
  def base_for(%Note{} = note, {start_tick, end_tick})
      when is_integer(start_tick) and is_integer(end_tick) do
    %{"note" => Note.to_canonical(note), "span" => [start_tick, end_tick]}
    |> canonicalize()
  end

  @impl true
  @doc "resolved payload 的落点：常规 `{:port, :synth, :phoneme_timing}` 端口。"
  def target, do: {:port, :synth, @channel}

  # ---- 锚 → 音符 id ----

  defp anchor_note_id(%Tamale.Anchor.Ordinal{refs: [id | _]}), do: {:ok, id}
  defp anchor_note_id(%Tamale.Anchor.Relative{ref: id}), do: {:ok, id}
  defp anchor_note_id(_other), do: {:error, :unsupported_anchor}

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

  # ---- canonical 归一化（digest 输入纪律，本模块职责） ----

  @doc """
  递归归一化为 canonical term（`Tamale.Digest` 可接受）：

  - float → 十进制字符串；atom → 字符串；tuple → list；struct → 报错。
  - 非法 UTF-8 binary 与其余类型原样报错。
  """
  @spec canonicalize(term()) :: {:ok, Tamale.Digest.canonical()} | {:error, term()}
  def canonicalize(term), do: do_canonicalize(term)

  defp do_canonicalize(nil), do: {:ok, nil}
  defp do_canonicalize(true), do: {:ok, true}
  defp do_canonicalize(false), do: {:ok, false}
  defp do_canonicalize(i) when is_integer(i), do: {:ok, i}
  defp do_canonicalize(f) when is_float(f), do: {:ok, Float.to_string(f)}
  defp do_canonicalize(a) when is_atom(a), do: {:ok, Atom.to_string(a)}

  defp do_canonicalize(b) when is_binary(b) do
    if String.valid?(b), do: {:ok, b}, else: {:error, {:non_canonical, b}}
  end

  defp do_canonicalize(list) when is_list(list), do: map_ok(list, &do_canonicalize/1)

  defp do_canonicalize(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> map_ok(&do_canonicalize/1)

  defp do_canonicalize(%_{} = struct), do: {:error, {:non_canonical, struct}}

  defp do_canonicalize(%{} = map) do
    map_ok(Map.to_list(map), fn {key, value} ->
      with {:ok, key} <- canonicalize_key(key),
           {:ok, value} <- do_canonicalize(value) do
        {:ok, {key, value}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      {:error, _} = err -> err
    end
  end

  defp do_canonicalize(other), do: {:error, {:non_canonical, other}}

  defp canonicalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}

  defp canonicalize_key(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: {:error, {:non_canonical_key, key}}
  end

  defp canonicalize_key(key), do: {:error, {:non_canonical_key, key}}

  defp map_ok(enumerable, fun) do
    Enum.reduce_while(enumerable, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end
end
