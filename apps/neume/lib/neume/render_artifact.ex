defmodule Neume.RenderArtifact do
  @moduledoc """
  Mock 合成器输出的确定性帧制品。

  它不是音频文件；真实声库接入前用它验证分数、干预和 DAG 执行的完整
  数据路径。`midi`、`lyrics` 与 `note_ids` 使用相同下标描述每一帧。
  """

  @enforce_keys [:frame_count, :midi, :lyrics, :note_ids]
  defstruct format: :mock_frames, frame_count: 0, midi: [], lyrics: [], note_ids: []

  @type t :: %__MODULE__{
          format: :mock_frames,
          frame_count: non_neg_integer(),
          midi: [number()],
          lyrics: [String.t() | nil],
          note_ids: [term()]
        }
end
