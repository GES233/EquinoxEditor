defmodule Equinox.Project do
  @moduledoc """
  顶层会话容器 (Pure Data)。
  拥有节拍图、轨道列表。完全可以通过 JSON 序列化和反序列化。
  """

  alias Equinox.Track

  @type id :: atom() | String.t()
  @type tempo_point :: %{tick: non_neg_integer(), bpm: number()}

  @type t :: %__MODULE__{
          id: id(),
          name: String.t(),
          version: pos_integer(),
          tempo_map: [tempo_point()],
          ticks_per_beat: pos_integer(),
          tracks: %{Track.id() => Track.t()},
          arranger_graph: Equinox.Kernel.Graph.t() | nil,
          extra: map()
        }

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :version,
             :tempo_map,
             :ticks_per_beat,
             :tracks,
             :arranger_graph,
             :extra
           ]}
  defstruct [
    :id,
    name: "Untitled Project",
    version: 1,
    tempo_map: [%{tick: 0, bpm: 120.0}],
    ticks_per_beat: 480,
    tracks: %{},
    arranger_graph: nil,
    extra: %{}
  ]

  @doc "创建新 Project，接受 Map 或 Keyword List"
  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}) do
    attrs = Equinox.Utils.AttributesHelper.normalize(attrs)

    %__MODULE__{
      id: Map.get(attrs, :id, Equinox.Utils.ID.generate()),
      name: Map.get(attrs, :name, "Untitled Project"),
      version: Map.get(attrs, :version, 1),
      tempo_map: Map.get(attrs, :tempo_map, [%{tick: 0, bpm: 120.0}]),
      ticks_per_beat: Map.get(attrs, :ticks_per_beat, 480),
      tracks: Map.get(attrs, :tracks, %{}),
      arranger_graph: Map.get(attrs, :arranger_graph),
      extra: Map.get(attrs, :extra, %{})
    }
  end

  @doc "序列化为格式化的 JSON"
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = project) do
    Jason.encode!(project, pretty: true)
  end

  @doc "从 JSON 字符串反序列化为完整的 Project 结构体（Hydration）"
  @spec from_json(String.t()) :: t()
  def from_json(json_string) when is_binary(json_string) do
    attrs = Jason.decode!(json_string, keys: :atoms)

    # 递归反序列化嵌套结构
    tracks =
      Map.get(attrs, :tracks, %{})
      |> Map.new(fn {track_id, track_attrs} ->
        # JSON parse 出来的 track_id 可能是 string 也可能是 atom，保持原样作为 key
        {track_id, Track.from_attrs(track_attrs)}
      end)

    arranger_graph = Map.get(attrs, :arranger_graph)

    # TODO: 当我们实现完整的反序列化时，这里可能需要调用 Graph.from_json() 等，目前暂存原始 Map

    attrs
    |> Map.put(:tracks, tracks)
    |> Map.put(:arranger_graph, arranger_graph)
    |> new()
  end

  # --- 轨道操作 ---

  @spec add_track(t(), Track.t()) :: {:ok, t()} | {:error, :already_exists}
  def add_track(%__MODULE__{} = project, %Track{id: track_id} = track) do
    if Map.has_key?(project.tracks, track_id) do
      {:error, :already_exists}
    else
      {:ok, %{project | tracks: Map.put(project.tracks, track_id, track)}}
    end
  end

  @spec remove_track(t(), Track.id()) :: t()
  def remove_track(%__MODULE__{} = project, track_id) do
    %{project | tracks: Map.delete(project.tracks, track_id)}
  end

  @spec get_track(t(), Track.id()) :: {:ok, Track.t()} | {:error, :track_not_found}
  def get_track(%__MODULE__{} = project, track_id) do
    with :error <- Map.fetch(project.tracks, track_id) do
      {:error, :track_not_found}
    end
  end

  @spec update_track(t(), Track.id(), Track.t()) :: {:ok, t()} | {:error, :track_not_found}
  def update_track(%__MODULE__{} = project, track_id, %Track{} = new_track) do
    case Map.fetch(project.tracks, track_id) do
      :error ->
        {:error, :track_not_found}

      {:ok, _track} ->
        {:ok, %{project | tracks: Map.put(project.tracks, track_id, new_track)}}
    end
  end

  @spec list_tracks(t()) :: [Track.t()]
  def list_tracks(%__MODULE__{} = project) do
    Map.values(project.tracks)
  end
end
