defmodule Neume.DebugExport do
  @moduledoc """
  调试导出：把一条 Track 的分析数据打包成 debug.json（`tools/plot_render.py`
  消费的 schema），供 matplotlib 画钢琴卷帘 + pitch + 音素时序面板。

  Track 维度 + 可选 `span`（tick 区间）裁剪，为多轨适配预留；`meta.patches`
  携带存活 pin 的锚点投影（kind/refs/at_version + 解析出的 tick 区间）与
  payload，`curves` 是 pitch intervention 控制点的绝对 MIDI 投影。

  帧网约定：`frames` / `phonemes` 一律落在**歌曲时间轴**上（与 notes、
  tempos 同轴）。`Analysis`/`RenderArtifact` 内部的「绝对帧」是制品音频轴
  （wav t=0 ↔ 歌曲 −lead_in），导出时按 `origin_sec − lead_in_sec` 平移
  回歌曲轴，因此 `meta.frames_origin_frame` 通常为负（lead-in 段落在歌曲
  0 点之前）。pitch payload 使用绝对 tick → MIDI：既兼容旧稀疏折线，也
  支持版本化 Bezier 控制点；`curves` 投影 anchor 点供兼容可视化，完整
  handle 保留在 `meta.patches[].payload`。

  运行时产物，不进工程文件和编辑历史。
  """

  alias Coconut.Render.Engine.Snapshot
  alias Coconut.Score.Key
  alias Neume.Analysis

  @typedoc "导出选项：`:span` tick 区间裁剪；`:raw` 无干预对照 probe 结果。"
  @type opts :: [span: {integer(), integer()} | nil, raw: Analysis.t() | nil]

  @doc """
  组装 Jason 可编码的 debug 数据（纯函数，不写文件）。

  `snapshot` 提供音符 tick/音高与 tempo map；`analysis` 是有效（含 pin）
  probe；`patches` 是该轨存活 patch 列表（`Coconut.Edit.Patch.t()`）。
  """
  @spec build(Snapshot.t(), term(), Analysis.t(), [Coconut.Edit.Patch.t()], opts()) ::
          {:ok, map()} | {:error, term()}
  def build(%Snapshot{} = snapshot, track_id, %Analysis{} = analysis, patches, opts \\ []) do
    with {:ok, view} <- fetch_view(snapshot, track_id),
         {:ok, tempo_map} <- tempo_map_of(snapshot) do
      span = Keyword.get(opts, :span)
      raw = Keyword.get(opts, :raw)
      fps = effective_fps(analysis, tempo_map)
      shift = frame_shift(analysis, fps)

      patches =
        Enum.filter(patches, fn p -> span_overlaps?(resolved_span(p.anchor, view), span) end)

      frames = frames_axis(analysis, shift, view, span, tempo_map, fps)

      frames_raw =
        raw && frames_axis(raw, frame_shift(raw, fps), view, span, tempo_map, fps)

      notes =
        view.elements
        |> Enum.filter(fn {_id, _note, {s, e}} -> overlap?({s, e}, span) end)
        |> Enum.map(&note_entry(&1, tempo_map))

      {:ok,
       %{
         meta: %{
           format: "neume-debug/1",
           sample_rate: analysis.sample_rate,
           hop_size: analysis.hop_size,
           frame_rate: Float.round(fps * 1.0, 4),
           tpqn: tempo_map.tpqn,
           tempos: tempos_json(tempo_map),
           total_frames: length(frames.midi),
           # 歌曲轴右边界，而非数组时长；负 origin 的 lead-in 不应在右侧重复。
           total_sec: Float.round((frames.origin + length(frames.midi)) / fps, 4),
           frames_origin_frame: frames.origin,
           lead_in_sec: analysis.lead_in_sec,
           origin_sec: analysis.origin_sec,
           span: span_json(span, tempo_map),
           patches: Enum.map(patches, &patch_json(&1, view))
         },
         notes: notes,
         frames: Map.take(frames, [:midi, :f0_hz]),
         frames_raw: frames_raw && Map.take(frames_raw, [:midi, :f0_hz]),
         phonemes: phonemes_json(analysis.phonemes, shift, fps, span, tempo_map),
         phonemes_raw:
           raw &&
             phonemes_json(raw.phonemes, frame_shift(raw, fps), fps, span, tempo_map),
         curves: curves_json(patches, view, span)
       }}
    end
  end

  @doc "编码并写入 JSON 文件。"
  @spec write!(map(), Path.t()) :: Path.t()
  def write!(data, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data))
    path
  end

  # ---- 内部 ----

  defp fetch_view(%Snapshot{tracks: tracks}, track_id) do
    case Map.fetch(tracks, track_id) do
      {:ok, view} -> {:ok, view}
      :error -> {:error, {:unknown_track, track_id}}
    end
  end

  # 真实管线：声学帧率 = sample_rate/hop；mock 的 frame_rate 字段语义是
  # 「帧/拍」（tpqn/ticks_per_frame），换算帧/秒要乘首段 bpm/60。
  defp effective_fps(%Analysis{sample_rate: sr, hop_size: hop}, _tempo_map)
       when is_integer(sr) and is_integer(hop),
       do: sr / hop

  defp effective_fps(%Analysis{frame_rate: frames_per_beat}, tempo_map) do
    %{strategy: %{bpm: bpm}} = elem(tempo_map.segments, 0)
    frames_per_beat * bpm / 60
  end

  # 制品音频轴 → 歌曲轴：局部帧 0 对应歌曲 origin_sec − lead_in_sec。
  defp frame_shift(%Analysis{origin_sec: origin, lead_in_sec: lead_in}, fps),
    do: round((origin - lead_in) * fps)

  # snapshot.tempo_map 在 tempo 轨为空时为 nil（coconut 约定：引擎用自己的
  # 兜底）——导出与 DiffSinger 对齐，退化为 120 BPM 平直 tempo。
  defp tempo_map_of(%Snapshot{tempo_map: %Coconut.Score.TempoMap{} = map}), do: {:ok, map}

  defp tempo_map_of(%Snapshot{tpqn: tpqn}) do
    Coconut.Score.TempoMap.compile(
      [{0, %Coconut.Score.Tempo.Event{module: Coconut.Score.Tempo.Step, context: %{bpm: 120.0}}}],
      tpqn: tpqn
    )
  end

  # 歌曲帧轴上的 pitch 序列：真实管线用模型预测；mock（pitch_pred_midi 为空）
  # 退化为按音符平铺的确定性栅格。轴第 0 元素 = min(0, shift)，lead-in 段
  # 落在歌曲 0 点之前时也能表达。
  #
  # 遮罩：pitch 模型在无发声帧（SP/AP/EP、音符间隙、尾部拖尾）上的输出
  # 无界不可视——只保留 note_id 非空的音素覆盖帧。
  defp frames_axis(%Analysis{} = analysis, shift, view, span, tempo_map, fps) do
    pred = analysis.pitch_pred_midi

    {origin, values} =
      if pred == [] do
        rasterize_mock(view, analysis.total_frames, shift, fps, tempo_map)
      else
        {shift, Enum.map(pred, &Float.round(&1 * 1.0, 3))}
      end

    axis0 = min(0, origin)
    padded = List.duplicate(nil, origin - axis0) ++ values

    {lo, hi} = frame_window(span, tempo_map, fps, axis0, length(padded))
    sliced = Enum.slice(padded, lo - axis0, hi - lo)
    masked = mask_voiced(sliced, lo, analysis.phonemes, shift)

    %{
      origin: lo,
      midi: masked,
      f0_hz: Enum.map(masked, &midi_to_f0/1)
    }
  end

  # 按音素归属遮罩：boundaries 平铺整条时间线，note_id 为 nil 的段
  # （lead-in/间隙/尾部的 SP 系）上的预测值置 nil。线性双指针。
  defp mask_voiced(values, first_frame, boundaries, shift) do
    voiced =
      boundaries
      |> Enum.filter(& &1.note_id)
      |> Enum.map(fn b -> {b.start_frame + shift, b.end_frame + shift} end)
      |> Enum.sort()

    {masked, _rest} =
      Enum.map_reduce(Enum.with_index(values), voiced, fn {value, index}, ranges ->
        frame = first_frame + index
        ranges = Enum.drop_while(ranges, fn {_s, e} -> frame >= e end)

        case ranges do
          [{s, e} | _] when frame >= s and frame < e -> {value, ranges}
          _ -> {nil, ranges}
        end
      end)

    masked
  end

  defp rasterize_mock(view, total_frames, shift, fps, tempo_map) do
    # mock 帧网 = tick/ticks_per_frame；tick→frame 由 tempo map 线性换算。
    midis =
      Map.new(view.elements, fn {id, note, {s, e}} ->
        {id, {tick_frame(s, fps, tempo_map), tick_frame(e, fps, tempo_map), midi_of(note)}}
      end)

    values =
      Enum.map(0..(total_frames - 1), fn f ->
        abs = f + shift

        Enum.find_value(midis, fn
          {_id, {sf, ef, midi}} when abs >= sf and abs < ef -> midi
          _ -> nil
        end)
      end)

    {shift, values}
  end

  defp tick_frame(tick, fps, tempo_map),
    do: round(Coconut.Score.TempoMap.tick_to_sec(tempo_map, tick) * fps)

  defp frame_window(nil, _tempo_map, _fps, axis0, len), do: {axis0, axis0 + len}

  defp frame_window({s, e}, tempo_map, fps, axis0, len) do
    lo = tick_frame(s, fps, tempo_map)
    hi = tick_frame(e, fps, tempo_map)
    {max(lo, axis0), min(hi, axis0 + len)}
  end

  defp midi_to_f0(nil), do: nil
  defp midi_to_f0(midi), do: Float.round(440.0 * :math.pow(2.0, (midi - 69.0) / 12.0), 3)

  defp note_entry({id, note, {s, e}}, tempo_map) do
    %{
      id: id,
      start_sec: sec_of(tempo_map, s),
      end_sec: sec_of(tempo_map, e),
      midi: midi_of(note),
      lyric: note.lyric,
      rest: is_nil(note.key) or note.lyric in [nil, ""]
    }
  end

  defp midi_of(%{key: nil}), do: nil

  defp midi_of(%{key: key}) do
    case Coconut.Score.Key.Inner.impl_for(key) do
      nil -> nil
      _ -> Key.to_midi(key)
    end
  end

  defp sec_of(tempo_map, tick),
    do: Float.round(Coconut.Score.TempoMap.tick_to_sec(tempo_map, tick), 4)

  # 编译后的 tempo 段：Step 段 strategy.bpm 是普通 bpm（非 milli）。
  defp tempos_json(%{segments: segments}) do
    segments
    |> Tuple.to_list()
    |> Enum.map(fn %{start_pos: tick, strategy: %{bpm: bpm}} ->
      %{tick: tick, bpm: Float.round(bpm * 1.0, 4)}
    end)
  end

  defp span_json(nil, _tempo_map), do: nil

  defp span_json({s, e}, tempo_map),
    do: %{
      start_tick: s,
      end_tick: e,
      start_sec: sec_of(tempo_map, s),
      end_sec: sec_of(tempo_map, e)
    }

  defp phonemes_json(boundaries, shift, fps, span, tempo_map) do
    boundaries
    |> Enum.filter(fn b ->
      overlap?({b.start_frame + shift, b.end_frame + shift}, frame_span(span, tempo_map, fps))
    end)
    |> Enum.map(fn b ->
      %{
        label: b.symbol,
        language: b.language,
        start_sec: Float.round((b.start_frame + shift) / fps, 4),
        end_sec: Float.round((b.end_frame + shift) / fps, 4),
        note_id: b.note_id
      }
    end)
  end

  defp frame_span(nil, _tempo_map, _fps), do: nil

  defp frame_span({s, e}, tempo_map, fps),
    do: {tick_frame(s, fps, tempo_map), tick_frame(e, fps, tempo_map)}

  defp overlap?({_s, _e}, nil), do: true
  defp overlap?({s, e}, {span_s, span_e}), do: s < span_e and e > span_s

  # ---- patch 锚点投影 ----

  defp patch_json(patch, view) do
    %{
      id: patch.id,
      channel: patch.channel,
      anchor: anchor_json(patch.anchor),
      span_ticks: resolved_span(patch.anchor, view),
      payload: patch.patch.payload
    }
  end

  defp anchor_json(%Tamale.Anchor.Ordinal{refs: refs, adjacent?: adjacent?, at_version: v}),
    do: %{kind: "ordinal", refs: refs, adjacent: adjacent?, at_version: v}

  defp anchor_json(%Tamale.Anchor.Metric{coord: coord, from: from, to: to, at_version: v}),
    do: %{kind: "metric", coord: to_string(coord), from: from, to: to, at_version: v}

  defp anchor_json(%Tamale.Anchor.Relative{
         ref: ref,
         from_offset: fo,
         to_offset: to,
         at_version: v
       }),
       do: %{kind: "relative", ref: ref, from_offset: fo, to_offset: to, at_version: v}

  defp resolved_span(%Tamale.Anchor.Ordinal{refs: [ref | _]}, view) do
    case Enum.find(view.elements, fn {id, _note, _span} -> id == ref end) do
      {_id, _note, {s, e}} -> [s, e]
      nil -> nil
    end
  end

  defp resolved_span(%Tamale.Anchor.Metric{from: from, to: to}, _view), do: [from, to]

  defp resolved_span(%Tamale.Anchor.Relative{ref: ref, from_offset: fo, to_offset: to}, view) do
    case Enum.find(view.elements, fn {id, _note, _span} -> id == ref end) do
      {_id, _note, {s, e}} -> [s + fo, e + to]
      nil -> nil
    end
  end

  defp resolved_span(_anchor, _view), do: nil

  # pitch intervention → 可视化控制点：绝对 tick + 绝对 MIDI。Bezier handle
  # 保留在 meta.patches.payload；现有画图 schema 继续消费兼容的 tick/value 点。
  defp curves_json(patches, view, span) do
    for %{channel: :pitch} = patch <- patches,
        span_overlaps?(resolved_span(patch.anchor, view), span),
        {:ok, points} <- [Neume.PitchCurve.display_points(patch.patch.payload)] do
      curve_points =
        Enum.map(points, fn [tick, midi] ->
          %{tick: tick, value: Float.round(midi * 1.0, 3)}
        end)

      %{id: patch.id, kind: "pitch_midi", points: curve_points}
    end
  end

  defp span_overlaps?(_span_ticks, nil), do: true
  defp span_overlaps?(nil, _span), do: true
  defp span_overlaps?([s, e], {span_s, span_e}), do: s < span_e and e > span_s
end
