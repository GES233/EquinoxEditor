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

  @type t :: key_struct()

  # ---- 基本的 CRUD ----

  # 新建
  @callback new(any()) :: {:ok, key_struct()} | {:error, term()}

  # ---- 创建 ----

  # 当前阶段暂时保留，不需要具体实现，MIDI 同理
  @callback from_score(score_data :: term(), type :: atom(), ctx :: term()) ::
              {:ok, key_struct()} | {:error, term()}

  @callback from_midi(midi_note :: number(), ctx :: term()) ::
              {:ok, key_struct()} | {:error, term()}

  # ---- 去向 ----

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

  # ---- Scope ----

  @scope "key"

  def scope, do: @scope

  # ---- Facade API ----

  def new(attrs, module), do: module.new(attrs)

  def from_score(data, type, ctx, module), do: module.from_score(data, type, ctx)

  def from_midi(midi, ctx, module), do: module.from_midi(midi, ctx)

  defdelegate to_score(key, type, ctx), to: Inner

  defdelegate to_midi(key), to: Inner

  defdelegate to_frequency(key, reference), to: Inner

  # ---- 序列化 ----

  alias EquinoxDomain.Util.Pickle.Plugable

  @doc "将 Key 实例序列化为 Plugable 信封"
  @spec serialize(t()) :: {:ok, Plugable.tagged()} | {:error, term()}
  def serialize(key) do
    Plugable.dispatch_dump(key, @scope, key.__struct__)
  end

  @doc "从 Plugable 信封反序列化为 Key 实例，需要 registry 查找实现模块"
  @spec deserialize(Plugable.tagged(), Plugable.registry()) :: {:ok, t()} | {:error, term()}
  def deserialize(payload, registry) do
    Plugable.dispatch_load(payload, @scope, registry)
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour EquinoxDomain.Score.Key
      alias EquinoxDomain.Score.Key.Inner
      use EquinoxDomain.Util.Pickle.Plugable
    end
  end
end
