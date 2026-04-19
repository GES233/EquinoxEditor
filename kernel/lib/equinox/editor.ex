defmodule Equinox.Editor do
  @moduledoc """
  Pure functional operations for mutating an `Equinox.Project`.
  All functions take a project and an action, returning a new `{:ok, project}`.
  """

  alias Equinox.Project
  alias Equinox.Track
  alias Equinox.Editor.Segment
  alias Equinox.Domain.Note

  @doc """
  Adds a new note to a specific segment within a track.
  """
  @spec add_note(Project.t(), Track.id(), Segment.id(), Note.t()) ::
          {:ok, Project.t()} | {:error, atom()}
  def add_note(%Project{} = project, track_id, segment_id, %Note{} = note) do
    with {:ok, track} <- Project.get_track(project, track_id),
         {:ok, segment} <- Track.get_segment(track, segment_id) do
      # Add the note to the segment
      updated_notes = [note | segment.notes]
      updated_segment = %{segment | notes: updated_notes}

      # Update the track with the new segment
      {:ok, updated_track} = Track.update_segment(track, segment_id, updated_segment)

      # Update the project with the new track
      Project.update_track(project, track_id, updated_track)
    end
  end

  @doc """
  Updates an existing note within a specific segment.
  """
  @spec update_note(Project.t(), Track.id(), Segment.id(), Note.id(), map()) ::
          {:ok, Project.t()} | {:error, atom()}
  def update_note(%Project{} = project, track_id, segment_id, note_id, updates) do
    with {:ok, track} <- Project.get_track(project, track_id),
         {:ok, segment} <- Track.get_segment(track, segment_id) do
      updated_notes =
        Enum.map(segment.notes, fn note ->
          if note.id == note_id do
            # Apply updates. Only allow specific fields to be updated safely.
            struct!(
              note,
              Map.take(updates, [:start_tick, :duration_tick, :key, :lyric, :phoneme, :extra])
            )
          else
            note
          end
        end)

      updated_segment = %{segment | notes: updated_notes}
      {:ok, updated_track} = Track.update_segment(track, segment_id, updated_segment)
      Project.update_track(project, track_id, updated_track)
    end
  end

  @doc """
  Deletes a note from a specific segment.
  """
  @spec delete_note(Project.t(), Track.id(), Segment.id(), Note.id()) ::
          {:ok, Project.t()} | {:error, atom()}
  def delete_note(%Project{} = project, track_id, segment_id, note_id) do
    with {:ok, track} <- Project.get_track(project, track_id),
         {:ok, segment} <- Track.get_segment(track, segment_id) do
      updated_notes = Enum.reject(segment.notes, fn note -> note.id == note_id end)

      updated_segment = %{segment | notes: updated_notes}
      {:ok, updated_track} = Track.update_segment(track, segment_id, updated_segment)
      Project.update_track(project, track_id, updated_track)
    end
  end

  @doc """
  Updates the mix state of a track without touching segment synthesis content.
  """
  @spec update_track_mix(Project.t(), Track.id(), map() | keyword()) ::
          {:ok, Project.t()} | {:error, atom()}
  def update_track_mix(%Project{} = project, track_id, updates) do
    with {:ok, track} <- Project.get_track(project, track_id) do
      updated_track = Track.update_mix(track, updates)
      Project.update_track(project, track_id, updated_track)
    end
  end

  @doc """
  Stores Track-scoped UI metadata such as Arranger projection positions.
  """
  @spec update_track_ui_state(Project.t(), Track.id(), atom() | String.t(), term()) ::
          {:ok, Project.t()} | {:error, atom()}
  def update_track_ui_state(%Project{} = project, track_id, key, value) do
    with {:ok, track} <- Project.get_track(project, track_id) do
      updated_track = Track.put_ui_state(track, key, value)
      Project.update_track(project, track_id, updated_track)
    end
  end

  @doc """
  Replaces the full note set of a segment.
  This is useful for UI surfaces that edit note collections as a whole snapshot.
  """
  @spec replace_segment_notes(Project.t(), Track.id(), Segment.id(), [Note.t()]) ::
          {:ok, Project.t()} | {:error, atom()}
  def replace_segment_notes(%Project{} = project, track_id, segment_id, notes)
      when is_list(notes) do
    with {:ok, track} <- Project.get_track(project, track_id),
         {:ok, segment} <- Track.get_segment(track, segment_id) do
      updated_segment = %{segment | notes: notes}
      {:ok, updated_track} = Track.update_segment(track, segment_id, updated_segment)
      Project.update_track(project, track_id, updated_track)
    end
  end
end
