defmodule Equinox.Editor.Track do
  @moduledoc """
  音轨表示。包含基础属性以及所属的 Segments（如果是 Synth Track）。
  """

  alias Equinox.Editor.Segment

  @type id :: atom() | String.t()
  @type track_type :: :synth | :audio

  @type t :: %__MODULE__{
          id: id(),
          project_id: atom() | String.t() | nil,
          type: track_type(),
          name: String.t(),
          segments: %{Segment.id() => Segment.t()},
          extra: map()
        }

  defstruct [
    :id,
    :project_id,
    :type,
    :name,
    segments: %{},
    extra: %{}
  ]

  @spec new(id(), track_type(), keyword()) :: t()
  def new(id, type, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    name = Keyword.get(opts, :name, "#{type} Track #{id}")

    %__MODULE__{
      id: id,
      project_id: project_id,
      type: type,
      name: name
    }
  end

  @spec add_segment(t(), Segment.t()) :: {:ok, t()} | {:error, :already_exists}
  def add_segment(%__MODULE__{} = track, %Segment{id: seg_id} = segment) do
    if Map.has_key?(track.segments, seg_id) do
      {:error, :already_exists}
    else
      {:ok, %{track | segments: Map.put(track.segments, seg_id, segment)}}
    end
  end

  @spec remove_segment(t(), Segment.id()) :: t()
  def remove_segment(%__MODULE__{} = track, seg_id) do
    %{track | segments: Map.delete(track.segments, seg_id)}
  end

  @spec get_segment(t(), Segment.id()) :: {:ok, Segment.t()} | :error
  def get_segment(%__MODULE__{} = track, seg_id) do
    Map.fetch(track.segments, seg_id)
  end

  @spec update_segment(t(), Segment.id(), Segment.t() | (Segment.t() -> Segment.t())) ::
          {:ok, t()} | :error
  def update_segment(%__MODULE__{} = track, seg_id, updater_or_segment) do
    case Map.fetch(track.segments, seg_id) do
      :error ->
        :error

      {:ok, old_seg} ->
        new_seg =
          if is_function(updater_or_segment, 1),
            do: updater_or_segment.(old_seg),
            else: updater_or_segment

        {:ok, %{track | segments: Map.put(track.segments, seg_id, new_seg)}}
    end
  end

  @spec list_segments(t()) :: [Segment.t()]
  def list_segments(%__MODULE__{} = track) do
    Map.values(track.segments)
  end
end
