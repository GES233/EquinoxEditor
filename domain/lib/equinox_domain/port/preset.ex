defmodule EquinoxDomain.Port.Preset do
  @moduledoc """
  功能清单（轨道可用的 channel 注册表）。

  coconut 时代注册表的 value 是 `Coconut.Render.Channel` 实现模块
  （`projection/2` + `target/0|1`），取代旧 Declaration 模块。

  - `channels`：channel atom → channel 模块注册表
  - `artifact`：可能产出 artifact 的通道名，必须已在 `channels` 注册
  - `allow_adopt`：用户准许固化/修改 artifact 的通道，必须在
    `channels` 与 `artifact` 中
  """

  import Coconut.Util.Helpers, only: [normalize_attrs: 2, strictly_normalize_attrs: 2]

  alias EquinoxDomain.Port.Channel

  @type t :: %__MODULE__{
          name: binary(),
          channels: %{Channel.channel() => module()},
          artifact: [Channel.channel()],
          allow_adopt: [Channel.channel()],
          metadata: %{optional(atom()) => term()}
        }

  @keys [
    :name,
    channels: %{},
    artifact: [],
    allow_adopt: [],
    metadata: %{}
  ]
  defstruct @keys

  @doc "创建预设；`:name` 必填。"
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
      struct(__MODULE__, normalized) |> validate()
    end
  end

  @doc "更新预设字段，重新校验。"
  @spec update(t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def update(%__MODULE__{} = preset, attrs) do
    with {:ok, normalized} <- strictly_normalize_attrs(attrs, @keys) do
      struct(preset, normalized) |> validate()
    end
  end

  @doc "校验：name 为字符串；`artifact` / `allow_adopt` 引用须已注册。"
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{name: name}) when not is_binary(name),
    do: {:error, {:invalid_preset_name, name}}

  def validate(%__MODULE__{} = preset) do
    %__MODULE__{channels: channels, artifact: artifacts, allow_adopt: adopts} = preset
    channel_keys = Map.keys(channels)

    unknown_artifacts = artifacts -- channel_keys
    unknown_adopts_in_channels = adopts -- channel_keys
    unknown_adopts_in_artifact = adopts -- artifacts

    cond do
      unknown_artifacts != [] ->
        {:error, {:artifact_not_in_channels, unknown_artifacts}}

      unknown_adopts_in_channels != [] ->
        {:error, {:adopt_not_in_channels, unknown_adopts_in_channels}}

      unknown_adopts_in_artifact != [] ->
        {:error, {:adopt_not_in_artifact, unknown_adopts_in_artifact}}

      true ->
        {:ok, preset}
    end
  end

  # ---- 序列化（plain map codec，与 Coconut.Pickle 约定一致） ----

  @doc "摊平为 plain map——channel atom 与模块 atom 原生保留。"
  @spec dump(t()) :: {:ok, map()}
  def dump(%__MODULE__{} = preset) do
    {:ok,
     %{
       name: preset.name,
       channels: preset.channels,
       artifact: preset.artifact,
       allow_adopt: preset.allow_adopt,
       metadata: preset.metadata
     }}
  end

  @doc "从 plain map 重建 Preset（经 `new/1` 校验生效）。"
  @spec load(map()) :: {:ok, t()} | {:error, term()}
  def load(%{} = data), do: new(data)
end
