defmodule Neume.VoicebankSelectionTest do
  use ExUnit.Case, async: true

  alias Neume.Editor
  alias Neume.Voicebank.Registry
  alias Neume.VoicebankFixture

  defmodule UnusedClient do
    @behaviour Neume.Engine.DiffSingerWorker
    @impl true
    def call(_payload, _config), do: {:error, :not_used}
  end

  @tag tmp_dir: true
  test "注册表选择把 Stock 身份写入工程，并可据此重新打开", %{tmp_dir: tmp_dir} do
    VoicebankFixture.diffsinger(tmp_dir)
    assert {:ok, registry} = Registry.discover(tmp_dir)
    assert [stock] = Registry.list(registry)

    opts = [
      voicebank_registry: registry,
      voicebank_id: stock.id,
      diffsinger_client: UnusedClient,
      output_dir: Path.join(tmp_dir, "renders")
    ]

    assert {:ok, editor} = Editor.new(opts)
    assert {:ok, project} = Coconut.project(editor.session)
    assert project.voicebank == nil

    assert get_in(project.workspace.tracks["vocal"].extras, [:neume, :voicebank]) ==
             stock.signature

    assert {:ok, reopened} = Editor.open(project, voicebank_registry: registry)
    assert reopened.pipeline_state.worker_config.fp_manifest == nil
  end

  @tag tmp_dir: true
  test "工程打开时按 signature 自动解析，无需再次提供 id", %{tmp_dir: tmp_dir} do
    VoicebankFixture.diffsinger(tmp_dir)
    assert {:ok, registry} = Registry.discover(tmp_dir)
    stock = Enum.find(Registry.list(registry), &(&1.mode == :stock))
    assert stock

    assert {:ok, editor} =
             Editor.new(
               voicebank_registry: registry,
               voicebank_id: stock.id,
               diffsinger_client: UnusedClient
             )

    assert {:ok, project} = Coconut.project(editor.session)
    assert {:ok, reopened} = Editor.open(project, voicebank_registry: registry)
    assert reopened.pipeline_state.manifest.root == stock.manifest.root
  end

  @tag tmp_dir: true
  test "目录入口必须显式选择 Stock 或 Modified", %{tmp_dir: tmp_dir} do
    voicebank = VoicebankFixture.diffsinger(tmp_dir)

    assert {:error, :voicebank_mode_required} =
             Editor.new(
               voicebank_path: voicebank,
               diffsinger_client: UnusedClient
             )
  end
end
