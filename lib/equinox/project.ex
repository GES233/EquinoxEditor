defmodule Equinox.Project do
  @moduledoc """
  顶层会话容器 (Pure Data)。
  拥有节拍图、轨道列表。完全可以通过 JSON 序列化和反序列化。
  """

  alias Equinox.Editor.Track

  @type id :: atom() | String.t()
  @type tempo_point :: %{tick: non_neg_integer(), bpm: number()}

  @type t :: %__MODULE__{
          id: id(),
          name: String.t(),
          version: pos_integer(),
          tempo_map: [tempo_point()],
          ticks_per_beat: pos_integer(),
          tracks: %{Track.id() => Track.t()},
          extra: map()
        }

  @derive {Jason.Encoder, only: [:id, :name, :version, :tempo_map, :ticks_per_beat, :tracks, :extra]}
  defstruct [
    :id,
    name: "Untitled Project",
    version: 1,
    tempo_map: [%{tick: 0, bpm: 120.0}],
    ticks_per_beat: 480,
    tracks: %{},
    extra: %{}
  ]

  @doc "创建新 Project，接受 Map 或 Keyword List"
  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}) do
    attrs = normalize_keys(attrs)

    %__MODULE__{
      id: Map.get(attrs, :id, generate_id()),
      name: Map.get(attrs, :name, "Untitled Project"),
      version: Map.get(attrs, :version, 1),
      tempo_map: Map.get(attrs, :tempo_map, [%{tick: 0, bpm: 120.0}]),
      ticks_per_beat: Map.get(attrs, :ticks_per_beat, 480),
      tracks: Map.get(attrs, :tracks, %{}),
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

    attrs
    |> Map.put(:tracks, tracks)
    |> new()
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp normalize_keys(map_or_kw) do
    map_or_kw
    |> Enum.into(%{})
    |> Map.new(fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
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
