defmodule EquinoxDomain.Port.Preset do
  @moduledoc "功能清单。"

  alias EquinoxDomain.Port.Channel

  # declarations：channel → declaration 模块（Zongzi.Intervention.Declaration 实现）注册表
  # artifact：可能产出 artifact 的通道名字
  # allow_adopt：用户准许固化/修改 artifact 的通道，必须在 declarations 与 artifact 中
  @type t :: %__MODULE__{
          name: binary(),
          declarations: %{Channel.channel() => module()},
          artifact: [Channel.channel()],
          allow_adopt: [Channel.channel()],
          metadata: %{optional(atom()) => term()}
        }

  use Zongzi.Util.Object,
    keys: [
      :name,
      declarations: %{},
      artifact: [],
      allow_adopt: [],
      metadata: %{}
    ]

  @impl true
  def validate(%__MODULE__{} = preset) do
    %__MODULE__{declarations: decls, artifact: artifacts, allow_adopt: adopts} = preset
    decl_keys = Map.keys(decls)

    unknown_artifacts = artifacts -- decl_keys
    unknown_adopts_in_decls = adopts -- decl_keys
    unknown_adopts_in_artifact = adopts -- artifacts

    cond do
      unknown_artifacts != [] ->
        {:error, {:artifact_not_in_declarations, unknown_artifacts}}

      unknown_adopts_in_decls != [] ->
        {:error, {:adopt_not_in_declarations, unknown_adopts_in_decls}}

      unknown_adopts_in_artifact != [] ->
        {:error, {:adopt_not_in_artifact, unknown_adopts_in_artifact}}

      true ->
        {:ok, preset}
    end
  end

  # ---- 序列化（EquinoxDomain.Pickle 原生对象 codec） ----

  @doc """
  摊平为 plain map（遵循 `EquinoxDomain.Pickle` 约定）。

  字段直出——`declarations` 的 channel atom 与 declaration 模块 atom 原生保留。
  """
  @spec dump(t()) :: {:ok, map()}
  def dump(%__MODULE__{} = preset) do
    {:ok,
     %{
       name: preset.name,
       declarations: preset.declarations,
       artifact: preset.artifact,
       allow_adopt: preset.allow_adopt,
       metadata: preset.metadata
     }}
  end

  @doc "从 plain map 重建 Preset（经 `new/1` 校验生效）。"
  @spec load(map()) :: {:ok, t()} | {:error, term()}
  def load(%{} = data), do: new(data)
end
