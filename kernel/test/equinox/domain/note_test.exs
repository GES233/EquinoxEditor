defmodule Equinox.Domain.NoteTest do
  use ExUnit.Case, async: true

  alias Equinox.Domain.Note

  describe "slice flag helpers" do
    test "recognizes slice start flags without Slicer dependency" do
      assert Note.slice_start?({:on_start, "slice-a"})
      refute Note.slice_start?(:on_end)
      refute Note.slice_start?(nil)

      assert Note.slice_start_id({:on_start, "slice-a"}) == "slice-a"
      assert Note.slice_start_id(:on_end) == nil
    end

    test "reads manual slice boundaries from note extra" do
      note =
        Note.new(%{id: "n1", start_tick: 0, duration_tick: 480})
        |> Note.put_manual_slice_flag({:on_start, "manual-slice"})

      assert Note.manual_slice_start?(note)
      refute Note.manual_slice_end?(note)
      assert Note.manual_slice_flag(note) == {:on_start, "manual-slice"}

      ended_note = Note.put_manual_slice_flag(note, :on_end)

      refute Note.manual_slice_start?(ended_note)
      assert Note.manual_slice_end?(ended_note)
      assert Note.manual_slice_flag(ended_note) == :on_end
    end
  end
end
