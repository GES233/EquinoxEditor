defmodule EquinoxDomain.Score.Project do
  # 可被序列化的工程
  use Zongzi.Util.Model,
    keys: [
      :id,
      :name,
      tempo_map: [],
      time_sig_map: [],
      # %{track_id => Track}
      tracks: %{},
      metadata: %{}
    ],
    id_prefix: "Project_"
end
