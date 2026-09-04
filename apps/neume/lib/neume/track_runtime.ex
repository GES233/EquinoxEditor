defmodule Neume.TrackRuntime do
  @moduledoc """
  单条人声轨的可重建运行态。

  这里只保存声库管线、worker/cache handle 与逐轨引擎配置；工程编辑事实和
  History 只存在于 `Neume.MultiTrack.session`。`Neume.Editor` 在逐轨调用期间
  临时把该运行态绑定到工程 Session 的当前快照。
  """

  alias Coconut.Edit.Track

  @enforce_keys [
    :track_id,
    :voicebank,
    :pipeline,
    :pipeline_state,
    :engine,
    :channels,
    :interventions
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          track_id: Track.track_id(),
          voicebank: Coconut.Project.voicebank() | nil,
          pipeline: module(),
          pipeline_state: term(),
          engine: Coconut.Render.Engine.engine(),
          channels: %{atom() => module()},
          interventions: map()
        }
end
