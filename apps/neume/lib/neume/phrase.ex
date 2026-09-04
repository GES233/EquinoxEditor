defmodule Neume.Phrase do
  @moduledoc """
  Neume 的瞬态乐句运行单元。

  乐句由轨道与分窗起点标识，只用于一次 analyze/check/render 调度；不会进入
  Coconut 工程、History 或 patch 身份。
  """

  alias Coconut.Render.Engine.Snapshot
  alias Neume.Windowing

  @enforce_keys [:id, :track_id, :start_tick, :end_tick, :note_ids, :snapshot, :pins]
  defstruct [:id, :track_id, :start_tick, :end_tick, :note_ids, :snapshot, :pins]

  @type t :: %__MODULE__{
          id: {term(), non_neg_integer()},
          track_id: term(),
          start_tick: non_neg_integer(),
          end_tick: non_neg_integer(),
          note_ids: [term()],
          snapshot: Snapshot.t(),
          pins: %{pitch: map(), duration: map()}
        }

  @spec split(Snapshot.t(), term(), map()) :: {:ok, [t()]} | {:error, term()}
  def split(%Snapshot{} = snapshot, track_id, pins \\ %{}) when is_map(pins) do
    case Map.fetch(snapshot.tracks, track_id) do
      {:ok, %{module: Coconut.Edit.Track.Vocal, elements: []}} ->
        {:error, :empty_score}

      {:ok, %{module: Coconut.Edit.Track.Vocal, elements: elements} = view} ->
        phrases =
          elements
          |> Enum.map(fn {id, _note, span} -> {id, span} end)
          |> Windowing.split(tpqn: snapshot.tpqn)
          |> Enum.map(&build(&1, snapshot, track_id, view, pins))

        {:ok, phrases}

      {:ok, %{module: module}} ->
        {:error, {:not_vocal_track, track_id, module}}

      :error ->
        {:error, {:unknown_track, track_id}}
    end
  end

  defp build(window, snapshot, track_id, view, pins) do
    ids = MapSet.new(window.note_ids)
    elements = Enum.filter(view.elements, fn {id, _note, _span} -> MapSet.member?(ids, id) end)
    phrase_view = %{view | elements: elements}

    %__MODULE__{
      id: {track_id, window.start_tick},
      track_id: track_id,
      start_tick: window.start_tick,
      end_tick: window.end_tick,
      note_ids: window.note_ids,
      snapshot: %{snapshot | tracks: Map.put(snapshot.tracks, track_id, phrase_view)},
      pins: %{
        pitch: Map.take(Map.get(pins, :pitch, %{}), window.note_ids),
        duration: Map.take(Map.get(pins, :duration, %{}), window.note_ids)
      }
    }
  end
end
