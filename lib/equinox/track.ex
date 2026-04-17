defmodule Equinox.Track do
  @moduledoc """
  A single track context containing segments (clips) and track-level configuration.

  Tracks define what pipeline (topology) is being used via `topology_ref`, and hold
  the data (Notes, Curves) within `segments`.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          topology_ref: String.t() | nil,
          color: String.t(),
          mute: boolean(),
          solo: boolean(),
          parameters: map(),
          segments: [Equinox.Editor.Segment.t()]
        }

  @derive Jason.Encoder
  defstruct id: nil,
            name: "New Track",
            topology_ref: nil,
            color: "#3B82F6",
            mute: false,
            solo: false,
            parameters: %{},
            segments: []

  @doc false
  def new(attrs \\ %{}) do
    id = Map.get(attrs, :id, generate_id())
    name = Map.get(attrs, :name, "New Track")
    topology_ref = Map.get(attrs, :topology_ref)
    color = Map.get(attrs, :color, "#3B82F6")
    mute = Map.get(attrs, :mute, false)
    solo = Map.get(attrs, :solo, false)
    parameters = Map.get(attrs, :parameters, %{})

    segments =
      Map.get(attrs, :segments, [])
      |> Enum.map(&Equinox.Editor.Segment.new/1)

    %__MODULE__{
      id: id,
      name: name,
      topology_ref: topology_ref,
      color: color,
      mute: mute,
      solo: solo,
      parameters: parameters,
      segments: segments
    }
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
