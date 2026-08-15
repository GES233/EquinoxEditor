defmodule EquinoxDomain.Command.AdoptRequest do
  @moduledoc """
  采纳请求——把引擎产出构造成一条 `Coconut.Edit.Patch`（纯函数）。

  取代旧版基于 Track 聚合的 `adopt/3`（z 库时代在 domain 内直接挂载）：
  本模块只负责**构造**——显式构造锚（Ordinal / Relative，意图已知，
  无需旧式三元组匹配猜测）、经 channel 的 `projection/2`
  算出 base 并由 `Tamale.Patch.new/2` 记 digest；**挂载动作不在此层**，
  由 kernel 经 `History.run(Command.attach_patches(...))` 完成。

  digest 输入的 canonical 归一化由 channel 模块负责
  （见 `EquinoxDomain.Port.Channels.PhonemeTiming.canonicalize/1`）。
  """

  alias Coconut.Edit.{Patch, Workspace}
  alias EquinoxDomain.Port.Channel

  @typedoc """
  锚构造参数：

  - `{:ordinal, refs}` / `{:ordinal, refs, adjacent?}` — 身份锚（refs 合取）
  - `{:relative, ref, from_offset, to_offset}` — 身份 + 偏移锚
  - 已构造好的 `Tamale.Anchor.t()` 原样采用（`at_version` 覆写为轨头）
  """
  @type anchor_spec ::
          {:ordinal, [Tamale.id()]}
          | {:ordinal, [Tamale.id()], boolean()}
          | {:relative, Tamale.id(), Tamale.Coord.input(), Tamale.Coord.input()}
          | Tamale.Anchor.t()

  @doc """
  构造一条待挂载的 patch，返回 `{:ok, Coconut.Edit.Patch.t()}`。

  参数：

  - `workspace` — 当前 workspace（取轨头版本 + channel 投影输入）；
  - `channel_module` — `Coconut.Render.Channel` 实现模块
    （提供 `projection/2` 算 base_digest）；
  - `attrs` — `%{track_id, anchor, payload}`，可选 `:channel`
    （缺省取 `channel_module.channel/0`，模块未导出则以模块名为 channel）、
    `:id`（缺省 nil，挂载时由 `Workspace.attach_patch/2` 铸造）、
    `:engine`（引擎版本戳二进制，缺省 nil 不盖戳；非 nil 时经
    `Channel.stamp_base/2` 把版本戳组合进 digest base——check 侧的
    Adapter spec projection 必须用同一版本戳，否则挂载即 conflict）。

  锚的 `at_version` 一律取目标轨道的 Space 头版本（挂载点即当前 head）。
  """
  @spec build_patch(Workspace.t(), module(), map() | keyword()) ::
          {:ok, Patch.t()} | {:error, term()}
  def build_patch(%Workspace{} = workspace, channel_module, attrs)
      when is_atom(channel_module) do
    attrs = Map.new(attrs)

    with {:ok, track_id} <- fetch_key(attrs, :track_id),
         {:ok, anchor_spec} <- fetch_key(attrs, :anchor),
         {:ok, payload} <- fetch_key(attrs, :payload),
         {:ok, track} <- Workspace.fetch_track(workspace, track_id),
         {:ok, anchor} <- build_anchor(anchor_spec, track.space.version),
         {:ok, base} <- run_projection(workspace, channel_module, track_id, anchor),
         {:ok, base} <- maybe_stamp(base, attrs),
         {:ok, tamale_patch} <- Tamale.Patch.new(base, payload) do
      Patch.new(%{
        id: Map.get(attrs, :id),
        track_id: track_id,
        anchor: anchor,
        patch: tamale_patch,
        channel: channel_of(channel_module, attrs)
      })
    end
  end

  defp fetch_key(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_adopt_attr, key}}
    end
  end

  # ---- 锚构造（at_version = 轨头版本） ----

  defp build_anchor({:ordinal, refs}, at_version) when is_list(refs) and refs != [],
    do: {:ok, %Tamale.Anchor.Ordinal{refs: refs, adjacent?: false, at_version: at_version}}

  defp build_anchor({:ordinal, refs, adjacent?}, at_version)
       when is_list(refs) and refs != [] and is_boolean(adjacent?),
       do: {:ok, %Tamale.Anchor.Ordinal{refs: refs, adjacent?: adjacent?, at_version: at_version}}

  defp build_anchor({:relative, ref, from_offset, to_offset}, at_version) do
    with {:ok, from} <- Tamale.Coord.cast(from_offset),
         {:ok, to} <- Tamale.Coord.cast(to_offset) do
      {:ok,
       %Tamale.Anchor.Relative{ref: ref, from_offset: from, to_offset: to, at_version: at_version}}
    end
  end

  defp build_anchor(%_{} = anchor, at_version) do
    if anchor_in?(anchor) do
      {:ok, %{anchor | at_version: at_version}}
    else
      {:error, {:unsupported_anchor, anchor}}
    end
  end

  defp build_anchor(other, _at_version), do: {:error, {:invalid_anchor_spec, other}}

  defp anchor_in?(%Tamale.Anchor.Ordinal{}), do: true
  defp anchor_in?(%Tamale.Anchor.Relative{}), do: true
  defp anchor_in?(%Tamale.Anchor.Metric{}), do: true
  defp anchor_in?(_other), do: false

  # ---- channel 投影（shell patch 只供 projection 读 anchor / track_id） ----

  # 引擎版本戳：nil 不盖戳（向后兼容）；二进制经 Channel.stamp_base/2 组合
  defp maybe_stamp(base, attrs) do
    case Map.get(attrs, :engine) do
      nil -> {:ok, base}
      key when is_binary(key) -> {:ok, Channel.stamp_base(base, key)}
      other -> {:error, {:invalid_engine_key, other}}
    end
  end

  defp run_projection(workspace, channel_module, track_id, anchor) do
    shell = %Patch{id: nil, track_id: track_id, anchor: anchor, patch: nil, channel: nil}

    case channel_module.projection(workspace, shell) do
      {:ok, base} -> {:ok, base}
      {:error, _} = err -> err
      other -> {:error, {:invalid_projection_result, other}}
    end
  end

  defp channel_of(channel_module, attrs) do
    case Map.fetch(attrs, :channel) do
      {:ok, channel} ->
        channel

      :error ->
        if Code.ensure_loaded?(channel_module) and
             function_exported?(channel_module, :channel, 0) do
          channel_module.channel()
        else
          channel_module
        end
    end
  end
end
