defmodule EquinoxUIShell.ProjectPresenter do
  @moduledoc """
  Session 视图（domain 工程投影 + 轨级合成图）→ 前端 TS 数据形状的投影器。

  输出为 plain map（可直接 Jason 编码），字段与 `assets/src/lib/bridge/index.ts`
  的 `ProjectData` / `TrackData` / `SegmentData` / `NoteData` 逐一对齐，前端零改动。

  ## 关键映射（coconut 时代）

  - **轨道二元组**：音符/时序真相在 `project.workspace` 的 `Coconut.Edit.Track`
    （`{id, name, module}`），混音/UI 状态在 `project.tracks_meta` 的
    `EquinoxDomain.Score.TrackMeta`（`gain/pan/mute/solo/ui_state/metadata`）。
    二者按 `track_id` 在此会合。
  - **窗口即 segment**：`Track.slice/3` 的瞬态 `EquinoxDomain.Windowing.Window`
    被仿真为 TS 的 `SegmentData`：id 为 `"w<start_tick>"`（见 `window_id/1`），
    `offset_tick` 取窗口起点，窗口内音符转为**窗口相对** tick（入方向经
    `ui_note_to_attrs/2` 还原）。
  - **音符**：coconut Note 不带时序，span `{start, end}` 来自 `Track.notes/2`
    视图项；`duration_tick = end - start`。
  - **key**：domain 侧是 `Coconut.Score.Key.TwelveET`；出方向 `Key.to_midi/1`
    （float 取整），入方向 `TwelveET.new/1`。
  - **phoneme**：coconut Note 无此字段，round-trip 走 `Note.metadata["phoneme"]`。
  - **color**：存于 `TrackMeta.metadata` 的 `"color"` 键；`ui_state` 直取
    `TrackMeta.ui_state`。
  - **type**：由 coconut Track 的 `module` 推导（Vocal → `"synth"`）。
  - **tempo**：tempo 是一条全局轨（`workspace.globals["global:tempo"]`，
    `Coconut.Edit.Track.Tempo`），经 `tempo_events/1` 投影为 `%{tick, bpm}`
    列表；tpqn 恒 480。
  - **patches**：轨道存活 patch（`Coconut.Edit.Track.patches`）投影为
    `TrackData.patches` 列表——`%{id, channel, anchor: %{kind, ...}, payload}`；
    anchor 只投影 kind + 关键字段（Ordinal 给 `refs`），payload 原样透传。
    结构死亡的 patch 不进此列表（经 kernel 通知通道上浮）。
  """

  alias Coconut.Edit.Track, as: CoconutTrack
  alias Coconut.Edit.Workspace
  alias Coconut.Score.Key
  alias Coconut.Score.Key.TwelveET
  alias Equinox.Kernel.Graph
  alias EquinoxDomain.Score.{Project, Track, TrackMeta}

  @ticks_per_beat 480
  @tempo_global_id "global:tempo"

  # ---- 出方向：Session 视图 → 前端 ----

  @doc "把 `Equinox.Session.Server.get_view/1` 的视图投影为前端 `ProjectData` 形状的 plain map。"
  @spec to_frontend(%{project: Project.t(), graphs: %{term() => term()}}) :: map()
  def to_frontend(%{project: %Project{} = project, graphs: graphs}) do
    %{
      id: project.id,
      name: project_name(project),
      version: 1,
      tempo_map: tempo_points(project),
      ticks_per_beat: @ticks_per_beat,
      tracks:
        Map.new(project.workspace.tracks, fn {track_id, track} ->
          {track_id, track_to_frontend(project, track, graphs)}
        end),
      arranger_graph: nil,
      extra: %{}
    }
  end

  @doc "窗口起点 → 前端 segment id（`\"w<start_tick>\"`）。"
  @spec window_id(non_neg_integer()) :: String.t()
  def window_id(start_tick) when is_integer(start_tick) and start_tick >= 0,
    do: "w#{start_tick}"

  @doc "前端 segment id → 窗口起点 tick；非法 id 报 `{:error, {:invalid_window_id, id}}`。"
  @spec parse_window_id(term()) ::
          {:ok, non_neg_integer()} | {:error, {:invalid_window_id, term()}}
  def parse_window_id("w" <> rest) do
    case Integer.parse(rest) do
      {tick, ""} when tick >= 0 -> {:ok, tick}
      _ -> {:error, {:invalid_window_id, "w" <> rest}}
    end
  end

  def parse_window_id(other), do: {:error, {:invalid_window_id, other}}

  # ---- 入方向：前端音符 → replace_window_notes attrs ----

  @doc """
  把前端 `replace_segment_notes` 的单个音符 map 转为
  `Equinox.Session.Server.replace_window_notes/4` 的单音符 attrs。

  - `start_tick` 由窗口相对转为绝对（加 `window_start`）；
  - `key`（midi 数，兼容前端别名 `pitch`）经 `TwelveET.new/1` 转为 Key struct；
  - `phoneme` 平铺进 attrs（kernel 侧经 coconut `Note.from_element/2` 落入
    `Note.metadata["phoneme"]`）；
  - `extra` 字段忽略（domain Note 无此字段）；
  - `id` 不透传：整窗替换走 `Coconut.Edit.Diff` 反推 op 批次，音符 id 由
    kernel 重新铸造，内容不变的音符自动保留原 id（锚其上的 patch 随之存活）。
  """
  @spec ui_note_to_attrs(map(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def ui_note_to_attrs(note, window_start) when is_map(note) and is_integer(window_start) do
    key_midi = Map.get(note, "key", Map.get(note, "pitch", 60))

    # TwelveET.new/1 只收 number（否则 FunctionClauseError），边界处显式校验
    if is_number(key_midi) do
      with {:ok, key} <- TwelveET.new(key_midi) do
        attrs = %{
          start_tick: window_start + Map.get(note, "start_tick", 0),
          duration_tick: Map.get(note, "duration_tick", Map.get(note, "length_tick", 480)),
          key: key,
          lyric: Map.get(note, "lyric", "la")
        }

        {:ok, maybe_put_phoneme(attrs, Map.get(note, "phoneme"))}
      end
    else
      {:error, {:invalid_key, key_midi}}
    end
  end

  # ---- 内部 ----

  # 工程名存于顶层 metadata（kernel 夹具约定 atom 键 :name；读档兼容字符串键）
  defp project_name(%Project{} = project) do
    Map.get(project.metadata, :name, Map.get(project.metadata, "name"))
  end

  defp track_to_frontend(%Project{} = project, %CoconutTrack{} = track, graphs) do
    meta = track_meta_or_default(project, track.id)

    %{
      id: track.id,
      project_id: project.id,
      type: track_type_to_string(track.module),
      name: track.name || "",
      topology_ref: nil,
      synth_graph: graphs |> Map.get(track.id) |> graph_to_frontend(),
      color: Map.get(meta.metadata, "color", ""),
      gain: meta.gain,
      pan: meta.pan,
      mute: meta.mute,
      solo: meta.solo,
      insert_fx_chain: [],
      ui_state: meta.ui_state,
      parameters: %{},
      patches: patches_to_frontend(track),
      segments: windows_to_segments(project, track.id),
      extra: %{}
    }
  end

  # 存活 patch（干预实体）投影：anchor 只投影 kind + 关键字段（Ordinal 给 refs，
  # Relative 给 ref，Metric 只给 kind），payload 原样透传（plain map，atom 键
  # 由 Jason 编码为字符串）。结构死亡的 patch 不在此列（走通知通道上浮）。
  defp patches_to_frontend(%CoconutTrack{} = track) do
    Enum.map(track.patches, fn patch ->
      %{
        id: patch.id,
        channel: patch.channel,
        anchor: anchor_to_frontend(patch.anchor),
        payload: patch.patch.payload
      }
    end)
  end

  defp anchor_to_frontend(%Tamale.Anchor.Ordinal{refs: refs}),
    do: %{kind: "ordinal", refs: refs}

  defp anchor_to_frontend(%Tamale.Anchor.Relative{ref: ref}),
    do: %{kind: "relative", ref: ref}

  defp anchor_to_frontend(%Tamale.Anchor.Metric{}), do: %{kind: "metric"}
  defp anchor_to_frontend(_other), do: %{kind: "unknown"}

  # 侧表缺项（如直接构造 workspace 未经 Server.add_track）按缺省 meta 投影
  defp track_meta_or_default(%Project{} = project, track_id) do
    case Project.track_meta(project, track_id) do
      {:ok, meta} -> meta
      {:error, _} -> %TrackMeta{}
    end
  end

  # Graph 的 edges 是 MapSet（Jason 无对应 Encoder），摊平为 list；
  # nodes map 与 Node/Edge struct 自身带 Jason derive，原样可编码
  defp graph_to_frontend(nil), do: nil

  defp graph_to_frontend(%Graph{} = graph),
    do: %{nodes: graph.nodes, edges: MapSet.to_list(graph.edges)}

  # 窗口投影失败按无 segment 处理，不让单轨拖垮整个工程投影
  defp windows_to_segments(%Project{} = project, track_id) do
    with {:ok, windows} <- Track.slice(project, track_id),
         {:ok, entries} <- Track.notes(project, track_id) do
      notes_by_id = Map.new(entries, fn {id, note, span} -> {id, {note, span}} end)

      Map.new(windows, fn window ->
        segment_id = window_id(window.start_tick)

        {segment_id,
         %{
           id: segment_id,
           track_id: track_id,
           name: segment_id,
           offset_tick: window.start_tick,
           notes: window_notes(notes_by_id, window),
           curves: %{},
           synth_override: nil,
           extra: %{}
         }}
      end)
    else
      {:error, _} -> %{}
    end
  end

  # 窗口内音符按 window.note_ids 顺序投影为窗口相对 tick；
  # 视图中已消亡的 id（理论上不出现）跳过
  defp window_notes(notes_by_id, window) do
    Enum.flat_map(window.note_ids, fn note_id ->
      case Map.fetch(notes_by_id, note_id) do
        {:ok, {note, {start_tick, end_tick}}} ->
          [
            %{
              id: note.id,
              start_tick: start_tick - window.start_tick,
              duration_tick: end_tick - start_tick,
              key: note.key |> Key.to_midi() |> trunc(),
              lyric: note.lyric,
              phoneme: Map.get(note.metadata, "phoneme"),
              extra: %{}
            }
          ]

        :error ->
          []
      end
    end)
  end

  # tempo 全局轨事件 → `%{tick, bpm}`；`tempo_events/1` 已把 milli-bpm
  # 反归一化为普通 bpm；tempo 轨缺失/为空时投影为空列表
  defp tempo_points(%Project{} = project) do
    case Workspace.fetch_track(project.workspace, @tempo_global_id) do
      {:ok, tempo_track} ->
        tempo_track
        |> Coconut.Edit.Track.Tempo.tempo_events()
        |> Enum.flat_map(fn
          {tick, %{context: %{bpm: bpm}}} -> [%{tick: tick, bpm: bpm}]
          _other -> []
        end)

      {:error, _} ->
        []
    end
  end

  # coconut Track 无 type 字段，由 module 推导前端 type 字符串
  defp track_type_to_string(Coconut.Edit.Track.Vocal), do: "synth"
  defp track_type_to_string(Coconut.Edit.Track.Audio), do: "external_audio"

  defp track_type_to_string(module) when is_atom(module),
    do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp maybe_put_phoneme(attrs, nil), do: attrs
  defp maybe_put_phoneme(attrs, phoneme), do: Map.put(attrs, :phoneme, phoneme)
end
