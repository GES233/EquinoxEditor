defmodule EquinoxDomain.Project do
  defstruct [
    :id,
    :name,
    tempo_map: [],
    time_sig_map: [],
    # %{track_id => Track}
    tracks: %{},
    metadata: %{}
  ]
end
