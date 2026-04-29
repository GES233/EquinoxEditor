defmodule EquinoxDomain.Segment do
  # 渲染的最小上下文单位

  # Track[Notes & Curves] -> Slicer & Utterance -> Segments
  alias EquinoxDomain.{Timeline.Tick, Score.Phoneme}

  # 是典型的 VO （因为是运行时生成的对象）
  @type t :: %__MODULE__{
          # ---- 业务标识 ----
          track_id: EquinoxDomain.Util.ID.t(),
          utterance_id: EquinoxDomain.Util.ID.t(),
          start_tick: Tick.numeric_tick(),
          end_tick: Tick.numeric_tick(),

          # ---- 声学区间界点 (以秒 Sec 为单位) ----
          # 实际发声的有效区间
          core_start_sec: EquinoxDomain.Timeline.physical_time(),
          core_end_sec: EquinoxDomain.Timeline.physical_time(),
          # 提供给声学模型的预留上下文（Padding）
          context_start_sec: EquinoxDomain.Timeline.physical_time(),
          context_end_sec: EquinoxDomain.Timeline.physical_time(),

          # ---- 下游所需的栅格化数据 ----
          phonemes: [Phoneme.rasterized()],
          curves: term()
        }
  use EquinoxDomain.Util.Object,
    keys: [
      :track_id,
      :utterance_id,
      :start_tick,
      :end_tick,
      :core_start_sec,
      :core_end_sec,
      :context_start_sec,
      :context_end_sec,
      :phonemes,
      :curves
    ]
end
