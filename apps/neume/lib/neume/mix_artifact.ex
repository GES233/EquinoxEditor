defmodule Neume.MixArtifact do
  @moduledoc "Neume 多轨混音与导出制品。"

  @enforce_keys [:path, :sample_rate, :sample_count, :track_ids]
  defstruct [:path, :sample_rate, :sample_count, :duration_sec, :track_ids]

  @type t :: %__MODULE__{
          path: Path.t(),
          sample_rate: pos_integer(),
          sample_count: non_neg_integer(),
          duration_sec: float(),
          track_ids: [term()]
        }
end
