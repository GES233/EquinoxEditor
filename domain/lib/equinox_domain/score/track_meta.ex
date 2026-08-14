defmodule EquinoxDomain.Score.TrackMeta do
  @moduledoc """
  轨道元数据侧表项——equinox 特有的轨道附加信息（混音、预设、UI 状态）。

  与 coconut 的区分：`Coconut.Edit.Track` 承载音符/干预真相并进入
  History（可 undo）；TrackMeta 是宿主侧表，**不进 History、不可 undo**，
  按 `track_id` 挂在 `EquinoxDomain.Score.Project.tracks_meta` 上。

  纯数据 VO：无 id（身份即侧表键），手写 new/update/validate + dump/load。
  """

  import Coconut.Util.Helpers, only: [normalize_attrs: 2, strictly_normalize_attrs: 2]

  alias EquinoxDomain.Port.Preset

  @type t :: %__MODULE__{
          mix_automation: map(),
          gain: number(),
          pan: number(),
          mute: boolean(),
          solo: boolean(),
          presets: %{binary() => Preset.t()},
          active_preset: nil | binary(),
          ui_state: map(),
          metadata: map()
        }

  @keys [
    mix_automation: %{},
    gain: 1.0,
    pan: 0.0,
    mute: false,
    solo: false,
    presets: %{},
    active_preset: nil,
    ui_state: %{},
    metadata: %{}
  ]
  defstruct @keys

  @doc "创建轨道元数据（全部字段有缺省值）。"
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ %{}) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
      struct(__MODULE__, normalized) |> validate()
    end
  end

  @doc "更新字段（只认已声明键，多余键报 `{:error, {:extra_attrs, _}}`）。"
  @spec update(t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def update(%__MODULE__{} = meta, attrs) do
    with {:ok, normalized} <- strictly_normalize_attrs(attrs, @keys) do
      struct(meta, normalized) |> validate()
    end
  end

  @doc "校验混音标量类型与预设表（逐个跑 `Preset.validate/1`）。"
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = meta) do
    cond do
      not is_number(meta.gain) -> {:error, {:invalid_gain, meta.gain}}
      not is_number(meta.pan) -> {:error, {:invalid_pan, meta.pan}}
      not is_boolean(meta.mute) -> {:error, {:invalid_mute, meta.mute}}
      not is_boolean(meta.solo) -> {:error, {:invalid_solo, meta.solo}}
      true -> validate_presets(meta)
    end
  end

  defp validate_presets(%__MODULE__{presets: presets} = meta) when is_map(presets) do
    Enum.reduce_while(presets, {:ok, meta}, fn
      {name, %Preset{} = preset}, {:ok, meta} ->
        case Preset.validate(preset) do
          {:ok, _} -> {:cont, {:ok, meta}}
          {:error, reason} -> {:halt, {:error, {:invalid_preset, name, reason}}}
        end

      {name, other}, _acc ->
        {:halt, {:error, {:invalid_preset, name, other}}}
    end)
  end

  defp validate_presets(%__MODULE__{presets: other}), do: {:error, {:invalid_presets, other}}

  # ---- 序列化（plain map codec，与 Coconut.Pickle 约定一致） ----

  @doc "摊平为 plain map（标量直出，`presets` 经 `Preset.dump/1` 逐个组合）。"
  @spec dump(t()) :: {:ok, map()}
  def dump(%__MODULE__{} = meta) do
    {:ok, presets} = dump_presets(meta.presets)

    {:ok,
     %{
       mix_automation: meta.mix_automation,
       gain: meta.gain,
       pan: meta.pan,
       mute: meta.mute,
       solo: meta.solo,
       presets: presets,
       active_preset: meta.active_preset,
       ui_state: meta.ui_state,
       metadata: meta.metadata
     }}
  end

  @doc "从 plain map 重建（经 `new/1` 校验生效）。"
  @spec load(map()) :: {:ok, t()} | {:error, term()}
  def load(%{} = data) do
    with {:ok, presets} <- load_presets(Map.get(data, :presets, %{})) do
      data
      |> Map.take([
        :mix_automation,
        :gain,
        :pan,
        :mute,
        :solo,
        :active_preset,
        :ui_state,
        :metadata
      ])
      |> Map.put(:presets, presets)
      |> new()
    end
  end

  def load(other), do: {:error, {:invalid_track_meta_dump, other}}

  # Preset.dump/1 恒 {:ok, _}（纯摊平），故直接映射
  defp dump_presets(presets) do
    {:ok,
     Map.new(presets, fn {name, preset} ->
       {:ok, dumped} = Preset.dump(preset)
       {name, dumped}
     end)}
  end

  defp load_presets(presets) when is_map(presets) do
    Enum.reduce_while(presets, {:ok, %{}}, fn {name, dumped}, {:ok, acc} ->
      case Preset.load(dumped) do
        {:ok, preset} -> {:cont, {:ok, Map.put(acc, name, preset)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp load_presets(other), do: {:error, {:invalid_presets_dump, other}}
end
