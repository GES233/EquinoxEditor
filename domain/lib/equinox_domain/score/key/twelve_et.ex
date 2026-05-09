defmodule EquinoxDomain.Score.Key.TwelveET do
  @moduledoc """
  十二平均律实现。
  内部以 MIDI 编号（整数）存储。
  """
  @behaviour EquinoxDomain.Score.Key
  alias EquinoxDomain.Score.Key.Inner

  defstruct [:midi]

  @impl true
  def new(midi) when is_number(midi), do: %__MODULE__{midi: midi}

  @impl true
  def from_midi(midi, _ctx) do
    {:ok, new(midi)}
  end

  @impl true
  def from_score(_score_data, _type, _ctx) do
    {:error, :not_implemented}
  end

  defimpl Inner, for: __MODULE__ do
    def to_midi(%{midi: midi}), do: midi * 1.0

    def to_frequency(%{midi: midi}, reference) do
      reference * :math.pow(2, (midi - 69) / 12)
    end

    def to_score(_key, _type, _ctx) do
      {:error, :not_implemented}
    end
  end
end
