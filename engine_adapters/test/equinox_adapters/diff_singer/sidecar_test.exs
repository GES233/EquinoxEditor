defmodule EquinoxAdapters.DiffSinger.SidecarTest do
  use ExUnit.Case, async: false

  alias EquinoxAdapters.DiffSinger.Sidecar

  # fake sidecar 只需 Jason 在代码路径上（注入其 ebin）
  defp fake_args do
    [
      "-pa",
      Path.join(Mix.Project.build_path(), "lib/jason/ebin"),
      Path.expand("../../support/fake_ds_sidecar.exs", __DIR__)
    ]
  end

  defp start_fake(name) do
    out_dir =
      Path.join(System.tmp_dir!(), "ds_sidecar_test_#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Sidecar.ensure_started(name, command: "elixir", args: fake_args(), out_dir: out_dir)

    {pid, out_dir}
  end

  test "ensure_started 去重 + out_dir + predict/render 解包" do
    {pid, out_dir} = start_fake("fake_vb_main")

    # 同 model_root 复用同一进程
    assert {:ok, ^pid} = Sidecar.ensure_started("fake_vb_main")
    assert Sidecar.out_dir(pid) == out_dir

    words = [[[["zh", "l"], ["zh", "iang"]], 0.5, 60]]

    assert {:ok, %{ph_dur: [42], total_frames: 42}} = Sidecar.predict(pid, words)

    out_path = Path.join(out_dir, "track_a_0.wav")

    assert {:ok, %{path: ^out_path, sample_rate: 44_100, frames: 100, lead_in_sec: 0.5}} =
             Sidecar.render(pid, words, out_path: out_path, seed: 42)

    assert File.exists?(out_path)

    # lead_in_sec 透传（对齐回放路径）
    assert {:ok, %{lead_in_sec: 0.42}} =
             Sidecar.render(pid, words,
               out_path: out_path,
               ph_dur_override: [40, 10, 42],
               lead_in_sec: 0.42
             )

    # align：绝对边界解包（atom 键 + note_index nil）
    assert {:ok,
            %{
              phonemes: [
                %{symbol: "SP", start_frame: 0, end_frame: 40, note_index: nil},
                %{symbol: "l", start_frame: 40, end_frame: 50, note_index: 0},
                %{symbol: "iang", start_frame: 50, end_frame: 92, note_index: 0}
              ],
              ph_dur: [40, 10, 420],
              lead_in_sec: 0.5,
              total_frames: 92
            }} = Sidecar.align(pid, words)
  end

  test "工具错误：isError 透传为 {:error, {:tool_error, _}}" do
    {pid, _out_dir} = start_fake("fake_vb_fail")

    assert {:error, {:tool_error, "boom"}} = GenServer.call(pid, {:tool_call, "fail", %{}})
  end

  test "未知工具：JSON-RPC error 透传" do
    {pid, _out_dir} = start_fake("fake_vb_unknown")

    assert {:error, %{"code" => -32_601}} = GenServer.call(pid, {:tool_call, "nope", %{}})
  end
end
