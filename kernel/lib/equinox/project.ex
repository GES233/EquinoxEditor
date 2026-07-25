defmodule Equinox.Project do
  @moduledoc """
  顶层会话容器 (Pure Data)。
  拥有节拍图、轨道列表。
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
    attrs = Equinox.Util.Attrs.normalize(attrs)

    %__MODULE__{
      id: Map.get(attrs, :id, Equinox.Util.Id.generate()),
      name: Map.get(attrs, :name, "Untitled Project"),
      version: Map.get(attrs, :version, 1),
      tempo_map: Map.get(attrs, :tempo_map, [%{tick: 0, bpm: 120.0}]),
      ticks_per_beat: Map.get(attrs, :ticks_per_beat, 480),
      tracks: Map.get(attrs, :tracks, %{}),
      arranger_graph: Map.get(attrs, :arranger_graph),
      extra: Map.get(attrs, :extra, %{})
    }
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
