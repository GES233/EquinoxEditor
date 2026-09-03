defmodule Neume.Analysis do
  @moduledoc """
  analyze/align 闭环的结果 VO。

  不运行 acoustic/vocoder 即可取得：按需 G2P 后的逐音符音素、duration 模型
  预测的逐音素帧长、pitch 预测，以及元音锚定后的音素边界。边界帧号是
  窗（或全轨）局部时基；歌曲绝对帧（含 lead-in 平移约定，与
  `RenderArtifact.phonemes` 一致）= `local_frame + round(origin_sec * frame_rate)`。

  运行时结果，不进入工程文件和编辑历史。
  """

  @enforce_keys [:frame_rate, :total_frames]
  defstruct notes: [],
            phonemes: [],
            phoneme_durations: [],
            pitch_pred_midi: [],
            lead_in_sec: 0.0,
            origin_sec: 0.0,
            total_frames: 0,
            frame_rate: nil,
            sample_rate: nil,
            hop_size: nil

  @type note :: %{
          required(:id) => term(),
          required(:lyric) => String.t() | nil,
          required(:language) => String.t(),
          required(:phonemes) => [[String.t()]]
        }

  @type t :: %__MODULE__{
          notes: [note()],
          phonemes: [Neume.RenderArtifact.phoneme_boundary()],
          phoneme_durations: [non_neg_integer()],
          pitch_pred_midi: [float()],
          lead_in_sec: float(),
          origin_sec: float(),
          total_frames: non_neg_integer(),
          frame_rate: float(),
          sample_rate: pos_integer() | nil,
          hop_size: pos_integer() | nil
        }
end
