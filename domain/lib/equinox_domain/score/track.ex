defmodule EquinoxDomain.Score.Track do
  @moduledoc """
  轨道——承载音符、数据通道、混音参数与 Port 预设。
  """
  alias EquinoxDomain.Score.{Project, Note, Track}
  alias EquinoxDomain.Port.{Channel, Preset}
  alias EquinoxDomain.Util.ID
  alias EquinoxDomain.LayerChunk

  @type t :: %__MODULE__{
          id: ID.t(Track),
          project_id: ID.t(Project),
          name: String.t(),
          notes: %{ID.t(Note) => Note.t()},
          data_channels: %{Channel.channel() => [LayerChunk.t()]},
          mix_automation: map(),
          gain: number(),
          pan: number(),
          mute: boolean(),
          solo: boolean(),
          presets: %{binary() => Preset.t()},
          active_preset: nil | binary(),
          metadata: map()
        }
  use EquinoxDomain.Util.Model,
    keys: [
      :id,
      :project_id,
      :name,
      type: :synth,
      # ---- Note 层 ----
      notes: %{},
      # ---- 统一数据通道 ----
      data_channels: %{},
      # ---- Mix Automation ----
      mix_automation: %{},
      # ---- Mix 静态值 ----
      gain: 1.0,
      pan: 0.0,
      mute: false,
      solo: false,
      # ---- Port 预设 ----
      presets: %{},
      active_preset: nil,
      # ---- 其他 ----
      metadata: %{}
    ],
    id_prefix: "Track_"
end
