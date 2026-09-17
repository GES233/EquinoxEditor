defmodule EquinoxWeb.Demo do
  @moduledoc "首个 UI 里程碑的演示工程；真实 History，使用内置 mock runtime，不运行声学推理。"

  alias Neume.Voicebank.{Entry, Registry}

  @project_id "equinox-ui-demo"
  def project_id, do: @project_id

  def open(project_id \\ @project_id) do
    entries = Enum.map([{"a", "演示声库 A"}, {"b", "演示声库 B"}], &entry/1)

    case Neumu.create_project(project_id, voicebank_registry: Registry.new(entries)) do
      {:ok, _pid} -> seed(project_id, hd(entries).id)
      {:error, {:project_already_open, ^project_id}} -> :ok
      {:error, _} = error -> error
    end
  end

  defp seed(project_id, voicebank_id) do
    with {:ok, _} <- Neumu.add_track(project_id, "lead", voicebank_id, %{name: "主唱"}),
         {:ok, _} <-
           Neumu.insert_note(project_id, "lead", "n1", :head, {480, 960}, %{
             pitch: 60,
             lyric: "啦"
           }) do
      :ok
    else
      {:error, _} = error ->
        Neumu.close_project(project_id)
        error
    end
  end

  defp entry({suffix, name}) do
    signature = %{name: name, engine: :mock, digest: "equinox-ui-demo-#{suffix}"}

    %Entry{
      id: Entry.id(signature),
      name: name,
      provider: __MODULE__,
      runtime: Neume.Engine.MockPipeline,
      mode: :demo,
      signature: signature
    }
  end
end
