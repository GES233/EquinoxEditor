defmodule Neume.Identity do
  @moduledoc """
  pin 的身份底料（§6.6 第二档）：probe 物化的逐音符词内音素序列。

  底料形状：`%{note_id => [[lang, phone], ...]}`——头音符是自身 G2P（或
  显式 `metadata["phonemes"]`）的序列；生效的 melisma 续音音符是派生的
  延续元音单元素序列（音素类型是声库事实，由 worker 展开，不在此猜测）。

  裁决时机在引擎 probe（G2P/展开之后），不在静态 check：挂载与重挂
  （`Neume.Editor.mount_*/3`、`repatch/2`）用挂载时刻的有效序列签名；
  `check`/`analyze`/`render` 在 probe 之后对每个在册 pin 重新执行
  `Tamale.Patch.resolve/2`，失配聚合为 `%{kind: :conflict, stage: :probe}`
  entry，与静态冲突共用同一个冲突裁决界面。

  爆炸半径：改词、显式音素修改、melisma 晋升/断组、声库字典变化会炸；
  改音高、拖动、邻居音符编辑不会。
  """

  alias Coconut.Edit.{Patch, Track}

  @typedoc "逐音符的词内音素序列表。"
  @type note_phonemes :: %{term() => [[String.t()]]}

  @typedoc "probe 期身份冲突 entry（与静态冲突同界面，多一个 `stage` 字段）。"
  @type conflict_entry :: %{
          kind: :conflict,
          stage: :probe,
          track_id: Track.track_id(),
          patch: Patch.t(),
          channel: atom(),
          reason: term()
        }

  @doc """
  对轨道上所有 probe 期 channel 的在册 patch 做身份裁决。

  `channels` 是会话的 channel 注册表（`%{name => module}`），只裁决声明
  `resolve_stage() == :probe` 的 channel。返回 `[]` 表示全部通过。
  """
  @spec adjudicate(Track.t(), %{atom() => module()}, note_phonemes()) :: [conflict_entry()]
  def adjudicate(%Track{} = track, channels, note_phonemes)
      when is_map(channels) and is_map(note_phonemes) do
    probe_channels =
      for {name, module} <- channels,
          function_exported?(module, :resolve_stage, 0) and module.resolve_stage() == :probe,
          into: MapSet.new(),
          do: name

    track.patches
    |> Enum.filter(&MapSet.member?(probe_channels, &1.channel))
    |> Enum.map(&adjudicate_one(&1, note_phonemes))
    |> Enum.reject(&is_nil/1)
  end

  defp adjudicate_one(%Patch{} = patch, note_phonemes) do
    case patch.anchor do
      %Tamale.Anchor.Ordinal{refs: [note_id | _]} ->
        case Map.fetch(note_phonemes, note_id) do
          {:ok, fresh} -> resolve_entry(patch, fresh)
          :error -> entry(patch, :identity_unavailable)
        end

      other ->
        entry(patch, {:unsupported_anchor, other})
    end
  end

  defp resolve_entry(patch, fresh) do
    case Tamale.Patch.resolve(patch.patch, fresh) do
      {:ok, _payload} -> nil
      {:conflict, reason} -> entry(patch, reason)
      {:error, reason} -> entry(patch, reason)
    end
  end

  defp entry(patch, reason) do
    %{
      kind: :conflict,
      stage: :probe,
      track_id: patch.track_id,
      patch: patch,
      channel: patch.channel,
      reason: reason
    }
  end

  @doc """
  re-patch 的可表达性校验：payload 在新底料上仍可表达则 `:ok`。

  - `:duration`——所有 pin 下标在新序列界内；
  - `:pitch`——点是绝对 tick，不索引音素，恒可表达（span 合法性在
    消费边界复核）。
  """
  @spec expressible?(atom(), term(), [[String.t()]]) :: :ok | {:error, term()}
  def expressible?(:duration, durations, fresh) when is_list(durations) do
    Enum.reduce_while(durations, :ok, fn
      [index, _ticks], :ok when is_integer(index) and index >= 0 ->
        if index < length(fresh),
          do: {:cont, :ok},
          else: {:halt, {:error, {:phoneme_index_out_of_range, index, length(fresh)}}}

      other, :ok ->
        {:halt, {:error, {:invalid_duration_payload, other}}}
    end)
  end

  def expressible?(:pitch, _points, _fresh), do: :ok
  def expressible?(channel, _payload, _fresh), do: {:error, {:unknown_pin_channel, channel}}
end
