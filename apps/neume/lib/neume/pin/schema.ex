defmodule Neume.Pin.Schema do
  @moduledoc """
  pin payload / base schema 的命名与 payload 分派 helper
  （`design-2026-09-pin-carriers` §5 版本化 envelope）。

  迁移期 schema 一览：

  | payload | payload schema | base schema | carrier |
  |---|---|---|---|
  | 旧 pitch 点列 `[[tick, midi]]` | `pitch_points_v1` | `pin_input_v1` | `:score` |
  | Bezier plain map | `pitch_curve_v1` | `pin_input_v1` | `:score` |
  | 旧 duration 点列 `[[ph_index, tick]]` | `phoneme_duration_v1` | `pin_input_v1` | `:correspondence` |

  v2（`score_pitch_v2` / `phoneme_duration_v2`，base `score_region_v1`
  等）见设计文档批次 B/D；本模块当前只分派 legacy payload，不产生 v2。
  """

  @base_pin_input_v1 "pin_input_v1"
  @pitch_points_v1 "pitch_points_v1"
  @pitch_curve_v1 "pitch_curve_v1"
  @phoneme_duration_v1 "phoneme_duration_v1"

  @doc "legacy 输入事实签名底料 schema 名（`Neume.Identity`）。"
  @spec base_pin_input_v1() :: String.t()
  def base_pin_input_v1, do: @base_pin_input_v1

  @doc "分派 pitch payload 的 schema 名。"
  @spec pitch_payload(term()) :: {:ok, String.t()} | {:error, term()}
  def pitch_payload(points) when is_list(points), do: {:ok, @pitch_points_v1}
  def pitch_payload(%{format: :pitch_curve_v1}), do: {:ok, @pitch_curve_v1}
  def pitch_payload(other), do: {:error, {:unknown_pitch_payload_schema, other}}

  @doc "分派 duration payload 的 schema 名。"
  @spec duration_payload(term()) :: {:ok, String.t()} | {:error, term()}
  def duration_payload(durations) when is_list(durations), do: {:ok, @phoneme_duration_v1}
  def duration_payload(other), do: {:error, {:unknown_duration_payload_schema, other}}
end
