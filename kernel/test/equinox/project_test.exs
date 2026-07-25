defmodule Equinox.ProjectTest do
  use ExUnit.Case, async: true
  alias Equinox.Project

  describe "Project" do
    test "new/1 creates a project with default values" do
      project = Project.new()
      assert project.name == "Untitled Project"
      assert project.version == 1
      assert length(project.tempo_map) == 1
      assert project.tracks == %{}
    end

    test "new/1 accepts custom values" do
      project = Project.new(%{name: "My Song", version: 2})
      assert project.name == "My Song"
      assert project.version == 2
    end
  end
end
