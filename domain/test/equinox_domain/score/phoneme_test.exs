defmodule EquinoxDomain.Score.PhonemeTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Score.Phoneme

  test "new/1：symbol 与 type 必填且合法" do
    assert {:ok, %Phoneme{symbol: "a", type: :vowel}} = Phoneme.new(symbol: "a", type: :vowel)

    assert {:error, {:invalid_phoneme_symbol, _}} = Phoneme.new(symbol: "", type: :vowel)
    assert {:error, {:invalid_phoneme_symbol, _}} = Phoneme.new(type: :vowel)
    assert {:error, {:invalid_phoneme_type, _}} = Phoneme.new(symbol: "a", type: :glottal)
    assert {:error, {:invalid_phoneme_type, _}} = Phoneme.new(symbol: "a")
  end

  test "update/2 更新并复验" do
    {:ok, phoneme} = Phoneme.new(symbol: "k", type: :consonant)

    assert {:ok, %Phoneme{symbol: "g"}} = Phoneme.update(phoneme, symbol: "g")
    assert {:error, {:invalid_phoneme_type, _}} = Phoneme.update(phoneme, type: nil)
    assert {:error, {:extra_attrs, _}} = Phoneme.update(phoneme, timing: 1.0)
  end
end
