defmodule EquinoxDomain.Project do
  defstruct [
    :id,
    :name,
    tempo_map: [],
    time_sig_map: [],
    tracks: %{},   # %{track_id => Track}
    metadata: %{}
  ]
end
