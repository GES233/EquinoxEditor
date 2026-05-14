defmodule EquinoxDomain.Command.AdoptRequest do
  @moduledoc """
  采纳请求——引擎产出的物理时间数据回写 Track 的入口。

  引擎产出的是物理时间采样，需先由调用方用 TempoMap 转换为 Tick 后，
  再通过 AdoptRequest 写入 Track.data_channels。
  """

  alias EquinoxDomain.{
    Util.ID,
    Timeline.Tick,
    Score.Track,
    Port.Channel,
    LayerChunk
  }

  @type t :: %__MODULE__{
          track_id: ID.t(Track),
          time_range: {Tick.numeric_tick(), Tick.numeric_tick()},
          channel: Channel.channel(),
          tick_payload: term()
        }

  use EquinoxDomain.Util.Object,
    keys: [
      :track_id,
      :channel,
      :tick_payload,
      time_range: {0, 0}
    ]

  @doc """
  将采纳请求写入 Track，返回更新后的 Track。

  在 `track.data_channels[channel]` 中插入一条 `source: :adopted` 的 LayerChunk。
  若该 channel 下已有 adopted chunk 与新区间重叠，旧 chunk 被覆盖区间会被裁剪。

  ## Examples

      iex> AdoptRequest.adopt(%AdoptRequest{...}, track)
      {:ok, %Track{data_channels: %{"phoneme" => [%LayerChunk{source: :adopted, ...}]}}}
  """
  @spec adopt(t(), Track.t()) :: {:ok, Track.t()} | {:error, term()}
  def adopt(%__MODULE__{} = request, %Track{} = track) do
    %__MODULE__{
      time_range: {start_tick, end_tick},
      channel: channel,
      tick_payload: payload
    } = request

    with {:ok, new_chunk} <-
           LayerChunk.new(
             start_tick: start_tick,
             end_tick: end_tick,
             payload: payload,
             source: :adopted
           ) do
      [data_channels: update_channels(track, channel, new_chunk, start_tick, end_tick)]
      |> then(&Track.update(track, &1))
    end
  end

  defp update_channels(track, channel, new_chunk, start_tick, end_tick) do
    Map.update(track.data_channels, channel, [new_chunk], fn existing ->
      # 裁剪旧 adopted chunk 与新区间重叠的部分，保留非重叠部分
      trimmed =
        Enum.flat_map(existing, fn ch ->
          cond do
            # 无重叠，保留原样
            ch.start_tick >= end_tick or ch.end_tick <= start_tick ->
              [ch]

            # 新区间完全覆盖旧 chunk，丢弃
            ch.start_tick >= start_tick and ch.end_tick <= end_tick ->
              []

            # 新区间在旧 chunk 中间切开
            ch.start_tick < start_tick and ch.end_tick > end_tick ->
              [
                %{ch | end_tick: start_tick},
                %{ch | start_tick: end_tick}
              ]

            # 新区间覆盖旧 chunk 头部
            ch.start_tick >= start_tick ->
              [%{ch | start_tick: end_tick}]

            # 新区间覆盖旧 chunk 尾部
            true ->
              [%{ch | end_tick: start_tick}]
          end
        end)

      [new_chunk | trimmed]
    end)
  end
end
