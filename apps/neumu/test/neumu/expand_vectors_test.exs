defmodule Neumu.ExpandVectorsTest do
  @moduledoc """
  黄金向量在 neumu 假 client（`Neumu.ProjectStub.PhonemesClient`）上的
  一致性消费；fixture 与真身语义见
  `apps/neume/test/fixtures/expand_vectors.json`。
  """

  use ExUnit.Case, async: true

  alias Neumu.ProjectStub.PhonemesClient

  @vectors __DIR__
           |> Path.join("../../../neume/test/fixtures/expand_vectors.json")
           |> Path.expand()
           |> File.read!()
           |> Jason.decode!()

  for vector_case <- @vectors["cases"] do
    name = vector_case["name"]
    words = vector_case["words"]
    groups = vector_case["groups"]
    expect = vector_case["expect"]
    within = vector_case["within_fake_approximation"]

    test "黄金向量：#{name}（neumu 替身）" do
      payload = %{
        action: "expand",
        words: unquote(Macro.escape(words)),
        groups: unquote(Macro.escape(groups))
      }

      if unquote(within) do
        assert {:ok, %{"note_phonemes" => actual}} = PhonemesClient.call(payload, %{})
        assert actual == unquote(Macro.escape(expect["note_phonemes"]))
      else
        assert_raise ArgumentError, ~r/近似不成立/, fn ->
          PhonemesClient.call(payload, %{})
        end
      end
    end
  end
end
