defmodule Neumu.PinFacadeTest do
  @moduledoc """
  pin 族手势的 facade 矩阵：两阶段挂载（预检在 ProjectServer 外、mount
  携预检令牌校验）、repatch 批量重挂、unmount_pin，以及快照 pins 投影。
  probe 走 `Neumu.ProjectStub.PhonemesClient`（纯 Elixir 假 G2P/组展开）。
  """

  use ExUnit.Case, async: false

  @moduletag tmp_dir: true

  alias Neumu.ProjectStub
  alias Neumu.ProjectStub.PhonemesClient

  # 默认工程：一条 fixture 声库的 "lead" 人声轨 + 一个双音素音符
  # （pin 0 = 空工程，pin 1 = 加轨，pin 2 = 插音符）。
  setup %{tmp_dir: tmp_dir} do
    {registry, stock} = ProjectStub.stock_registry(tmp_dir)
    project_id = "project-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Neumu.create_project(project_id, ProjectStub.open_opts(registry, tmp_dir, PhonemesClient))

    {:ok, 1} = Neumu.add_track(project_id, "lead", stock.id)

    {:ok, 2} =
      Neumu.insert_note(project_id, "lead", "n1", :head, {0, 480}, %{
        pitch: 60,
        lyric: "la",
        phonemes: [["zh", "l"], ["zh", "a"]]
      })

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(project_id), do: Neumu.close_project(project_id)
    end)

    %{project_id: project_id, registry: registry, tmp_dir: tmp_dir}
  end

  defp track(snapshot, track_id), do: Enum.find(snapshot.tracks, &(&1.id == track_id))
  defp pins!(project_id), do: project_id |> snapshot!() |> track("lead") |> Map.fetch!(:pins)

  defp snapshot!(project_id) do
    {:ok, snapshot} = Neumu.snapshot(project_id)
    snapshot
  end

  # 递归断言投影/令牌只含 plain data：无 PID/函数/引用/端口，无遗留 struct。
  defp assert_plain_data(term) do
    refute is_pid(term) or is_function(term) or is_reference(term) or is_port(term),
           "泄露运行时对象：#{inspect(term)}"

    cond do
      is_struct(term) -> flunk("泄露 struct：#{inspect(term)}")
      is_map(term) -> Enum.each(term, fn {k, v} -> assert_plain_data({k, v}) end)
      is_tuple(term) -> term |> Tuple.to_list() |> Enum.each(&assert_plain_data/1)
      is_list(term) -> Enum.each(term, &assert_plain_data/1)
      true -> :ok
    end
  end

  # 递归断言结构化投影字段不含 tuple（`:reason` 键例外：facade 契约保持
  # 结构化 tagged term，末端转换归壳层——见 docs/facade-protocol.md）。
  defp refute_projection_tuples(term, path \\ [])

  defp refute_projection_tuples(%{reason: _} = map, path) when is_map(map) do
    Enum.each(map, fn
      {:reason, _reason} -> :ok
      {key, value} -> refute_projection_tuples(value, path ++ [key])
    end)
  end

  defp refute_projection_tuples(map, path) when is_map(map) do
    Enum.each(map, fn {key, value} -> refute_projection_tuples(value, path ++ [key]) end)
  end

  defp refute_projection_tuples(tuple, path) when is_tuple(tuple),
    do: flunk("tuple 泄露于 #{inspect(path)}：#{inspect(tuple)}")

  defp refute_projection_tuples(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.each(fn {v, i} -> refute_projection_tuples(v, path ++ [i]) end)
  end

  defp refute_projection_tuples(_term, _path), do: :ok

  test "preflight_pin 返回 plain-data 令牌，不改状态不发事件", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")

    # 令牌只钉 track/note 与 History cursor；底料不随令牌下发——mount 时
    # 由 server 在 stale 校验覆盖的当前状态上经 channel 语义现场推导
    # （批次 B 起 pitch 点列落 score_pitch_v2，客户端不代为选底料）。
    assert %{track_id: "lead", note_id: "n1", history_pin: 2} = token
    refute Map.has_key?(token, :base)
    assert_plain_data(token)

    # 预检是只读旁路：history_pin 不变、无事件。
    assert {:ok, 2} = Neumu.history_pin(id)
    assert {:error, {:unknown_note, "no-such"}} = Neumu.preflight_pin(id, "lead", "no-such")
    assert {:error, {:unknown_track, "no-such"}} = Neumu.preflight_pin(id, "no-such", "n1")
    refute_received {:project_changed, _, _}
  end

  test "mount_pitch 携预检令牌落边，快照 pins 投影一致且无运行时对象", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")

    assert {:ok, 3} = Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], token)
    assert_received {:project_changed, ^id, 3}

    assert [
             %{
               id: patch_id,
               channel: :pitch,
               anchor: %{type: :ordinal, refs: ["n1"], at_version: _},
               payload: %{
                 schema: "score_pitch_v2",
                 coordinates: "note_tick",
                 values: [[120, 72.0]]
               }
             }
           ] = pins!(id)

    assert is_binary(patch_id)
    assert_plain_data(snapshot!(id))
    refute_received {:project_changed, _, _}
  end

  test "预检之后工程被编辑，mount 以 stale_pin 拒绝且状态不变", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")

    # 预检之后工程前进了一条边。
    assert {:ok, 3} = Neumu.edit_note(id, "lead", "n1", %{pitch: 62})
    assert_received {:project_changed, ^id, 3}

    assert {:error, {:stale_pin, _}} =
             Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], token)

    # 状态不变、不发事件；重新预检后重试成功。
    assert {:ok, 3} = Neumu.history_pin(id)
    assert [] = pins!(id)
    refute_received {:project_changed, _, _}

    assert {:ok, fresh} = Neumu.preflight_pin(id, "lead", "n1")
    assert fresh.history_pin == 3
    assert {:ok, 4} = Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], fresh)
    assert_received {:project_changed, ^id, 4}
  end

  test "预检令牌绑定 track/note，张冠李戴或畸形令牌被拒绝", %{project_id: id} do
    assert {:ok, 3} =
             Neumu.insert_note(id, "lead", "n2", "n1", {480, 960}, %{pitch: 62, lyric: "mi"})

    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")

    assert {:error, {:invalid_pin_token, "lead", "n2", _}} =
             Neumu.mount_pitch(id, "lead", "n2", [[120, 72]], token)

    assert {:error, {:invalid_pin_token, "lead", "n1", _}} =
             Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], %{})

    # 携带 base 的旧形令牌一律拒绝（底料由 server 侧现场推导）。
    assert {:error, {:invalid_pin_token, "lead", "n1", _}} =
             Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], Map.put(token, :base, %{}))

    assert {:ok, 3} = Neumu.history_pin(id)
    assert [] = pins!(id)
  end

  test "mount_phoneme_duration 与 unmount_pin 闭环，可 undo/redo", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")

    # E0a：list 入参在 server 侧换算为 phoneme_duration_v2 envelope
    # （成员内下标 0 → segment %{unit: "n1", member: 0, index: 0}）。
    assert {:ok, 3} = Neumu.mount_phoneme_duration(id, "lead", "n1", [[0, 96]], token)
    assert_received {:project_changed, ^id, 3}

    assert [
             %{
               channel: :duration,
               payload: %{
                 schema: "phoneme_duration_v2",
                 values: [%{segment: %{unit: "n1", member: 0, index: 0}, duration_tick: 96}]
               }
             }
           ] = pins!(id)

    assert {:ok, 4} = Neumu.unmount_pin(id, "lead", "n1", :duration)
    assert_received {:project_changed, ^id, 4}
    assert [] = pins!(id)

    # 无存活 pin：tagged error，不改状态。
    assert {:error, {:pin_not_found, "n1", :duration}} =
             Neumu.unmount_pin(id, "lead", "n1", :duration)

    assert {:error, {:pin_not_found, "n1", :pitch}} = Neumu.unmount_pin(id, "lead", "n1", :pitch)
    assert {:ok, 4} = Neumu.history_pin(id)

    # undo 恢复 pin，redo 再卸载。
    assert {:ok, 3} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 3}
    assert [%{channel: :duration}] = pins!(id)

    assert {:ok, 4} = Neumu.redo(id)
    assert_received {:project_changed, ^id, 4}
    assert [] = pins!(id)

    refute_received {:project_changed, _, _}
  end

  test "mount_phoneme_duration 接受 phoneme_duration_v2 envelope", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")

    v2 = %{
      schema: "phoneme_duration_v2",
      values: [%{segment: %{unit: "n1", member: 0, index: 1}, duration_tick: 96}]
    }

    assert {:ok, 3} = Neumu.mount_phoneme_duration(id, "lead", "n1", v2, token)
    assert_received {:project_changed, ^id, 3}

    assert [
             %{
               channel: :duration,
               payload: %{
                 schema: "phoneme_duration_v2",
                 values: [%{segment: %{unit: "n1", member: 0, index: 1}, duration_tick: 96}]
               }
             }
           ] = pins!(id)

    assert_plain_data(snapshot!(id))
    refute_received {:project_changed, _, _}
  end

  test "replace_pin：同 schema v2 替换一条边一次事件，undo 还原", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")

    # E0a 起 facade 挂载零 legacy：list 换算为 v2 envelope；legacy → v2
    # 升级手势只剩读档来源（Editor 层契约由 neume 侧测试钉住）。
    assert {:ok, 3} = Neumu.mount_phoneme_duration(id, "lead", "n1", [[0, 96]], token)
    assert_received {:project_changed, ^id, 3}

    [%{id: old_id, payload: old_payload}] = pins!(id)

    assert old_payload == %{
             schema: "phoneme_duration_v2",
             values: [%{segment: %{unit: "n1", member: 0, index: 0}, duration_tick: 96}]
           }

    v2 = %{
      schema: "phoneme_duration_v2",
      values: [%{segment: %{unit: "n1", member: 0, index: 1}, duration_tick: 120}]
    }

    assert {:ok, 4, result} = Neumu.replace_pin(id, "lead", old_id, v2)
    assert_received {:project_changed, ^id, 4}

    assert %{
             replaced_patch_id: ^old_id,
             payload_schema: "phoneme_duration_v2",
             patch_id: new_id
           } = result

    assert new_id != old_id
    assert [%{id: ^new_id, payload: %{schema: "phoneme_duration_v2"}}] = pins!(id)
    assert_plain_data(result)

    # 一条历史边：undo 一次完整还原旧 pin。
    assert {:ok, 3} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 3}
    assert [%{id: ^old_id, payload: ^old_payload}] = pins!(id)

    refute_received {:project_changed, _, _}
  end

  test "replace_pin：v2 → legacy 降级拒绝，不改状态不发事件", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")

    v2 = %{
      schema: "phoneme_duration_v2",
      values: [%{segment: %{unit: "n1", member: 0, index: 0}, duration_tick: 96}]
    }

    assert {:ok, 3} = Neumu.mount_phoneme_duration(id, "lead", "n1", v2, token)
    assert_received {:project_changed, ^id, 3}
    [%{id: patch_id}] = pins!(id)

    assert {:error, {:pin_schema_downgrade, "phoneme_duration_v2", "phoneme_duration_v1"}} =
             Neumu.replace_pin(id, "lead", patch_id, [[0, 96]])

    assert {:error, {:patch_not_alive, "no-such"}} =
             Neumu.replace_pin(id, "lead", "no-such", [[0, 96]])

    assert {:ok, 3} = Neumu.history_pin(id)
    assert [%{id: ^patch_id}] = pins!(id)
    refute_received {:project_changed, _, _}
  end

  test "mount_pitch_curve 接受绝对 tick plain map，落 v2 envelope", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")

    curve = %{
      format: :pitch_curve_v1,
      adapter: :bezier,
      coord: :absolute_tick,
      value: :absolute_midi,
      points: [
        %{tick: 0, value: 60, handle_left: nil, handle_right: %{tick: 120, value: 1.5}},
        %{tick: 479, value: 62, handle_left: %{tick: -120, value: -1.5}, handle_right: nil}
      ]
    }

    assert {:ok, 3} = Neumu.mount_pitch_curve(id, "lead", "n1", curve, token)
    assert_received {:project_changed, ^id, 3}

    # 批次 E：facade 仍传绝对 tick plain map，server 侧按 span 起点换算为
    # `pitch_curve_v2` envelope（offset_tick），handle 原样携带。
    assert [%{channel: :pitch, payload: payload}] = pins!(id)

    assert payload == %{
             schema: "pitch_curve_v2",
             coordinates: "note_tick",
             adapter: "bezier",
             points: [
               %{
                 offset_tick: 0,
                 value: 60.0,
                 handle_left: nil,
                 handle_right: %{tick: 120, value: 1.5}
               },
               %{
                 offset_tick: 479,
                 value: 62.0,
                 handle_left: %{tick: -120, value: -1.5},
                 handle_right: nil
               }
             ]
           }

    assert_plain_data(snapshot!(id))

    # 畸形 payload：tagged error，不落边。
    assert {:error, _} = Neumu.mount_pitch_curve(id, "lead", "n1", %{bogus: true}, token)
    assert {:ok, 3} = Neumu.history_pin(id)
    refute_received {:project_changed, _, _}
  end

  test "repatch 批量重签返回 {:ok, pin, results}，一条历史边", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")
    assert {:ok, 3} = Neumu.mount_phoneme_duration(id, "lead", "n1", [[0, 96]], token)
    assert_received {:project_changed, ^id, 3}
    assert [%{id: patch_id}] = pins!(id)

    # 改词换音素序列 → pin 失配（在册但底座过期），按 id 重签。
    assert {:ok, 4} = Neumu.edit_note(id, "lead", "n1", %{phonemes: [["zh", "l"], ["zh", "u"]]})
    assert_received {:project_changed, ^id, 4}

    assert {:ok, 5, [%{patch_id: ^patch_id, status: :repatched}]} =
             Neumu.repatch(id, "lead", [patch_id])

    assert_received {:project_changed, ^id, 5}

    assert [
             %{
               id: new_patch_id,
               channel: :duration,
               payload: %{
                 schema: "phoneme_duration_v2",
                 values: [%{segment: %{unit: "n1", member: 0, index: 0}, duration_tick: 96}]
               }
             }
           ] = pins!(id)

    assert new_patch_id != patch_id

    # undo 一次整批还原（旧 pin 回来）。
    assert {:ok, 4} = Neumu.undo(id)
    assert_received {:project_changed, ^id, 4}
    assert [%{id: ^patch_id}] = pins!(id)

    refute_received {:project_changed, _, _}
  end

  test "repatch 降级不落边不发事件；不在册的 patch 报 tagged error", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")

    # 下标 1 指向第二个音素。
    assert {:ok, 3} = Neumu.mount_phoneme_duration(id, "lead", "n1", [[1, 96]], token)
    assert_received {:project_changed, ^id, 3}
    assert [%{id: patch_id}] = pins!(id)

    # 改成单音素词 → 下标 1 越界，repatch 降级。
    assert {:ok, 4} = Neumu.edit_note(id, "lead", "n1", %{phonemes: [["zh", "o"]]})
    assert_received {:project_changed, ^id, 4}

    assert {:ok, 4, [%{patch_id: ^patch_id, status: :degraded, reason: reason}]} =
             Neumu.repatch(id, "lead", [patch_id])

    assert reason == {:phoneme_index_out_of_range, 1, 1}

    # 全部降级：无新历史边、无事件，旧 patch 原样在册。
    assert {:ok, 4} = Neumu.history_pin(id)
    assert [%{id: ^patch_id}] = pins!(id)
    refute_received {:project_changed, _, _}

    assert {:error, {:patch_not_alive, "Patch_nope"}} = Neumu.repatch(id, "lead", ["Patch_nope"])
    assert {:error, {:unknown_track, "no-such"}} = Neumu.repatch(id, "no-such", [patch_id])
  end

  test "note_phonemes 返回拍板形状，history_pin 一致且只读无副作用", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    assert {:ok, result} = Neumu.note_phonemes(id)

    # 拍板形状（E0b）：segment 即可直接撰写 phoneme_duration_v2 envelope
    # 的 stable ref；span 已 JSON-safe 化为 list；extras 预留。
    assert %{
             history_pin: 2,
             tracks: %{
               "lead" => %{
                 "n1" => %{
                   span: [0, 480],
                   segments: [
                     %{segment: %{unit: "n1", member: 0, index: 0}, phoneme: "l"},
                     %{segment: %{unit: "n1", member: 0, index: 1}, phoneme: "a"}
                   ],
                   extras: %{}
                 }
               }
             }
           } = result

    assert_plain_data(result)
    refute_projection_tuples(result)

    # 只读查询：不产生历史边、不派发事件。
    assert {:ok, 2} = Neumu.history_pin(id)
    refute_received {:project_changed, _, _}
  end

  test "note_phonemes：melisma 组头给全组序列，续音符只给延续元音", %{project_id: id} do
    assert {:ok, 3} = Neumu.split_note(id, "lead", "n1", 240, "n1b")

    assert {:ok, %{history_pin: 3, tracks: %{"lead" => notes}}} = Neumu.note_phonemes(id)

    assert %{
             "n1" => %{
               span: [0, 240],
               segments: [
                 %{segment: %{unit: "n1", member: 0, index: 0}, phoneme: "l"},
                 %{segment: %{unit: "n1", member: 0, index: 1}, phoneme: "a"},
                 %{segment: %{unit: "n1", member: 1, index: 0}, phoneme: "a"}
               ]
             },
             "n1b" => %{
               span: [240, 480],
               segments: [%{segment: %{unit: "n1", member: 1, index: 0}, phoneme: "a"}]
             }
           } = notes
  end

  test "note_phonemes：probe/G2P 失败投影为 plain-data entries", %{tmp_dir: tmp_dir} do
    {registry, stock} = ProjectStub.stock_registry(tmp_dir)
    failing_id = "project-failing-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Neumu.create_project(
        failing_id,
        ProjectStub.open_opts(registry, tmp_dir, Neumu.PinFacadeTest.FailingPhonemesClient)
      )

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(failing_id), do: Neumu.close_project(failing_id)
    end)

    assert {:ok, 1} = Neumu.add_track(failing_id, "lead", stock.id)

    # 无显式音素 → probe 走 G2P，假 client loud 失败。
    assert {:ok, 2} =
             Neumu.insert_note(failing_id, "lead", "n1", :head, {0, 480}, %{
               pitch: 60,
               lyric: "la"
             })

    assert {:ok, %{history_pin: 2, status: :failed, entries: [entry]}} =
             Neumu.note_phonemes(failing_id)

    assert %{kind: :probe, track_id: "lead", reason: {:encoder_failed, {:g2p_failed, "la"}}} =
             entry

    assert_plain_data(entry)
    refute_projection_tuples(entry)

    # 失败查询同样只读：不落边、不发事件。
    assert {:ok, 2} = Neumu.history_pin(failing_id)
  end

  test "pin 随工程保存/重开恢复，undo 历史一并回来", %{
    project_id: id,
    registry: registry,
    tmp_dir: tmp_dir
  } do
    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")
    assert {:ok, 3} = Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], token)
    # 第一次 mount 后 history_pin 前进，旧令牌作废，需重新预检。
    assert {:ok, token} = Neumu.preflight_pin(id, "lead", "n1")
    assert {:ok, 4} = Neumu.mount_phoneme_duration(id, "lead", "n1", [[0, 96]], token)

    assert [%{channel: :pitch}, %{channel: :duration}] = pins!(id)

    path = Path.join(tmp_dir, "pins.coconut")
    assert {:ok, ^path} = Neumu.save_project(id, path)
    assert :ok = Neumu.close_project(id)

    assert {:ok, _pid} =
             Neumu.load_project(
               id,
               path,
               ProjectStub.open_opts(registry, tmp_dir, PhonemesClient)
             )

    assert %{history_pin: 4} = snapshot!(id)

    assert [
             %{
               channel: :pitch,
               anchor: %{refs: ["n1"]},
               payload: %{schema: "score_pitch_v2", values: [[120, 72.0]]}
             },
             %{
               channel: :duration,
               payload: %{
                 schema: "phoneme_duration_v2",
                 values: [%{segment: %{unit: "n1", member: 0, index: 0}, duration_tick: 96}]
               }
             }
           ] = pins!(id)

    # 存档 History 可继续 undo：duration pin 卸载边先还原。
    assert {:ok, 3} = Neumu.undo(id)
    assert [%{channel: :pitch}] = pins!(id)
    assert {:ok, 2} = Neumu.undo(id)
    assert [] = pins!(id)
  end
end

defmodule Neumu.PinFacadeTest.FailingPhonemesClient do
  @moduledoc false
  # G2P loud 失败的假 client：probe 在 encode 动作即以 tagged error 拒绝，
  # 供 note_phonemes 的失败投影测试使用。
  @behaviour NeumeOpuDs.Worker

  @impl true
  def call(%{action: "encode", notes: notes}, _config),
    do: {:error, {:g2p_failed, notes |> hd() |> Map.get(:lyric)}}

  def call(_payload, _config), do: {:error, :not_used}
end
