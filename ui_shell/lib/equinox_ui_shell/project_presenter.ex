defmodule EquinoxUIShell.ProjectPresenter do
  @moduledoc """
  Session 视图（domain 聚合 + 轨级合成图）→ 前端 TS 数据形状的投影器。

  输出为 plain map（可直接 Jason 编码），字段与 `assets/src/lib/bridge/index.ts`
  的 `ProjectData` / `TrackData` / `SegmentData` / `NoteData` 逐一对齐，前端零改动。

  ## 关键映射

  - **窗口即 segment**：`Track.slice/1` 的瞬态 `Zongzi.Windowing.Segment` 被仿真为
    TS 的 `SegmentData`：id 为 `"w<start_tick>"`（见 `window_id/1`），`offset_tick`
    取窗口起点，窗口内音符转为**窗口相对** tick（入方向经 `ui_note_to_attrs/2` 还原）。
  - **key**：domain 侧是 `Zongzi.Score.Key.TwelveET`；出方向 `Key.to_midi/1`（float
    取整），入方向 `TwelveET.new/1`。
  - **phoneme**：domain Note 无此字段，round-trip 走 `Note.metadata["phoneme"]`。
  - **color / ui_state**：存于 `Track.metadata` 的 `"color"` / `"ui_state"` 键。
  - **type**：atom（`:synth` / `:external_audio`）显式映射为字符串（禁反向 `String.to_atom`）。
  - **tempo**：`Project.tempo_map` 源事件列表抽 `%{tick, bpm}`；tpqn 恒 480。
  """

  alias Equinox.Kernel.Graph
  alias EquinoxDomain.Score.{Project, Track}
  alias Zongzi.Score.Key
  alias Zongzi.Score.Key.TwelveET

  @ticks_per_beat 480

  # ---- 出方向：Session 视图 → 前端 ----

  @doc "把 `Equinox.Session.Server.get_view/1` 的视图投影为前端 `ProjectData` 形状的 plain map。"
  @spec to_frontend(%{project: Project.t(), graphs: %{term() => term()}}) :: map()
  def to_frontend(%{project: %Project{} = project, graphs: graphs}) do
    %{
      id: project.id,
      name: project.name,
      version: 1,
      tempo_map: tempo_points(project.tempo_map),
      ticks_per_beat: @ticks_per_beat,
      tracks:
        Map.new(project.tracks, fn {track_id, track} ->
          {track_id, track_to_frontend(track, graphs)}
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

  # ---- 入方向：前端音符 → domain insert attrs ----

  @doc """
  把前端 `replace_segment_notes` 的单个音符 map 转为 `Track.insert_note/2` 的 attrs。

  - `start_tick` 由窗口相对转为绝对（加 `window_start`）；
  - `key`（midi 数，兼容前端别名 `pitch`）经 `TwelveET.new/1` 转为 Key struct；
  - `phoneme` 写入 `metadata["phoneme"]`；`extra` 字段忽略（domain Note 无此字段）；
  - `id` 非空时透传（replace 语义下窗口音符已先整体删除，id 重用无冲突）。
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
          lyric: Map.get(note, "lyric", "la"),
          metadata: note_metadata(note)
        }

        {:ok, maybe_put_id(attrs, Map.get(note, "id"))}
      end
    else
      {:error, {:invalid_key, key_midi}}
    end
  end

  # ---- 内部 ----

  defp track_to_frontend(%Track{} = track, graphs) do
    %{
      id: track.id,
      project_id: track.project_id,
      type: track_type_to_string(track.type),
      name: track.name,
      topology_ref: nil,
      synth_graph: graphs |> Map.get(track.id) |> graph_to_frontend(),
      color: Map.get(track.metadata, "color", ""),
      gain: track.gain,
      pan: track.pan,
      mute: track.mute,
      solo: track.solo,
      insert_fx_chain: [],
      ui_state: Map.get(track.metadata, "ui_state", %{}),
      parameters: %{},
      segments: windows_to_segments(track),
      extra: %{}
    }
  end

  # Graph 的 edges 是 MapSet（Jason 无对应 Encoder），摊平为 list；
  # nodes map 与 Node/Edge struct 自身带 Jason derive，原样可编码
  defp graph_to_frontend(nil), do: nil

  defp graph_to_frontend(%Graph{} = graph),
    do: %{nodes: graph.nodes, edges: MapSet.to_list(graph.edges)}

  # 窗口投影失败按无 segment 处理，不让单轨拖垮整个工程投影
  defp windows_to_segments(%Track{} = track) do
    case Track.slice(track) do
      {:ok, windows} ->
        Map.new(windows, fn window ->
          segment_id = window_id(window.start_tick)

          {segment_id,
           %{
             id: segment_id,
             track_id: track.id,
             name: segment_id,
             offset_tick: window.start_tick,
             notes: window_notes(track, window),
             curves: %{},
             synth_override: nil,
             extra: %{}
           }}
        end)

      {:error, _} ->
        %{}
    end
  end

  defp window_notes(%Track{} = track, window) do
    Enum.map(window.seq_ids, fn seq ->
      note = Map.fetch!(track.notes_by_seq, seq)

      %{
        id: note.id,
        start_tick: note.start_tick - window.start_tick,
        duration_tick: note.duration_tick,
        key: note.key |> Key.to_midi() |> trunc(),
        lyric: note.lyric,
        phoneme: Map.get(note.metadata, "phoneme"),
        extra: %{}
      }
    end)
  end

  # tempo 源事件 `{tick, %Tempo.Event{context}}` → `%{tick, bpm}`；
  # Step 取 :bpm、Linear 取 :bpm_start，无法识别的事件跳过
  defp tempo_points(events) do
    Enum.flat_map(events, fn
      {tick, %{context: %{bpm: bpm}}} -> [%{tick: tick, bpm: bpm}]
      {tick, %{context: %{bpm_start: bpm}}} -> [%{tick: tick, bpm: bpm}]
      _other -> []
    end)
  end

  defp track_type_to_string(:synth), do: "synth"
  defp track_type_to_string(:external_audio), do: "external_audio"
  defp track_type_to_string(other) when is_atom(other), do: Atom.to_string(other)

  defp note_metadata(note) do
    case Map.get(note, "phoneme") do
      nil -> %{}
      phoneme -> %{"phoneme" => phoneme}
    end
  end

  defp maybe_put_id(attrs, nil), do: attrs
  defp maybe_put_id(attrs, id), do: Map.put(attrs, :id, id)
end
