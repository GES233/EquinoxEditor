defmodule EquinoxDomain.Command.RenderRequest do
  @moduledoc """
  渲染请求——Compiler 的统一入口（per-window 快照）。

  `from_window/3` 构造时自动完成：

  - 按 `Window.note_ids` 定位轨道（在工程 Vocal 轨集合中找元素表全覆盖者）
    并取回带 span 的音符视图；
  - 过滤轨道上**结构存活**的 patch：Ordinal / Relative 锚按
    refs ∩ `window.note_ids`，Metric 锚按 tick 区间相交（左闭右开）；
  - 用 `Coconut.Score.TempoMap.slice/3` 切窗口内 tempo_segments，
    并把编译图的 `tpqn` 带上（帧网格换算——kernel 曲线光栅化——需要它）；
  - 从 patch channel 集合 + 轨道 active preset 的 channel 注册表派生
    `channels`（`%{channel_atom => Coconut.Render.Channel 实现模块}`）；
    注册表缺失的 channel 不收录——kernel check 阶段会以
    `:unknown_channel` 条目上报（与 `Coconut.Render.Resolve` 同语义）。

  RenderRequest 携带的是**结构存活**的 patch——写时 transport 已由
  `Workspace.apply_batch/3` 完成。digest 语义判定（`Tamale.Patch.resolve/2`）
  发生在引擎 check 阶段，不在本结构内。
  """

  import Coconut.Util.Helpers, only: [normalize_attrs: 2, strictly_normalize_attrs: 2]

  alias Coconut.Edit.{Patch, Track, Workspace}
  alias Coconut.Score.{Note, TempoMap, Tick}
  alias EquinoxDomain.Port.Channel
  alias EquinoxDomain.Score.Project
  alias EquinoxDomain.Windowing.Window

  @type t :: %__MODULE__{
          track_id: Track.track_id(),
          note_ids: [Note.note_id()],
          notes: [{Note.note_id(), Note.t(), Track.span()}],
          time_range: {Tick.numeric_tick(), Tick.numeric_tick()},
          tempo_segments: [TempoMap.compiled_event()],
          tpqn: pos_integer(),
          patches: [Patch.t()],
          channels: %{Channel.channel() => module()}
        }

  @keys [
    :track_id,
    note_ids: [],
    notes: [],
    time_range: {0, 0},
    tempo_segments: [],
    tpqn: 480,
    patches: [],
    channels: %{}
  ]
  defstruct @keys

  @doc "创建渲染请求；`:track_id` 必填。"
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
      case Map.fetch(normalized, :track_id) do
        {:ok, _} -> {:ok, struct(__MODULE__, normalized)}
        :error -> {:error, {:missing_track_id, attrs}}
      end
    end
  end

  @doc "更新渲染请求字段。"
  @spec update(t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def update(%__MODULE__{} = request, attrs) do
    with {:ok, normalized} <- strictly_normalize_attrs(attrs, @keys) do
      {:ok, struct(request, normalized)}
    end
  end

  @doc """
  从分窗投影构建 RenderRequest。

  - `project` — 工程（workspace + 侧表）；
  - `window` — `EquinoxDomain.Windowing.Window`（瞬态投影）；
  - `tempo_map` — 编译态 `Coconut.Score.TempoMap.t()`。

  `window.note_ids` 非空时据以定位轨道（元素表须全覆盖）；空窗
  （纯 extra_spans 撑出）无法定位轨道，报
  `{:error, :cannot_locate_track}`。
  """
  @spec from_window(Project.t(), Window.t(), TempoMap.t()) :: {:ok, t()} | {:error, term()}
  def from_window(%Project{} = project, %Window{} = window, %TempoMap{} = tempo_map) do
    with {:ok, track_id, track} <- locate_track(project, window.note_ids) do
      {t0, t1} = {window.start_tick, window.end_tick}
      notes = window_notes(track, window.note_ids)

      patches =
        Enum.filter(track.patches, &patch_in_window?(&1, window))

      new(
        track_id: track_id,
        note_ids: Enum.map(notes, fn {id, _note, _span} -> id end),
        notes: notes,
        time_range: {t0, t1},
        tempo_segments: TempoMap.slice(tempo_map, t0, t1),
        tpqn: tempo_map.tpqn,
        patches: patches,
        channels: derive_channels(project, track_id, patches)
      )
    end
  end

  # ---- 轨道定位 ----

  # 在工程 Vocal 轨集合（tracks_meta 键）中找元素表全覆盖 window.note_ids 者
  defp locate_track(_project, []), do: {:error, :cannot_locate_track}

  defp locate_track(%Project{} = project, note_ids) do
    project.tracks_meta
    |> Map.keys()
    |> Enum.find_value(fn track_id ->
      with {:ok, track} <- Workspace.fetch_track(project.workspace, track_id),
           true <- Enum.all?(note_ids, &Map.has_key?(track.elements_by_id, &1)) do
        {track_id, track}
      else
        _ -> nil
      end
    end)
    |> case do
      {track_id, track} -> {:ok, track_id, track}
      nil -> {:error, {:unknown_track_for_window, note_ids}}
    end
  end

  # 按窗口 note_ids 过滤轨道视图（保持视图的 {start, id} 序）
  defp window_notes(%Track{} = track, note_ids) do
    track
    |> Track.view()
    |> Enum.filter(fn {id, _note, _span} -> id in note_ids end)
  end

  # ---- patch 窗口过滤（只判结构相交，语义判定在 check 阶段） ----

  # Ordinal / Relative：refs ∩ window.note_ids 非空即纳入
  defp patch_in_window?(%Patch{anchor: %Tamale.Anchor.Ordinal{refs: refs}}, %Window{} = window),
    do: Enum.any?(refs, &(&1 in window.note_ids))

  defp patch_in_window?(%Patch{anchor: %Tamale.Anchor.Relative{ref: ref}}, %Window{} = window),
    do: ref in window.note_ids

  # Metric：tick 区间（左闭右开）与窗口相交；端点为精确有理数
  # （integer 或 {n, d}），比较不经过 float
  defp patch_in_window?(
         %Patch{anchor: %Tamale.Anchor.Metric{from: from, to: to}},
         %Window{start_tick: win_start, end_tick: win_end}
       ),
       do: rational_lt?(from, win_end) and rational_gt?(to, win_start)

  defp rational_lt?(a, b), do: rational_cmp(a, b) == :lt
  defp rational_gt?(a, b), do: rational_cmp(a, b) == :gt

  defp rational_cmp(a, b) do
    {n1, d1} = to_ratio(a)
    {n2, d2} = to_ratio(b)

    cond do
      n1 * d2 < n2 * d1 -> :lt
      n1 * d2 > n2 * d1 -> :gt
      true -> :eq
    end
  end

  defp to_ratio({n, d}) when is_integer(n) and is_integer(d) and d > 0, do: {n, d}
  defp to_ratio(i) when is_integer(i), do: {i, 1}

  # ---- channels 派生（patch channel 集合 ∩ active preset 注册表） ----

  defp derive_channels(%Project{} = project, track_id, patches) do
    registry = active_preset_channels(project, track_id)

    patches
    |> Enum.map(& &1.channel)
    |> Enum.uniq()
    |> Map.new(fn channel -> {channel, Map.get(registry, channel)} end)
    |> Enum.reject(fn {_channel, module} -> is_nil(module) end)
    |> Map.new()
  end

  defp active_preset_channels(%Project{} = project, track_id) do
    with {:ok, meta} <- Project.track_meta(project, track_id),
         active when not is_nil(active) <- meta.active_preset,
         %{channels: channels} <- Map.get(meta.presets, active) do
      channels
    else
      _ -> %{}
    end
  end
end
