defmodule Neume.Identity do
  @moduledoc """
  pin 的身份底料（§6.6 第二档，2026-09-05 起改为**输入事实签名**）。

  底料是 canonical plain map（`Tamale.Digest` 可直接消化；值只用
  字符串/列表/nil，不用 atom），逐音符形状：

      %{
        schema: "pin_input_v1",
        voicebank: 声库内容摘要（无则 nil）,
        lyric: 歌词,
        phonemes: 显式音素（无则 nil）,
        group: %{kind: "head"}
             | %{kind: "continuation", head: 头音符 id,
                 head_lyric: 头歌词, head_phonemes: 头显式音素}
      }

  即"决定该音符语音学身份的全部输入事实"：歌词、显式音素、生效的
  melisma 归属（续音的身份 = 头的输入事实，与 probe 展开语义一致——
  生效续音自身歌词/音素不被模型消费，不入底料）、声库内容摘要（字典
  变化随之变化）。G2P 与组合展开是引擎内部协议，不进身份层。

  爆炸半径（与签物化输出对比）：改词、显式音素修改、melisma 晋升/断组、
  声库内容变化会炸；改音高、拖动、邻居音符编辑不会。已知取舍：同音字
  改词等"输入变了但 G2P 输出不变"的编辑会假冲突，由 `repatch` 重签
  兜住；换来的是底料推导为纯函数（不跑 G2P、不调 worker），且对语言/
  声库前端中立。

  裁决时机仍在引擎 probe 之后的统一冲突界面（`stage: :probe`），但裁决
  本身只依赖 workspace 事实与声库摘要；payload 的可表达性（duration
  下标界内）在 re-patch 手势里另行校验（`expressible?/3`，需要 probe
  物化的序列长度）。
  """

  alias Coconut.Edit.{Patch, Track}
  alias Neume.Syllable

  @base_schema "pin_input_v1"

  @typedoc "逐音符输入事实底料（canonical plain map，值只用字符串/列表/nil）。"
  @type input_base :: %{optional(atom()) => term()}

  @typedoc """
  probe 物化的逐音符词内音素序列表（`%{note_id => [[lang, phone], ...]}`）。

  自 2026-09-05 起不再是签名底料；只服务于 duration pin 的可表达性
  校验（`expressible?/3`）与 Analysis 的词内下标平移。
  """
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
  派生整轨每个存活音符的输入事实底料（纯函数，不跑 G2P、不调 worker）。
  """
  @spec base_by_note(Track.t(), String.t() | nil) :: %{term() => input_base()}
  def base_by_note(%Track{} = track, voicebank_digest) do
    view = Track.view(track)
    notes = Map.new(view, fn {id, note, _span} -> {id, note} end)

    memberships =
      view
      |> Enum.map(fn {id, note, {start_tick, end_tick}} ->
        {id, start_tick, end_tick, Syllable.flagged?(note.metadata)}
      end)
      |> Syllable.derive_groups()
      |> Map.new(&{&1.id, &1})

    Map.new(view, fn {id, note, _span} ->
      {id, base(note, Map.fetch!(memberships, id), notes, voicebank_digest)}
    end)
  end

  @doc "派生单个音符的输入事实底料；音符不存活时返回 `{:error, {:unknown_note, id}}`。"
  @spec base_for(Track.t(), term(), String.t() | nil) ::
          {:ok, input_base()} | {:error, {:unknown_note, term()}}
  def base_for(%Track{} = track, note_id, voicebank_digest) do
    case base_by_note(track, voicebank_digest) do
      %{^note_id => base} -> {:ok, base}
      _other -> {:error, {:unknown_note, note_id}}
    end
  end

  # 头音符：身份 = 自身歌词/显式音素 + 声库事实。
  defp base(note, %{continuation?: false}, _notes, voicebank_digest) do
    %{
      schema: @base_schema,
      voicebank: voicebank_digest,
      lyric: note.lyric,
      phonemes: explicit_phonemes(note),
      group: %{kind: "head"}
    }
  end

  # 生效续音：身份 = 头的输入事实（延续元音由头的音素派生；续音自身歌词
  # 在生效期不被模型消费，不入底料——自身歌词编辑不炸 pin）。
  defp base(_note, %{continuation?: true, head_id: head_id}, notes, voicebank_digest) do
    head = Map.fetch!(notes, head_id)

    %{
      schema: @base_schema,
      voicebank: voicebank_digest,
      lyric: nil,
      phonemes: nil,
      group: %{
        kind: "continuation",
        head: head_id,
        head_lyric: head.lyric,
        head_phonemes: explicit_phonemes(head)
      }
    }
  end

  defp explicit_phonemes(note), do: Map.get(note.metadata || %{}, "phonemes")

  @doc """
  对轨道上所有 probe 期 channel 的在册 patch 做身份裁决。

  `channels` 是会话的 channel 注册表（`%{name => module}`），只裁决声明
  `resolve_stage() == :probe` 的 channel。返回 `[]` 表示全部通过。
  """
  @spec adjudicate(Track.t(), %{atom() => module()}, String.t() | nil) :: [conflict_entry()]
  def adjudicate(%Track{} = track, channels, voicebank_digest)
      when is_map(channels) do
    bases = base_by_note(track, voicebank_digest)

    probe_channels =
      for {name, module} <- channels,
          function_exported?(module, :resolve_stage, 0) and module.resolve_stage() == :probe,
          into: MapSet.new(),
          do: name

    track.patches
    |> Enum.filter(&MapSet.member?(probe_channels, &1.channel))
    |> Enum.map(&adjudicate_one(&1, bases))
    |> Enum.reject(&is_nil/1)
  end

  defp adjudicate_one(%Patch{} = patch, bases) do
    case patch.anchor do
      %Tamale.Anchor.Ordinal{refs: [note_id | _]} ->
        case Map.fetch(bases, note_id) do
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
  re-patch 的可表达性校验：payload 在 probe 物化序列上仍可表达则 `:ok`。

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
