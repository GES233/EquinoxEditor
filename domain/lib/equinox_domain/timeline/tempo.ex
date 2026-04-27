defmodule EquinoxDomain.Timeline.Tempo do
  alias EquinoxDomain.Timeline.Tick

  defmodule Step do
    @behaviour EquinoxDomain.Timeline.TempoSegment

    defstruct [:start_tick, :end_tick, :bpm]

    def duration_sec(seg) do
      tick_to_sec(seg, seg.end_tick - seg.start_tick)
    end

    def tick_to_sec(seg, ticks) do
      sec_per_quarter = 60.0 / seg.bpm
      ticks * (sec_per_quarter / Tick.ticks_per_quarter_note())
    end
  end

  # Linear/Curve
end
