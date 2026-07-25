defmodule EquinoxDomain.Command.AdoptRequest do
  @moduledoc """
  采纳请求——把引擎产出挂载为用户所有的 intervention（锚在指定音符上）。

  取代旧的 tick 区间 LayerChunk 回写：采纳不再按时间区间切片存储，
  而是生成一条 channel 干预，锚定 `seq_id` 对应的三元组锚；
  结构死活由后续 rebase 判定，语义有效性由 declaration 的
  snapshot/resolve 判定。
  """

  alias EquinoxDomain.{Port.Channel, Score.Track}
  alias Zongzi.{Intervention, Util.ID}
  alias Zongzi.Timeline.SeqID

  @type t :: %__MODULE__{
          channel: Channel.channel(),
          declaration: module(),
          seq_id: SeqID.t(),
          payload: term()
        }

  use Zongzi.Util.Object,
    keys: [
      :channel,
      :declaration,
      :seq_id,
      :payload
    ]

  @doc """
  将采纳请求挂载到 Track，返回 `{:ok, track, intervention}`。

  新建的 intervention 以 `"iv_"` 前缀分配 id，经
  `Track.mount_intervention/5` 派生锚点并写入 snapshot。
  """
  @spec adopt(t(), Track.t(), term()) :: {:ok, Track.t(), Intervention.t()} | {:error, term()}
  def adopt(%__MODULE__{} = request, %Track{} = track, projection) do
    with {:ok, int} <-
           Intervention.new(
             id: ID.generate_id("iv_"),
             channel: request.channel,
             declaration: request.declaration
           ) do
      Track.mount_intervention(track, int, request.payload, request.seq_id, projection)
    end
  end
end
