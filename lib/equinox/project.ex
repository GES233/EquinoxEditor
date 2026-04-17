defmodule Equinox.Project do
  @moduledoc """
  顶层会话容器。
  拥有节拍图、轨道列表、全局撤销/重做。
  """

  alias Equinox.Editor.Track

  @type id :: atom() | String.t()

  @type tempo_point :: {non_neg_integer(), number()}

  @type t :: %__MODULE__{
          id: id(),
          name: String.t(),
          tempo_map: [tempo_point()],
          ticks_per_beat: pos_integer(),
          tracks: %{Track.id() => Track.t()},
          extra: map()
        }

  defstruct [
    :id,
    :name,
    tempo_map: [{0, 120.0}],
    ticks_per_beat: 480,
    tracks: %{},
    extra: %{}
  ]

  @spec new(id(), keyword()) :: t()
  def new(id, opts \\ []) do
    %__MODULE__{
      id: id,
      name: Keyword.get(opts, :name, to_string(id)),
      tempo_map: Keyword.get(opts, :tempo_map, [{0, 120.0}]),
      ticks_per_beat: Keyword.get(opts, :ticks_per_beat, 480)
    }
  end

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

  @spec get_track(t(), Track.id()) :: {:ok, Track.t()} | :error
  def get_track(%__MODULE__{} = project, track_id) do
    Map.fetch(project.tracks, track_id)
  end

  @spec update_track(t(), Track.id(), Track.t()) :: {:ok, t()} | :error
  def update_track(%__MODULE__{} = project, track_id, %Track{} = new_track) do
    case Map.fetch(project.tracks, track_id) do
      :error ->
        :error

      {:ok, _track} ->
        {:ok, %{project | tracks: Map.put(project.tracks, track_id, new_track)}}
    end
  end

  @spec list_tracks(t()) :: [Track.t()]
  def list_tracks(%__MODULE__{} = project) do
    Map.values(project.tracks)
  end
end
