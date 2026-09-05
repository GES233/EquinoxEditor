defmodule Neume.ExpandVectorsTest do
  @moduledoc """
  黄金向量（`test/fixtures/expand_vectors.json`）的 Elixir 侧消费。

  - 替身近似成立（`within_fake_approximation`）的用例：假 client 的输出
    必须与真 worker 的期望逐字节一致；
  - 不成立的用例：假 client 必须触发前置断言 loudly 报错，不许静默选错。

  真 worker 侧由 `priv/diffsinger/test_alignment.py` 的 `ExpandVectorsTest`
  消费同一份 fixture。
  """

  use ExUnit.Case, async: true

  alias Neume.FakePhonemes

  @vectors __DIR__
           |> Path.join("../fixtures/expand_vectors.json")
           |> Path.expand()
           |> File.read!()
           |> Jason.decode!()

  for vector_case <- @vectors["cases"] do
    name = vector_case["name"]
    words = vector_case["words"]
    groups = vector_case["groups"]
    expect = vector_case["expect"]
    within = vector_case["within_fake_approximation"]

    test "黄金向量：#{name}（替身）" do
      if unquote(within) do
        assert FakePhonemes.note_phonemes(
                 unquote(Macro.escape(words)),
                 unquote(Macro.escape(groups))
               ) ==
                 unquote(Macro.escape(expect["note_phonemes"]))
      else
        assert_raise ArgumentError, ~r/近似不成立/, fn ->
          FakePhonemes.note_phonemes(unquote(Macro.escape(words)), unquote(Macro.escape(groups)))
        end
      end
    end
  end
end
