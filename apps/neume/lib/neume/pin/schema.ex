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
  | v2 pitch envelope（批次 B） | `score_pitch_v2` | `score_region_v1` | `:score` |
  | v2 duration envelope（批次 D） | `phoneme_duration_v2` | `phoneme_correspondence_v1` | `:correspondence` |
  | v2 Bezier envelope（批次 E） | `pitch_curve_v2` | `score_region_v1` | `:score` |

  `score_pitch_v2` 是自描述 envelope：`%{schema, coordinates: "note_tick",
  values: [[offset_tick, midi], ...]}`，坐标为音符内相对 tick（拖动跟随）；
  base `score_region_v1` 只钉 track/note 与坐标系，不含歌词、音素、声库
  与 runtime digest。

  `phoneme_duration_v2` 是自描述 envelope：`%{schema, values:
  [%{segment: %{unit, member, index}, duration_tick: ticks}, ...]}`，
  segment 为 stable phonology ref（`Neume.Phonology.Ref`：unit = 组头
  note_id，member = 组内序号，index = 成员内音素序号）；base
  `phoneme_correspondence_v1` 钉 track/note、unit 与全组输入事实
  （各成员歌词/显式音素）+ 字典级 phonology digest——改音高、拖动、
  模型刷新不炸；改词、词典/G2P 变化、melisma 晋升/断组会炸，由 repatch
  显式重签或重定向（见设计文档批次 D）。

  `pitch_curve_v2` 是自描述 envelope（批次 E）：`%{schema, coordinates:
  "note_tick", adapter: "bezier", points: [%{offset_tick, value,
  handle_left, handle_right}, ...]}`，anchor 坐标为音符内相对 tick
  （handle 仍是相对 anchor 的 tick/value 偏移，与 legacy 同语义），
  value 为绝对 MIDI；base 复用 `score_region_v1`（与 `score_pitch_v2`
  同构）。
  """

  @base_pin_input_v1 "pin_input_v1"
  @base_score_region_v1 "score_region_v1"
  @base_phoneme_correspondence_v1 "phoneme_correspondence_v1"
  @pitch_points_v1 "pitch_points_v1"
  @pitch_curve_v1 "pitch_curve_v1"
  @phoneme_duration_v1 "phoneme_duration_v1"
  @score_pitch_v2 "score_pitch_v2"
  @phoneme_duration_v2 "phoneme_duration_v2"
  @pitch_curve_v2 "pitch_curve_v2"
  @note_tick "note_tick"

  @legacy_payload_schemas [@pitch_points_v1, @pitch_curve_v1, @phoneme_duration_v1]

  @doc "legacy 输入事实签名底料 schema 名（`Neume.Identity`）。"
  @spec base_pin_input_v1() :: String.t()
  def base_pin_input_v1, do: @base_pin_input_v1

  @doc "v2 谱面区域底料 schema 名（批次 B）。"
  @spec base_score_region_v1() :: String.t()
  def base_score_region_v1, do: @base_score_region_v1

  @doc "v2 correspondence 底料 schema 名（批次 D）。"
  @spec base_phoneme_correspondence_v1() :: String.t()
  def base_phoneme_correspondence_v1, do: @base_phoneme_correspondence_v1

  @doc "v2 pitch envelope 的 payload schema 名。"
  @spec score_pitch_v2() :: String.t()
  def score_pitch_v2, do: @score_pitch_v2

  @doc "v2 duration envelope 的 payload schema 名（批次 D）。"
  @spec phoneme_duration_v2() :: String.t()
  def phoneme_duration_v2, do: @phoneme_duration_v2

  @doc "v2 Bezier envelope 的 payload schema 名（批次 E）。"
  @spec pitch_curve_v2() :: String.t()
  def pitch_curve_v2, do: @pitch_curve_v2

  @doc "音符内相对 tick 坐标系名。"
  @spec note_tick() :: String.t()
  def note_tick, do: @note_tick

  @doc "legacy payload schema 名单（lowering 回退资格判定用）。"
  @spec legacy_payload_schemas() :: [String.t()]
  def legacy_payload_schemas, do: @legacy_payload_schemas

  @doc """
  payload schema 的世代号（1 = legacy，2 = v2）。replace_pin 的降级门卫用：
  只允许同世代或向上替换，拒绝 v2 → legacy。
  """
  @spec payload_generation(String.t()) :: 1 | 2
  def payload_generation(schema) when schema in @legacy_payload_schemas, do: 1
  def payload_generation(@score_pitch_v2), do: 2
  def payload_generation(@phoneme_duration_v2), do: 2
  def payload_generation(@pitch_curve_v2), do: 2

  @doc "构造 `score_pitch_v2` envelope（`values` 为 `[[offset_tick, midi], ...]`）。"
  @spec score_pitch_v2_payload([[number()]]) :: map()
  def score_pitch_v2_payload(values) when is_list(values),
    do: %{schema: @score_pitch_v2, coordinates: @note_tick, values: values}

  @doc """
  构造 `phoneme_duration_v2` envelope（批次 D）。`values` 为
  `[%{segment: %{unit, member, index}, duration_tick: ticks}, ...]`。
  """
  @spec phoneme_duration_v2_payload([map()]) :: map()
  def phoneme_duration_v2_payload(values) when is_list(values),
    do: %{schema: @phoneme_duration_v2, values: values}

  @doc """
  构造 `pitch_curve_v2` envelope（批次 E）。`points` 为
  `[%{offset_tick, value, handle_left, handle_right}, ...]`（handle 可 nil）。
  浅构造，逐点形状校验归 `Neume.PitchCurve.normalize_v2/1` 与 channel 语义。
  """
  @spec pitch_curve_v2_payload([map()]) :: map()
  def pitch_curve_v2_payload(points) when is_list(points),
    do: %{schema: @pitch_curve_v2, coordinates: @note_tick, adapter: "bezier", points: points}

  @doc "分派 pitch payload 的 schema 名。"
  @spec pitch_payload(term()) :: {:ok, String.t()} | {:error, term()}
  def pitch_payload(points) when is_list(points), do: {:ok, @pitch_points_v1}
  def pitch_payload(%{format: :pitch_curve_v1}), do: {:ok, @pitch_curve_v1}

  def pitch_payload(%{schema: @score_pitch_v2, coordinates: @note_tick, values: values})
      when is_list(values),
      do: {:ok, @score_pitch_v2}

  def pitch_payload(%{schema: @score_pitch_v2} = other),
    do: {:error, {:invalid_score_pitch_v2, other}}

  def pitch_payload(%{
        schema: @pitch_curve_v2,
        coordinates: @note_tick,
        adapter: "bezier",
        points: points
      })
      when is_list(points),
      do: {:ok, @pitch_curve_v2}

  def pitch_payload(%{schema: @pitch_curve_v2} = other),
    do: {:error, {:invalid_pitch_curve_v2, other}}

  def pitch_payload(other), do: {:error, {:unknown_pitch_payload_schema, other}}

  @doc "分派 duration payload 的 schema 名。"
  @spec duration_payload(term()) :: {:ok, String.t()} | {:error, term()}
  def duration_payload(durations) when is_list(durations), do: {:ok, @phoneme_duration_v1}

  def duration_payload(%{schema: @phoneme_duration_v2, values: values})
      when is_list(values),
      do: {:ok, @phoneme_duration_v2}

  def duration_payload(%{schema: @phoneme_duration_v2} = other),
    do: {:error, {:invalid_phoneme_duration_v2, other}}

  def duration_payload(other), do: {:error, {:unknown_duration_payload_schema, other}}
end
