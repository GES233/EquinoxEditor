defmodule EquinoxDomain.Port.Preset do
  @moduledoc "功能清单。"

  alias EquinoxDomain.Port.{Declaration, Channel}

  # declarations：数据以及允许被 intervention 的所有数据
  # artifact：可能产出 artifact 的通道名字
  # allow_adopt：用户准许固化/修改 artifact 的通道，必须在 declarations 与 artifact 中
  @type t :: %__MODULE__{
          name: binary(),
          declarations: %{Channel.channel() => Declaration.t()},
          artifact: [Channel.channel()],
          allow_adopt: [Channel.channel()],
          metadata: %{optional(atom()) => term()}
        }

  use EquinoxDomain.Util.Object,
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
end
