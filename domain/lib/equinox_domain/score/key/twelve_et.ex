defmodule EquinoxDomain.Score.Key.TwelveET do
  @moduledoc """
  十二平均律实现。
  内部以 MIDI 编号（整数）存储。
  """
  use EquinoxDomain.Score.Key

  defstruct [:midi]

  @impl true
  def new(midi) when is_number(midi), do: %__MODULE__{midi: midi}

  @impl true
  def from_midi(midi, _ctx), do: {:ok, new(midi)}

  @impl true
  def from_score(_score_data, _type, _ctx), do: {:error, :not_implemented}

  defimpl Inner, for: __MODULE__ do
    def to_midi(%{midi: midi}), do: midi * 1.0

    def to_frequency(%{midi: midi}, reference), do: reference * :math.pow(2, (midi - 69) / 12)

    def to_score(_key, _type, _ctx), do: {:error, :not_implemented}
  end

  @signature "12ET"

  @impl true
  def signature, do: @signature

  @impl true
    def serialize(%__MODULE__{midi: midi}) do
      {:ok,
       %{
         "__scope__" => "key",
         "__signature__" => @signature,
         "midi" => midi
       }}
    end

    @impl true
    def deserialize(%{
         "__scope__" => "key",
         "__signature__" => @signature,
         "midi" => midi
        }) do
      with true <- is_number(midi) do
        {:ok, %__MODULE__{midi: midi}}
      else
        false -> {:error, {:invalid_data, __MODULE__, :is_not_number, midi}}
      end
    end

    def deserialize(%{"__scope__" => other_type}),
      do: {:error, {:invalid_data, __MODULE__, :scope_incorrect, other_type}}
end
