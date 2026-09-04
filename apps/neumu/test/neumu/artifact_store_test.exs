defmodule Neumu.ArtifactStoreTest do
  use ExUnit.Case, async: false

  alias Neumu.ArtifactStore
  alias Neumu.ProjectStub

  test "存入混音制品后按不透明 id 查询，未知名返回 tagged error" do
    artifact = ProjectStub.mix_artifact()

    assert {:ok, artifact_id} = ArtifactStore.put(artifact)
    assert is_binary(artifact_id)
    assert {:ok, ^artifact} = ArtifactStore.fetch(artifact_id)

    assert {:error, {:artifact_not_found, "artifact-missing"}} =
             ArtifactStore.fetch("artifact-missing")

    assert {:error, {:artifact_not_found, "artifact-missing"}} =
             Neumu.artifact("artifact-missing")
  end

  test "存入渲染制品并可取回" do
    artifact = %Neume.RenderArtifact{format: :mock_frames, frame_count: 42}

    assert {:ok, artifact_id} = ArtifactStore.put(artifact)
    assert {:ok, ^artifact} = ArtifactStore.fetch(artifact_id)
  end

  test "每次存入分配不同的不透明 id" do
    ids =
      for _ <- 1..100 do
        {:ok, id} = ArtifactStore.put(ProjectStub.mix_artifact())
        id
      end

    assert length(Enum.uniq(ids)) == 100
  end

  test "非制品值不能入库" do
    assert {:error, {:invalid_artifact, :not_an_artifact}} = ArtifactStore.put(:not_an_artifact)
  end

  test "删除已登记制品后无法再取回" do
    {:ok, artifact_id} = ArtifactStore.put(ProjectStub.mix_artifact())

    assert :ok = ArtifactStore.delete(artifact_id)

    assert {:error, {:artifact_not_found, ^artifact_id}} = ArtifactStore.fetch(artifact_id)
  end

  test "删除未知标识返回 tagged error" do
    assert {:error, {:artifact_not_found, "artifact-missing"}} =
             ArtifactStore.delete("artifact-missing")
  end
end
