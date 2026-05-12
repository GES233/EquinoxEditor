defmodule EquinoxDomain.Score.Key.TwelveET do
  @moduledoc """
  十二平均律实现。
  内部以 MIDI 编号（整数）存储。
  """
  use EquinoxDomain.Score.Key

  defstruct [:midi]

  # ---- Key 行为 ----

  @impl true
  def new(midi) when is_number(midi), do: {:ok, %__MODULE__{midi: midi}}

  @impl true
  def from_midi(midi, _ctx), do: new(midi)

  @impl true
  def from_score(_score_data, _type, _ctx), do: {:error, :not_implemented}

  # ---- Plugable 行为 ----

  @impl true
  def signature, do: "12ET"

  @impl true
  def dump(%__MODULE__{midi: midi}), do: {:ok, %{"midi" => midi}}

  @impl true
  def load(%{"midi" => midi}) when is_number(midi), do: new(midi)

  def load(_), do: {:error, {:invalid_payload, __MODULE__}}

  # ---- Inner 协议实现 ----

  defimpl Inner, for: __MODULE__ do
    def to_midi(%{midi: midi}), do: midi * 1.0

    def to_frequency(%{midi: midi}, reference), do: reference * :math.pow(2, (midi - 69) / 12)

    def signature(_key), do: "12ET"

    def to_score(_key, _type, _ctx), do: {:error, :not_implemented}
  end
end
