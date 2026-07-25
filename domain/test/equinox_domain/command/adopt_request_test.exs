defmodule EquinoxDomain.Command.AdoptRequestTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Command.AdoptRequest
  alias EquinoxDomain.Port.Declarations.PhonemeTiming
  alias EquinoxDomain.Score.Track
  alias Zongzi.Score.Key.TwelveET
  alias Zongzi.Util.ID

  @projection %{"C" => {0.0, 0.05}, "V" => {0.05, 0.10}}

  setup do
    {:ok, track} =
      Track.new(
        id: ID.generate_id("Track_"),
        project_id: ID.generate_id("Project_"),
        name: "采纳轨"
      )

    {:ok, key} = TwelveET.new(60)

    {:ok, track, note} =
      Track.insert_note(track, start_tick: 0, duration_tick: 480, key: key, lyric: "a")

    %{track: track, note: note}
  end

  defp payload do
    %{
      range: {0, 480},
      deltas: [%{identity: "V", onset_delta_ms: 20, duration_delta_ms: 0}]
    }
  end

  describe "adopt/3" do
    test "采纳后 track.interventions 含新干预、snapshot 已写入", %{track: track, note: note} do
      {:ok, request} =
        AdoptRequest.new(
          channel: PhonemeTiming.channel(),
          declaration: PhonemeTiming,
          seq_id: note.seq_id,
          payload: payload()
        )

      assert {:ok, track, intervention} = AdoptRequest.adopt(request, track, @projection)

      assert [^intervention] = track.interventions
      assert String.starts_with?(intervention.id, "iv_")
      assert intervention.channel == :phoneme_timing
      assert intervention.declaration == PhonemeTiming
      assert intervention.snapshot == %{"V" => {0.05, 0.10}}
      assert intervention.anchor == {nil, note.seq_id, nil}
      assert intervention.payload == payload()
    end

    test "锚定的 seq 非 active 时报错", %{track: track} do
      {:ok, request} =
        AdoptRequest.new(
          channel: PhonemeTiming.channel(),
          declaration: PhonemeTiming,
          seq_id: 999_999,
          payload: payload()
        )

      assert {:error, :not_active} = AdoptRequest.adopt(request, track, @projection)
    end
  end
end
