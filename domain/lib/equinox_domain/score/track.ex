defmodule EquinoxDomain.Score.Track do
  use EquinoxDomain.Util.Model,
    keys: [
      :id,
      :project_id,
      :name,
      type: :synth,
      # ---- Note 层 ----
      notes: %{},
      # 作为可选项的索引
      # ---- 连续参数层 (synth) ----
      curve_layers: %{},
      # ---- Mix Automation ----
      mix_automation: %{},
      # ---- Mix 静态值 (非自动化的默认值) ----
      gain: 1.0,
      pan: 0.0,
      mute: false,
      solo: false,
      # ---- 其他 ----
      metadata: %{}
    ],
    id_prefix: "Track_"
end
