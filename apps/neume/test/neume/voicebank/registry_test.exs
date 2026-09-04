defmodule Neume.Voicebank.RegistryTest do
  use ExUnit.Case, async: true

  alias Neume.Voicebank.{Entry, Registry}
  alias Neume.VoicebankFixture

  @tag tmp_dir: true
  test "发现多个声库，并把无效目录作为诊断返回", %{tmp_dir: tmp_dir} do
    first = VoicebankFixture.diffsinger(tmp_dir, directory: "alpha", name: "Alpha")
    second = VoicebankFixture.diffsinger(tmp_dir, directory: "beta", name: "Beta")
    File.mkdir_p!(Path.join(tmp_dir, "not-a-voicebank"))

    assert {:ok, registry} = Registry.discover(tmp_dir)
    assert Enum.map(Registry.list(registry), & &1.name) == ["Alpha (Stock)", "Beta (Stock)"]
    assert Enum.all?(Registry.list(registry), &(&1.mode == :stock))
    assert Enum.any?(registry.diagnostics, &String.ends_with?(&1.path, "not-a-voicebank"))

    assert Enum.map(Registry.list(registry), & &1.manifest.root) |> Enum.sort() ==
             Enum.sort([Path.expand(first), Path.expand(second)])
  end

  @tag tmp_dir: true
  test "Stock 与现有 Modified manifest 是两个工程身份，发现不执行修改", %{tmp_dir: tmp_dir} do
    root = VoicebankFixture.diffsinger(tmp_dir)
    assert {:ok, stock_registry} = Registry.discover(root)
    assert [%Entry{mode: :stock} = stock] = Registry.list(stock_registry)

    fp_dir =
      Path.join([
        File.cwd!(),
        "tmp",
        "onnx_fp",
        "#{String.slice(stock.manifest.digest, 0, 16)}-v1"
      ])

    on_exit(fn -> File.rm_rf(fp_dir) end)
    write_fp_manifest!(fp_dir)

    assert {:ok, registry} = Registry.discover(root, fp_python: ["definitely-not-called"])

    assert [%Entry{mode: :modified} = modified, %Entry{mode: :stock} = stock] =
             Registry.list(registry) |> Enum.sort_by(& &1.mode)

    refute modified.id == stock.id
    refute modified.signature == stock.signature
    assert modified.signature.engine == :diffsinger_modified
    assert stock.signature.engine == :diffsinger_stock
    assert Registry.resolve(registry, modified.signature) == {:ok, modified}
  end

  @tag tmp_dir: true
  test "显式 prepare_modified 才允许构建变体", %{tmp_dir: tmp_dir} do
    root = VoicebankFixture.diffsinger(tmp_dir)
    assert {:ok, registry} = Registry.discover(root)
    assert [%Entry{id: stock_id}] = Registry.list(registry)

    assert {:error, {:fp_manifest_missing, _}} =
             Registry.prepare_modified(registry, stock_id,
               build?: false,
               dir: Path.join(tmp_dir, "missing-fp")
             )
  end

  @tag tmp_dir: true
  test "discover_configured 使用应用配置中的发现根", %{tmp_dir: tmp_dir} do
    VoicebankFixture.diffsinger(tmp_dir)
    previous = Application.get_env(:neume, :voicebank_roots)
    Application.put_env(:neume, :voicebank_roots, [tmp_dir])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:neume, :voicebank_roots, previous),
        else: Application.delete_env(:neume, :voicebank_roots)
    end)

    assert {:ok, registry} = Registry.discover_configured()
    assert [%Entry{mode: :stock}] = Registry.list(registry)
  end

  defp write_fp_manifest!(dir) do
    File.mkdir_p!(dir)

    manifest =
      Map.new(~w(pitch_predict variance acoustic vocoder), fn key ->
        path = Path.join(dir, "#{key}.onnx")
        File.write!(path, key)
        {key, %{"path" => path, "noise" => []}}
      end)

    File.write!(Path.join(dir, "fp_manifest.json"), Jason.encode!(manifest))
  end
end
