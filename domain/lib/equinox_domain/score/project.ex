defmodule EquinoxDomain.Score.Project do
  @moduledoc """
  工程——可序列化的顶层聚合根（coconut 时代的**纯数据查询层**）。

  ## 职责划分

  - `workspace :: Coconut.Edit.Workspace.t()` — 全部音符 / patch（干预）/
    tempo / time_sig 真相。coconut 已收纳领域模型，本模块不再持有任何
    音符级状态，只做查询代理与侧表组合。
  - `tracks_meta :: %{track_id => TrackMeta.t()}` — equinox 侧表
    （混音 / 预设 / UI 状态），**不进 History、不可 undo**。
  - **写操作不在此层**：一切音符 / 干预 / tempo 写路径由 kernel 经
    `Coconut.Edit.History` + Operations/Command 完成；本层只提供
    `add_track/2` / `remove_track/2` 两个结构级便捷封装
    （`Workspace.add_track/2` + TrackMeta 初始化/清理的原子组合）。

  ## 序列化

  `dump/1` / `load/1` 组合 `Coconut.Pickle.Workspace`
  （registry 取 `Coconut.Pickle.Track.default_registry/0`，宿主扩展轨型时
  需同步扩展）与 TrackMeta 的 plain map codec；产物带 `version: 1`。
  """

  import Coconut.Util.Helpers, only: [normalize_attrs: 2, strictly_normalize_attrs: 2]

  alias Coconut.Edit.{Track, Workspace}
  alias EquinoxDomain.Score.TrackMeta

  @type t :: %__MODULE__{
          id: Coconut.Util.ID.t(t()),
          workspace: Workspace.t(),
          tracks_meta: %{Track.track_id() => TrackMeta.t()},
          metadata: map()
        }

  @keys [:id, :workspace, tracks_meta: %{}, metadata: %{}]
  defstruct @keys

  # ---- 构造 ----

  @doc """
  创建工程；`:id` 必填。`:workspace` 缺省时新建空 Workspace
  （id 自动以 `"WSpc_"` 前缀生成）。
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys),
         {:ok, id} <- fetch_id(normalized),
         {:ok, workspace} <- build_workspace(normalized) do
      {:ok,
       %__MODULE__{
         id: id,
         workspace: workspace,
         tracks_meta: Map.get(normalized, :tracks_meta, %{}),
         metadata: Map.get(normalized, :metadata, %{})
       }}
    end
  end

  defp fetch_id(attrs) do
    case Map.fetch(attrs, :id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:missing_id, "Project_"}}
    end
  end

  defp build_workspace(attrs) do
    case Map.fetch(attrs, :workspace) do
      {:ok, %Workspace{} = workspace} -> {:ok, workspace}
      :error -> Workspace.new(id: Coconut.Util.ID.generate_id("WSpc_"), edit_version: 0)
    end
  end

  @doc "更新顶层字段（`:id` / `:workspace` 不可经此修改）。"
  @spec update(t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def update(%__MODULE__{} = project, attrs) do
    with {:ok, normalized} <- strictly_normalize_attrs(attrs, [:tracks_meta, :metadata]) do
      {:ok, struct(project, normalized)}
    end
  end

  # ---- Track 结构（Workspace 写 + 侧表同步的组合） ----

  @doc """
  新建一条 Vocal 轨并挂进工程。

  `attrs` 透传 `Coconut.Edit.Track.new/1`（`:id` 必填，`:module` 固定为
  `Coconut.Edit.Track.Vocal`，不可覆盖）；成功后初始化缺省 TrackMeta。
  返回 `{:ok, project, track}`。
  """
  @spec add_track(t(), map() | keyword()) ::
          {:ok, t(), Track.t()} | {:error, term()}
  def add_track(%__MODULE__{} = project, attrs) do
    attrs = attrs |> Map.new() |> Map.put(:module, Coconut.Edit.Track.Vocal)

    with {:ok, track} <- Track.new(attrs),
         {:ok, workspace} <- Workspace.add_track(project.workspace, track),
         {:ok, meta} <- TrackMeta.new() do
      project = %{
        project
        | workspace: workspace,
          tracks_meta: Map.put(project.tracks_meta, track.id, meta)
      }

      {:ok, project, track}
    end
  end

  @doc "移除轨道（连同侧表）；不存在报 `{:error, {:unknown_track, id}}`。"
  @spec remove_track(t(), Track.track_id()) :: {:ok, t()} | {:error, term()}
  def remove_track(%__MODULE__{} = project, track_id) do
    with {:ok, workspace} <- Workspace.remove_track(project.workspace, track_id) do
      {:ok,
       %{project | workspace: workspace, tracks_meta: Map.delete(project.tracks_meta, track_id)}}
    end
  end

  # ---- 查询代理 ----

  @doc "按 id 取 `Coconut.Edit.Track`。"
  @spec fetch_track(t(), Track.track_id()) ::
          {:ok, Track.t()} | {:error, {:unknown_track, term()}}
  def fetch_track(%__MODULE__{workspace: workspace}, track_id),
    do: Workspace.fetch_track(workspace, track_id)

  @doc "取轨道元数据侧表项。"
  @spec track_meta(t(), Track.track_id()) ::
          {:ok, TrackMeta.t()} | {:error, {:unknown_track_meta, Track.track_id()}}
  def track_meta(%__MODULE__{tracks_meta: tracks_meta}, track_id) do
    case Map.fetch(tracks_meta, track_id) do
      {:ok, meta} -> {:ok, meta}
      :error -> {:error, {:unknown_track_meta, track_id}}
    end
  end

  @doc "写入轨道元数据侧表项（轨道须已存在；meta 经 `TrackMeta.validate/1`）。"
  @spec put_track_meta(t(), Track.track_id(), TrackMeta.t()) :: {:ok, t()} | {:error, term()}
  def put_track_meta(%__MODULE__{} = project, track_id, %TrackMeta{} = meta) do
    with {:ok, _track} <- Workspace.fetch_track(project.workspace, track_id),
         {:ok, meta} <- TrackMeta.validate(meta) do
      {:ok, %{project | tracks_meta: Map.put(project.tracks_meta, track_id, meta)}}
    end
  end

  @doc "编译态 tempo map（代理 `Workspace.tempo_map/1`）。"
  @spec tempo_map(t()) :: {:ok, Coconut.Score.TempoMap.t()} | {:error, term()}
  def tempo_map(%__MODULE__{workspace: workspace}), do: Workspace.tempo_map(workspace)

  @doc "编译态 time sig map（代理 `Workspace.time_sig_map/1`）。"
  @spec time_sig_map(t()) :: {:ok, Coconut.Score.TimeSigMap.t()} | {:error, term()}
  def time_sig_map(%__MODULE__{workspace: workspace}), do: Workspace.time_sig_map(workspace)

  @doc """
  轨道的扁平乐谱视图（代理 `Coconut.Edit.Track.view/1`）：
  `[{note_id, Note.t(), {start_tick, end_tick}}]`，按 `{start, id}` 排序。
  """
  @spec view(t(), Track.track_id()) :: {:ok, Track.view()} | {:error, term()}
  def view(%__MODULE__{} = project, track_id) do
    with {:ok, track} <- fetch_track(project, track_id) do
      {:ok, Track.view(track)}
    end
  end

  # ---- 序列化 ----

  @doc "摊平为 plain map（`version: 1`；workspace 与 tracks_meta 分别走各自 codec）。"
  @spec dump(t()) :: {:ok, map()} | {:error, term()}
  def dump(%__MODULE__{} = project) do
    with {:ok, workspace} <-
           Coconut.Pickle.Workspace.dump(project.workspace, pickle_registry()),
         {:ok, tracks_meta} <- dump_tracks_meta(project.tracks_meta) do
      {:ok,
       %{
         version: 1,
         id: project.id,
         workspace: workspace,
         tracks_meta: tracks_meta,
         metadata: project.metadata
       }}
    end
  end

  @doc "从 plain map 重建 Project（workspace 与 tracks_meta 各自 load 后组合）。"
  @spec load(map()) :: {:ok, t()} | {:error, term()}
  def load(%{} = data) do
    with {:ok, workspace} <-
           Coconut.Pickle.Workspace.load(Map.get(data, :workspace, %{}), pickle_registry()),
         {:ok, tracks_meta} <- load_tracks_meta(Map.get(data, :tracks_meta, %{})),
         {:ok, project} <-
           new(
             id: Map.get(data, :id),
             workspace: workspace,
             tracks_meta: tracks_meta,
             metadata: Map.get(data, :metadata, %{})
           ) do
      {:ok, project}
    end
  end

  def load(other), do: {:error, {:invalid_project_dump, other}}

  # registry 是存档格式的一部分：宿主扩展轨型 / 元素 codec 时应在此处扩展
  defp pickle_registry, do: Coconut.Pickle.Track.default_registry()

  # TrackMeta.dump/1 恒 {:ok, _}（Preset.dump/1 同为恒成功），故直接映射
  defp dump_tracks_meta(tracks_meta) do
    {:ok,
     Map.new(tracks_meta, fn {track_id, meta} ->
       {:ok, dumped} = TrackMeta.dump(meta)
       {track_id, dumped}
     end)}
  end

  defp load_tracks_meta(dumped) when is_map(dumped) do
    Enum.reduce_while(dumped, {:ok, %{}}, fn {track_id, meta_dump}, {:ok, acc} ->
      case TrackMeta.load(meta_dump) do
        {:ok, meta} -> {:cont, {:ok, Map.put(acc, track_id, meta)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp load_tracks_meta(other), do: {:error, {:invalid_tracks_meta_dump, other}}
end
