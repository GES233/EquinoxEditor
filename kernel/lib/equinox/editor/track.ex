defmodule Equinox.Editor.Track do
  @moduledoc """
  音轨的纯数据声明。
  """

  alias Equinox.Editor.Segment

  @type id :: atom() | String.t()
  @type track_type :: String.t() | atom()

  @type t :: %__MODULE__{
          id: id(),
          project_id: atom() | String.t() | nil,
          type: track_type(),
          name: String.t(),
          topology_ref: String.t() | nil,
          synth_graph: Equinox.Kernel.Graph.t() | nil,
          color: String.t(),
          gain: float(),
          pan: float(),
          mute: boolean(),
          solo: boolean(),
          insert_fx_chain: [map()],
          ui_state: map(),
          parameters: map(),
          segments: %{Segment.id() => Segment.t()},
          extra: map()
        }

  @derive {Jason.Encoder,
           only: [
             :id,
             :project_id,
             :type,
             :name,
             :topology_ref,
             :synth_graph,
             :color,
             :gain,
             :pan,
             :mute,
             :solo,
             :insert_fx_chain,
             :ui_state,
             :parameters,
             :segments,
             :extra
           ]}
  defstruct [
    :id,
    :project_id,
    type: "synth",
    name: "New Track",
    topology_ref: nil,
    synth_graph: nil,
    color: "#3B82F6",
    gain: 1.0,
    pan: 0.0,
    mute: false,
    solo: false,
    insert_fx_chain: [],
    ui_state: %{},
    parameters: %{},
    segments: %{},
    extra: %{}
  ]

  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}) do
    attrs = normalize_keys(attrs)

    %__MODULE__{
      id: Map.get(attrs, :id, generate_id()),
      project_id: Map.get(attrs, :project_id),
      type: Map.get(attrs, :type, "synth"),
      name: Map.get(attrs, :name, "New Track"),
      topology_ref: Map.get(attrs, :topology_ref),
      synth_graph: Map.get(attrs, :synth_graph),
      color: Map.get(attrs, :color, "#3B82F6"),
      gain: Map.get(attrs, :gain, 1.0),
      pan: Map.get(attrs, :pan, 0.0),
      mute: Map.get(attrs, :mute, false),
      solo: Map.get(attrs, :solo, false),
      insert_fx_chain: Map.get(attrs, :insert_fx_chain, []),
      ui_state: Map.get(attrs, :ui_state, %{}),
      parameters: Map.get(attrs, :parameters, %{}),
      segments: Map.get(attrs, :segments, %{}),
      extra: Map.get(attrs, :extra, %{})
    }
  end

  @doc "从 JSON Map 反序列化并构造嵌套结构体"
  def from_attrs(attrs) do
    attrs = normalize_keys(attrs)

    segments =
      Map.get(attrs, :segments, %{})
      |> Map.new(fn {k, v} -> {k, Segment.from_attrs(v)} end)

    synth_graph = Map.get(attrs, :synth_graph)

    attrs
    |> Map.put(:segments, segments)
    |> Map.put(:synth_graph, synth_graph)
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

  # --- Segment 操作 ---

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

  @spec get_segment(t(), Segment.id()) :: {:ok, Segment.t()} | {:error, :segment_not_found}
  def get_segment(%__MODULE__{} = track, seg_id) do
    with :error <- Map.fetch(track.segments, seg_id) do
      {:error, :segment_not_found}
    end
  end

  @spec update_segment(t(), Segment.id(), Segment.t() | (Segment.t() -> Segment.t())) ::
          {:ok, t()} | {:error, :segment_not_found}
  def update_segment(%__MODULE__{} = track, seg_id, updater_or_segment) do
    case Map.fetch(track.segments, seg_id) do
      :error ->
        {:error, :segment_not_found}

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

  @spec update_mix(t(), map() | keyword()) :: t()
  def update_mix(%__MODULE__{} = track, updates) do
    updates = normalize_keys(updates)

    %{
      track
      | gain: Map.get(updates, :gain, track.gain),
        pan: Map.get(updates, :pan, track.pan),
        mute: Map.get(updates, :mute, track.mute),
        solo: Map.get(updates, :solo, track.solo)
    }
  end

  @spec put_ui_state(t(), atom() | String.t(), term()) :: t()
  def put_ui_state(%__MODULE__{} = track, key, value) when is_atom(key) or is_binary(key) do
    %{track | ui_state: Map.put(track.ui_state, key, value)}
  end
end
