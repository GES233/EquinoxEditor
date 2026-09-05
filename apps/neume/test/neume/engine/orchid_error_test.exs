defmodule Neume.Engine.OrchidErrorTest do
  @moduledoc """
  Orchid 执行错误收敛：剥掉调度上下文（巨型 term），保留机器可判的
  内层 `reason`/`step_id`/`kind`；幂等；非 orchid 形态原样放行。
  """

  use ExUnit.Case, async: true

  alias Neume.Engine.OrchidError

  test "收敛 {:orchid_error, ...}：丢 context，留内层 reason/step_id/kind" do
    error = %Orchid.Error{
      reason: {:phoneme_duration_overflow, "n1"},
      context: %{fat: String.duplicate("x", 100_000)},
      step_id: :root,
      kind: :logic
    }

    assert {:orchid_error, nil, slim} = OrchidError.slim({:orchid_error, nil, error})
    assert slim.reason == {:phoneme_duration_overflow, "n1"}
    assert slim.step_id == :root
    assert slim.kind == :logic
    refute Map.has_key?(slim, :context)
    # 收敛后的条目量级与 context 大小无关。
    assert byte_size(inspect(slim)) < 1_000
  end

  test "非 orchid 形态原样放行；收敛幂等" do
    assert OrchidError.slim(:boom) == :boom
    assert OrchidError.slim({:some, :error}) == {:some, :error}

    once =
      OrchidError.slim(
        {:orchid_error, "recipe",
         %Orchid.Error{reason: :x, context: %{}, step_id: nil, kind: :exception}}
      )

    assert OrchidError.slim(once) == once
  end

  test "富结构 step_id 降为 inspect 摘要" do
    error = %Orchid.Error{
      reason: :x,
      context: nil,
      step_id: {MapSet.new([:in]), MapSet.new([:out])},
      kind: :exit
    }

    assert {:orchid_error, _recipe, %{step_id: step_id}} =
             OrchidError.slim({:orchid_error, nil, error})

    assert is_binary(step_id)
  end
end
