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
  下标界内）在 re-patch 手势里另行校验（各 channel 的
  `Neume.Pin.Semantics.expressible?/4`，需要 probe 物化的序列长度）。

  自 `design-2026-09-pin-carriers` 批次 A 起，`adjudicate/3` 按各
  channel 的 `Neume.Pin.Semantics` 分派底料与裁决；本模块保留的
  `base_by_note/2` / `base_for/3` / `legacy_base/2` 即 legacy
  `pin_input_v1` schema 的实现，供 channel 语义模块与挂载路径委托。
  """

  alias Coconut.Edit.{Patch, Track}
  alias Neume.Pin.{Context, Semantics}
  alias Neume.Syllable

  @base_schema "pin_input_v1"

  @typedoc "逐音符输入事实底料（canonical plain map，值只用字符串/列表/nil）。"
  @type input_base :: %{optional(atom()) => term()}

  @typedoc """
  probe 物化的逐音符词内音素序列表（`%{note_id => [[lang, phone], ...]}`）。

  自 2026-09-05 起不再是签名底料；只服务于 duration pin 的可表达性
  校验（`Neume.Channels.DurationPin.expressible?/4`，经
  `Neume.Pin.Context.legacy_probe` 传入）与 Analysis 的词内下标平移。
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

  @doc """
  legacy（`pin_input_v1`）底料入口：从 Ordinal anchor 取 note_id 后等价
  `base_for/3`，声库摘要取自 `Context.voicebank_identity`。供 channel
  语义模块的 `base/4` 委托；`Context.legacy_bases` 携带批量裁决预计算
  的整轨底料时直接复用，不逐 patch 重算。非 Ordinal anchor 返回
  `{:error, {:unsupported_anchor, anchor}}`。
  """
  @spec legacy_base(Context.t(), Tamale.Anchor.t()) :: {:ok, input_base()} | {:error, term()}
  def legacy_base(%Context{legacy_bases: %{} = bases}, %Tamale.Anchor.Ordinal{
        refs: [note_id | _]
      }) do
    case Map.fetch(bases, note_id) do
      {:ok, base} -> {:ok, base}
      :error -> {:error, {:unknown_note, note_id}}
    end
  end

  def legacy_base(%Context{legacy_bases: nil} = context, %Tamale.Anchor.Ordinal{
        refs: [note_id | _]
      }),
      do: base_for(context.track, note_id, Context.voicebank_digest(context))

  def legacy_base(%Context{}, other), do: {:error, {:unsupported_anchor, other}}

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
  `resolve_stage() == :probe` 的 channel。每个 patch 经其 channel 的
  `Neume.Pin.Semantics` 分派：`describe/1` 按 payload 得出 descriptor，
  `base/4` 推导底料，再 `Tamale.Patch.resolve/2` 裁决。整轨 legacy 底料
  只推导一次，经 `Context.legacy_bases` 共享给所有 patch；channel 未完整
  实现语义回调时聚合为 `{:missing_pin_semantics, module}` 冲突 entry
  （入口校验，不抛 `UndefinedFunctionError`）。返回 `[]` 表示全部通过。
  """
  @spec adjudicate(Track.t(), %{atom() => module()}, String.t() | nil, keyword()) ::
          [conflict_entry()]
  def adjudicate(%Track{} = track, channels, voicebank_digest, opts \\ [])
      when is_map(channels) do
    probe_channels =
      for {name, module} <- channels,
          function_exported?(module, :resolve_stage, 0) and module.resolve_stage() == :probe,
          into: MapSet.new(),
          do: name

    bases = base_by_note(track, voicebank_digest)
    phonology_digest = Keyword.get(opts, :phonology_digest)

    track.patches
    |> Enum.filter(&MapSet.member?(probe_channels, &1.channel))
    |> Enum.map(
      &adjudicate_one(
        &1,
        track,
        Map.fetch!(channels, &1.channel),
        voicebank_digest,
        phonology_digest,
        bases
      )
    )
    |> Enum.reject(&is_nil/1)
  end

  defp adjudicate_one(
         %Patch{} = patch,
         %Track{} = track,
         semantics,
         voicebank_digest,
         phonology_digest,
         bases
       ) do
    if Semantics.implemented?(semantics) do
      context =
        Context.new(track, patch.track_id, voicebank_digest,
          phonology_digest: phonology_digest,
          legacy_bases: bases
        )

      with {:ok, descriptor} <- semantics.describe(patch.patch.payload),
           {:ok, fresh} <- semantics.base(context, patch.anchor, descriptor, patch.patch.payload) do
        resolve_entry(patch, fresh)
      else
        {:error, {:unknown_note, _note_id}} -> entry(patch, :identity_unavailable)
        {:error, reason} -> entry(patch, reason)
      end
    else
      entry(patch, {:missing_pin_semantics, semantics})
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
end
