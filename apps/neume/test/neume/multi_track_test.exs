defmodule Neume.MultiTrackTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.Workspace
  alias Neume.{MixPipeline, MultiTrack, TrackConfig}
  alias Neume.Voicebank.{Entry, Registry}
  alias Neume.VoicebankFixture

  @tag tmp_dir: true
  test "逐轨持久化不同声库身份，并按 signature 打开独立 runtime", %{tmp_dir: tmp_dir} do
    root = VoicebankFixture.diffsinger(tmp_dir)
    assert {:ok, registry} = Registry.discover(root)
    assert [stock] = Enum.filter(Registry.list(registry), &(&1.mode == :stock))
    modified = fake_modified(stock, tmp_dir)
    registry = %{registry | entries: Map.put(registry.entries, modified.id, modified)}

    assert {:ok, project} = empty_project()
    assert {:ok, project} = MultiTrack.add_vocal_track(project, "lead", stock)

    assert {:ok, project} =
             MultiTrack.add_vocal_track(project, "backing", modified, %{
               mix: %{gain: 0.5, pan: 1.0, mute: false}
             })

    assert project.voicebank == nil
    assert TrackConfig.voicebank(project.workspace.tracks["lead"]) == stock.signature
    assert TrackConfig.voicebank(project.workspace.tracks["backing"]) == modified.signature

    assert {:ok, runtime} =
             MultiTrack.open(project,
               voicebank_registry: registry,
               diffsinger_client: Neume.VoicebankSelectionTest.UnusedClient,
               output_dir: Path.join(tmp_dir, "renders")
             )

    assert Map.keys(runtime.tracks) |> Enum.sort() == ["backing", "lead"]

    assert runtime.tracks["lead"].pipeline_state.worker_config.fp_manifest == nil

    assert runtime.tracks["backing"].pipeline_state.worker_config.fp_manifest ==
             modified.fp.manifest_path
  end

  @tag tmp_dir: true
  test "Neume Oi 混音图应用 gain/pan/mute 并导出立体声", %{tmp_dir: tmp_dir} do
    one = Path.join(tmp_dir, "one.wav")
    two = Path.join(tmp_dir, "two.wav")
    :ok = Neume.Wav.write(one, <<10_000::little-signed-16, 10_000::little-signed-16>>, 44_100)
    :ok = Neume.Wav.write(two, <<5_000::little-signed-16, 5_000::little-signed-16>>, 44_100)

    assert {:ok, compiled} = MixPipeline.compile(output_dir: tmp_dir)

    tracks = [
      %{track_id: "left", artifact: %{path: one}, mix: %{gain: 1.0, pan: -1.0, mute: false}},
      %{track_id: "muted", artifact: %{path: two}, mix: %{gain: 1.0, pan: 1.0, mute: true}}
    ]

    assert {:ok, artifact} = MixPipeline.run(compiled, tracks)
    assert artifact.track_ids == ["left", "muted"]
    assert artifact.sample_count == 2
    assert {:ok, bytes} = File.read(artifact.path)

    assert <<_header::binary-size(44), 10_000::little-signed-16, 0::little-signed-16,
             10_000::little-signed-16, 0::little-signed-16>> = bytes
  end

  @tag tmp_dir: true
  test "多轨 mix 参数经 Coconut History 更新", %{tmp_dir: tmp_dir} do
    root = VoicebankFixture.diffsinger(tmp_dir)
    assert {:ok, registry} = Registry.discover(root)
    assert [stock] = Enum.filter(Registry.list(registry), &(&1.mode == :stock))
    assert {:ok, project} = empty_project()
    assert {:ok, project} = MultiTrack.add_vocal_track(project, "lead", stock)

    assert {:ok, runtime} =
             MultiTrack.open(project,
               voicebank_registry: registry,
               diffsinger_client: Neume.VoicebankSelectionTest.UnusedClient
             )

    assert {:ok, runtime} = MultiTrack.put_mix(runtime, "lead", %{gain: 0.25, pan: -0.5})
    editor = runtime.tracks["lead"]

    assert TrackConfig.mix(Coconut.workspace(editor.session).tracks["lead"]) == %{
             gain: 0.25,
             pan: -0.5,
             mute: false
           }

    assert {:ok, session} = Coconut.undo(editor.session)

    assert TrackConfig.mix(Coconut.workspace(session).tracks["lead"]) == %{
             gain: 1.0,
             pan: 0.0,
             mute: false
           }
  end

  @tag tmp_dir: true
  test "多轨 check 聚合每条轨道和乐句的错误", %{tmp_dir: tmp_dir} do
    root = VoicebankFixture.diffsinger(tmp_dir)
    assert {:ok, registry} = Registry.discover(root)
    assert [stock] = Enum.filter(Registry.list(registry), &(&1.mode == :stock))
    assert {:ok, project} = empty_project()
    assert {:ok, project} = MultiTrack.add_vocal_track(project, "lead", stock)
    assert {:ok, project} = MultiTrack.add_vocal_track(project, "backing", stock)
    project = put_note(project, "lead", "l1", nil)
    project = put_note(project, "backing", "b1", nil)

    assert {:ok, runtime} =
             MultiTrack.open(project,
               voicebank_registry: registry,
               diffsinger_client: Neume.VoicebankSelectionTest.UnusedClient
             )

    assert {:error, {:check_failed, entries}} = MultiTrack.check(runtime)
    assert Enum.sort(Enum.map(entries, & &1.track_id)) == ["backing", "lead"]
    assert Enum.all?(entries, &match?({_, 0}, &1.phrase_id))
  end

  defp empty_project do
    with {:ok, workspace} <- Workspace.new(%{id: "workspace", tracks: %{}}) do
      Coconut.Project.new(%{id: "project", workspace: workspace, voicebank: nil, metadata: %{}})
    end
  end

  defp put_note(project, track_id, note_id, lyric) do
    attrs = %{pitch: 60}
    attrs = if lyric, do: Map.put(attrs, :lyric, lyric), else: attrs

    request = %Coconut.Edit.Operations.InsertNote{
      track_id: track_id,
      note_id: note_id,
      after_id: :head,
      span: {0, 480},
      attrs: attrs
    }

    :ok = Coconut.Edit.Operations.InsertNote.validate(request, project.workspace)
    {:ok, batches} = Coconut.Edit.Operation.lower_batches(request, project.workspace, %{})

    {:ok, workspace} =
      Workspace.apply_batches(project.workspace, project.workspace.edit_version, batches)

    %{project | workspace: workspace}
  end

  defp fake_modified(stock, tmp_dir) do
    dir = Path.join(tmp_dir, "modified")
    File.mkdir_p!(dir)
    manifest_path = Path.join(dir, "fp_manifest.json")
    File.write!(manifest_path, "{}")

    fp = %{
      manifest_path: manifest_path,
      manifest_digest: String.duplicate("a", 64),
      models: %{},
      noise: %{},
      noise_version: 1
    }

    Entry.modified(stock.manifest, fp)
  end
end
