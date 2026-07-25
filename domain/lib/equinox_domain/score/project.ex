defmodule EquinoxDomain.Score.Project do
  @moduledoc """
  工程——可序列化的顶层聚合根。

  ## 序列化模型

  - `tempo_map` / `time_sig_map` 字段存的是**源事件列表**（plain data：
    `Zongzi.Score.Tempo.tempo_events()` / `Zongzi.Score.TimeSig.time_sig_events()`），
    不是编译态 tuple；编译态是运行时投影，用 `compiled_tempo_map/2` /
    `compiled_time_sig_map/2` 现场编译（缺省 `[]` 正好契合「尚未设置」语义，
    编译会返回 `{:error, :empty_*_events}`，由调用方处理）。
  - `tracks` 为 `%{track_id => Track.t()}`。
  - `dump/1` / `load/1` 遵循 `EquinoxDomain.Pickle` 原生对象 codec 约定，
    dump 产物带 `version: 1` 便于将来演进。
  """

  alias EquinoxDomain.Pickle
  alias EquinoxDomain.Score.Track
  alias Zongzi.Score.{TempoMap, TimeSigMap}

  use Zongzi.Util.Model,
    keys: [
      :id,
      :name,
      # tempo / 拍号源事件列表（plain data，编译态是运行时投影）
      tempo_map: [],
      time_sig_map: [],
      # %{track_id => Track}
      tracks: %{},
      metadata: %{}
    ],
    id_prefix: "Project_"

  @type t :: %__MODULE__{
          id: Zongzi.Util.ID.t(t()),
          name: String.t(),
          tempo_map: Zongzi.Score.Tempo.tempo_events(),
          time_sig_map: Zongzi.Score.TimeSig.time_sig_events(),
          tracks: %{Zongzi.Util.ID.t(Track) => Track.t()},
          metadata: map()
        }

  # ---- 编译态投影 ----

  @doc "把 `tempo_map` 源事件编译为 `Zongzi.Score.TempoMap.t()`（opts 透传 compile/2，如 `:tpqn`）。"
  @spec compiled_tempo_map(t(), keyword()) :: {:ok, TempoMap.t()} | {:error, term()}
  def compiled_tempo_map(%__MODULE__{tempo_map: events}, opts \\ []),
    do: TempoMap.compile(events, opts)

  @doc "把 `time_sig_map` 源事件编译为 `Zongzi.Score.TimeSigMap.t()`（opts 透传 compile/2）。"
  @spec compiled_time_sig_map(t(), keyword()) :: {:ok, TimeSigMap.t()} | {:error, term()}
  def compiled_time_sig_map(%__MODULE__{time_sig_map: events}, opts \\ []),
    do: TimeSigMap.compile(events, opts)

  # ---- Track CRUD ----

  @doc """
  把 Track 挂进工程。

  `track.project_id` 会对齐为 `project.id`；track id 冲突报 `{:already_exists, id}`。
  """
  @spec add_track(t(), Track.t()) ::
          {:ok, t()} | {:error, {:already_exists, Zongzi.Util.ID.t(Track)}}
  def add_track(%__MODULE__{} = project, %Track{} = track) do
    if Map.has_key?(project.tracks, track.id) do
      {:error, {:already_exists, track.id}}
    else
      with {:ok, track} <- Track.update(track, %{project_id: project.id}) do
        {:ok, %{project | tracks: Map.put(project.tracks, track.id, track)}}
      end
    end
  end

  @doc "按 id 移除 Track；不存在报 `{:track_not_found, id}`（不静默）。"
  @spec remove_track(t(), Zongzi.Util.ID.t(Track)) ::
          {:ok, t()} | {:error, {:track_not_found, Zongzi.Util.ID.t(Track)}}
  def remove_track(%__MODULE__{} = project, track_id) do
    if Map.has_key?(project.tracks, track_id) do
      {:ok, %{project | tracks: Map.delete(project.tracks, track_id)}}
    else
      {:error, {:track_not_found, track_id}}
    end
  end

  @doc "按 id 取 Track。"
  @spec get_track(t(), Zongzi.Util.ID.t(Track)) ::
          {:ok, Track.t()} | {:error, {:track_not_found, Zongzi.Util.ID.t(Track)}}
  def get_track(%__MODULE__{} = project, track_id) do
    case Map.fetch(project.tracks, track_id) do
      {:ok, track} -> {:ok, track}
      :error -> {:error, {:track_not_found, track_id}}
    end
  end

  @doc "整体替换或用 updater 函数（`Track.t() -> Track.t()`）更新指定 Track。"
  @spec update_track(t(), Zongzi.Util.ID.t(Track), Track.t() | (Track.t() -> Track.t())) ::
          {:ok, t()} | {:error, {:track_not_found, Zongzi.Util.ID.t(Track)}}
  def update_track(%__MODULE__{} = project, track_id, %Track{} = track) do
    put_track(project, track_id, fn _old -> track end)
  end

  def update_track(%__MODULE__{} = project, track_id, updater) when is_function(updater, 1) do
    put_track(project, track_id, updater)
  end

  @doc "列出全部 Track（顺序不保证）。"
  @spec list_tracks(t()) :: [Track.t()]
  def list_tracks(%__MODULE__{} = project), do: Map.values(project.tracks)

  defp put_track(project, track_id, fun) do
    case Map.fetch(project.tracks, track_id) do
      {:ok, old} -> {:ok, %{project | tracks: Map.put(project.tracks, track_id, fun.(old))}}
      :error -> {:error, {:track_not_found, track_id}}
    end
  end

  # ---- 序列化（EquinoxDomain.Pickle 原生对象 codec） ----

  @doc "摊平为 plain map（`version: 1`；tracks 的 track_id 键原生保留）。"
  @spec dump(t()) :: {:ok, map()} | {:error, term()}
  def dump(%__MODULE__{} = project) do
    with {:ok, tempo_events} <- Pickle.TempoEvents.dump(project.tempo_map),
         {:ok, time_sig_events} <- Pickle.TimeSigEvents.dump(project.time_sig_map),
         {:ok, tracks} <- dump_tracks(project.tracks) do
      {:ok,
       %{
         version: 1,
         id: project.id,
         name: project.name,
         tempo_events: tempo_events,
         time_sig_events: time_sig_events,
         tracks: tracks,
         metadata: project.metadata
       }}
    end
  end

  @doc "从 plain map 重建 Project（组合各子 codec；`version` 键忽略）。"
  @spec load(map()) :: {:ok, t()} | {:error, term()}
  def load(%{} = data) do
    with {:ok, tempo_map} <- Pickle.TempoEvents.load(Map.get(data, :tempo_events, %{events: []})),
         {:ok, time_sig_map} <-
           Pickle.TimeSigEvents.load(Map.get(data, :time_sig_events, %{events: []})),
         {:ok, tracks} <- load_tracks(Map.get(data, :tracks, %{})) do
      new(
        id: Map.get(data, :id),
        name: Map.get(data, :name),
        tempo_map: tempo_map,
        time_sig_map: time_sig_map,
        tracks: tracks,
        metadata: Map.get(data, :metadata, %{})
      )
    end
  end

  defp dump_tracks(tracks) do
    Enum.reduce_while(tracks, {:ok, %{}}, fn {track_id, track}, {:ok, acc} ->
      case Track.dump(track) do
        {:ok, dumped} -> {:cont, {:ok, Map.put(acc, track_id, dumped)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp load_tracks(dumped) do
    Enum.reduce_while(dumped, {:ok, %{}}, fn {track_id, track_dump}, {:ok, acc} ->
      case Track.load(track_dump) do
        {:ok, track} -> {:cont, {:ok, Map.put(acc, track_id, track)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
