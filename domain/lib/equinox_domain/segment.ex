defmodule EquinoxDomain.Segment do
  @moduledoc """
  渲染的最小上下文单位（rendering-context VO）。

  典型的运行时生成对象：`phonemes` / `curves` 字段由 Kernel 在编译期
  填充，不参与序列化。与 `EquinoxDomain.Windowing.Window`（分窗投影）
  是两个不同概念，勿混用。
  """

  import Coconut.Util.Helpers, only: [normalize_attrs: 2, strictly_normalize_attrs: 2]

  alias Coconut.Score.{Tempo, Tick}

  @type t :: %__MODULE__{
          # ---- 业务标识 ----
          track_id: Coconut.Util.ID.t(),
          start_tick: Tick.numeric_tick(),
          end_tick: Tick.numeric_tick(),

          # ---- 声学区间界点 (以秒 Sec 为单位) ----
          # 实际发声的有效区间
          core_start_sec: Tempo.physical_time(),
          core_end_sec: Tempo.physical_time(),
          context_start_sec: Tempo.physical_time(),
          context_end_sec: Tempo.physical_time(),

          # ---- 下游所需的栅格化数据（Kernel 编译期填充，不序列化） ----
          phonemes: [term()] | nil,
          curves: term() | nil
        }

  @keys [
    :track_id,
    :start_tick,
    :end_tick,
    :core_start_sec,
    :core_end_sec,
    :context_start_sec,
    :context_end_sec,
    phonemes: nil,
    curves: nil
  ]
  defstruct @keys

  @doc "创建 Segment；`:track_id` 与 tick / 秒界点必填，`phonemes` / `curves` 可后填。"
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
      struct(__MODULE__, normalized) |> validate()
    end
  end

  @doc "更新字段（Kernel 编译期填充 `phonemes` / `curves` 走这里）。"
  @spec update(t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def update(%__MODULE__{} = segment, attrs) do
    with {:ok, normalized} <- strictly_normalize_attrs(attrs, @keys) do
      struct(segment, normalized) |> validate()
    end
  end

  @doc "校验：tick 区间合法（`0 <= start_tick < end_tick`）。"
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{start_tick: s, end_tick: e} = segment) do
    if is_integer(s) and is_integer(e) and s >= 0 and e > s do
      {:ok, segment}
    else
      {:error, {:invalid_segment_span, {s, e}}}
    end
  end
end
