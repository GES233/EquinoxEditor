defmodule EquinoxDomain.Score.Key do
  @moduledoc """
  关于音高的领域模型。

  因为调式的不同，也会采用适配器的模式。

  主要负责两个方面数据的互换：

  * 谱表的数据
  * MIDI/频率的数据

  其以内部类型被保留/序列化。
  """

  @type key_struct :: struct()

  @callback new(any()) :: key_struct()

  @callback from_score(score_data :: term(), type :: atom(), ctx :: term()) ::
              {:ok, key_struct()} | {:error, term()}

  @callback from_midi(midi_note :: number(), ctx :: term()) ::
              {:ok, key_struct()} | {:error, term()}

  # ---- 调用实现了行为的模块 ----

  def new(attrs, module), do: module.new(attrs)

  def from_score(data, type, ctx, module), do: module.from_score(data, type, ctx)

  def from_midi(midi, ctx, module), do: module.from_midi(midi, ctx)

  defprotocol Inner do
    @moduledoc "部分去向的操作集合"

    # ---- 谱表 ----

    @doc "根据谱表类型（如 :staff, :numbered）转换为谱表渲染所需的数据"
    def to_score(key, type, ctx)
    # 比方说十二平均律的钢琴卷帘窗转五线谱就需要调号作为上下文

    # ---- MIDI /频率 ----

    @doc "转换到 MIDI 编号（支持小数）"
    def to_midi(key)

    @doc "转换到绝对频率 (Hz)"
    def to_frequency(key, reference)
  end
end
