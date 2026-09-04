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

    assert {:ok, runtime} = MultiTrack.put_voicebank(runtime, "lead", modified)

    assert TrackConfig.voicebank(Coconut.workspace(runtime.session).tracks["lead"]) ==
             modified.signature

    assert runtime.tracks["lead"].pipeline_state.worker_config.fp_manifest ==
             modified.fp.manifest_path

    assert {:ok, runtime} = MultiTrack.undo(runtime)

    assert TrackConfig.voicebank(Coconut.workspace(runtime.session).tracks["lead"]) ==
             stock.signature

    assert runtime.tracks["lead"].pipeline_state.worker_config.fp_manifest == nil
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
  test "多轨共享唯一 Coconut Session，mix 参数进入全局 History", %{tmp_dir: tmp_dir} do
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

    assert %Neume.TrackRuntime{} = runtime.tracks["lead"]

    assert TrackConfig.mix(Coconut.workspace(runtime.session).tracks["lead"]) == %{
             gain: 0.25,
             pan: -0.5,
             mute: false
           }

    assert {:ok, runtime} = MultiTrack.undo(runtime)

    assert TrackConfig.mix(Coconut.workspace(runtime.session).tracks["lead"]) == %{
             gain: 1.0,
             pan: 0.0,
             mute: false
           }
  end

  @tag tmp_dir: true
  test "不同轨编辑按同一 History 的全局顺序 undo/redo", %{tmp_dir: tmp_dir} do
    root = VoicebankFixture.diffsinger(tmp_dir)
    assert {:ok, registry} = Registry.discover(root)
    assert [stock] = Enum.filter(Registry.list(registry), &(&1.mode == :stock))
    assert {:ok, project} = empty_project()
    assert {:ok, project} = MultiTrack.add_vocal_track(project, "lead", stock)
    assert {:ok, project} = MultiTrack.add_vocal_track(project, "backing", stock)

    assert {:ok, runtime} =
             MultiTrack.open(project,
               voicebank_registry: registry,
               diffsinger_client: Neume.VoicebankSelectionTest.UnusedClient
             )

    assert {:ok, runtime} =
             MultiTrack.insert_note(runtime, "lead", "l1", :head, {0, 480}, %{
               pitch: 60,
               lyric: "la"
             })

    assert {:ok, runtime} =
             MultiTrack.insert_note(runtime, "backing", "b1", :head, {0, 480}, %{
               pitch: 55,
               lyric: "ba"
             })

    assert {:ok, [{"l1", _, {0, 480}}]} = MultiTrack.notes(runtime, "lead")
    assert {:ok, [{"b1", _, {0, 480}}]} = MultiTrack.notes(runtime, "backing")

    assert {:ok, runtime} = MultiTrack.undo(runtime)
    assert {:ok, [{"l1", _, {0, 480}}]} = MultiTrack.notes(runtime, "lead")
    assert {:ok, []} = MultiTrack.notes(runtime, "backing")

    assert {:ok, runtime} = MultiTrack.undo(runtime)
    assert {:ok, []} = MultiTrack.notes(runtime, "lead")

    assert {:ok, runtime} = MultiTrack.redo(runtime)
    assert {:ok, [{"l1", _, {0, 480}}]} = MultiTrack.notes(runtime, "lead")
  end

  @tag tmp_dir: true
  test "运行时增删轨可 undo，并同步重建逐轨 runtime", %{tmp_dir: tmp_dir} do
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

    assert {:ok, runtime} = MultiTrack.add_vocal_track(runtime, "backing", stock)
    assert Map.keys(runtime.tracks) |> Enum.sort() == ["backing", "lead"]

    assert {:ok, runtime} = MultiTrack.remove_track(runtime, "lead")
    assert Map.keys(runtime.tracks) == ["backing"]

    assert {:ok, runtime} = MultiTrack.undo(runtime)
    assert Map.keys(runtime.tracks) |> Enum.sort() == ["backing", "lead"]
  end

  @tag tmp_dir: true
  test "唯一多轨 History 随工程文件保存并恢复", %{tmp_dir: tmp_dir} do
    root = VoicebankFixture.diffsinger(tmp_dir)
    assert {:ok, registry} = Registry.discover(root)
    assert [stock] = Enum.filter(Registry.list(registry), &(&1.mode == :stock))
    assert {:ok, project} = empty_project()
    assert {:ok, project} = MultiTrack.add_vocal_track(project, "lead", stock)
    assert {:ok, project} = MultiTrack.add_vocal_track(project, "backing", stock)

    opts = [
      voicebank_registry: registry,
      diffsinger_client: Neume.VoicebankSelectionTest.UnusedClient
    ]

    assert {:ok, runtime} = MultiTrack.open(project, opts)

    assert {:ok, runtime} =
             MultiTrack.insert_note(runtime, "lead", "l1", :head, {0, 480}, %{
               pitch: 60,
               lyric: "la"
             })

    assert {:ok, runtime} = MultiTrack.put_mix(runtime, "backing", %{gain: 0.4})
    path = Path.join(tmp_dir, "multi-track.coconut")
    assert {:ok, ^path} = MultiTrack.save(runtime, path)
    assert {:ok, loaded} = MultiTrack.load(path, opts)

    assert loaded.session.history.cursor == runtime.session.history.cursor
    assert Coconut.workspace(loaded.session) == Coconut.workspace(runtime.session)

    assert {:ok, loaded} = MultiTrack.undo(loaded)

    assert TrackConfig.mix(Coconut.workspace(loaded.session).tracks["backing"]) == %{
             gain: 1.0,
             pan: 0.0,
             mute: false
           }

    assert {:ok, loaded} = MultiTrack.undo(loaded)
    assert {:ok, []} = MultiTrack.notes(loaded, "lead")
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
