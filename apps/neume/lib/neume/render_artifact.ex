defmodule Neume.RenderArtifact do
  @moduledoc """
  Neume 对外返回的渲染制品。

  `:mock_frames` 用于不加载声库的确定性闭环测试；`:wav` 指向仓库外或
  `tmp/` 下的临时音频。制品是运行时结果，不进入工程文件和编辑历史。
  """

  @enforce_keys [:frame_count]
  defstruct format: :mock_frames,
            frame_count: 0,
            midi: [],
            lyrics: [],
            note_ids: [],
            path: nil,
            sample_rate: nil,
            sample_count: nil,
            duration_sec: nil,
            lead_in_sec: 0.0,
            origin_sec: 0.0,
            phonemes: [],
            phoneme_durations: [],
            windows: []

  @type t :: %__MODULE__{
          format: :mock_frames | :wav,
          frame_count: non_neg_integer(),
          midi: [number()],
          lyrics: [String.t() | nil],
          note_ids: [term()],
          path: Path.t() | nil,
          sample_rate: pos_integer() | nil,
          sample_count: non_neg_integer() | nil,
          duration_sec: float() | nil,
          lead_in_sec: float(),
          origin_sec: float(),
          phonemes: [phoneme_boundary()],
          phoneme_durations: [non_neg_integer()],
          windows: [window_info()]
        }

  @type window_info :: %{
          required(:start_tick) => non_neg_integer(),
          required(:end_tick) => non_neg_integer(),
          required(:note_ids) => [term()],
          required(:cache) => :hit | :miss
        }

  @type phoneme_boundary :: %{
          required(:language) => String.t(),
          required(:symbol) => String.t(),
          required(:type) => String.t() | nil,
          required(:start_frame) => non_neg_integer(),
          required(:end_frame) => non_neg_integer(),
          required(:note_id) => term() | nil,
          required(:phoneme_index) => non_neg_integer()
        }
end
