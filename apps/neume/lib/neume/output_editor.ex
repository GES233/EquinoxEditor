defmodule Neume.OutputEditor do
  @moduledoc "输出提取与显式确认：模型往返在调用方执行，持久化仍只走 Coconut History。"
  alias Coconut.Edit.{Command, Patch, Workspace}

  def extract(editor) do
    with true <- function_exported?(editor.pipeline, :output_packets, 5),
         {:ok, session} <- Coconut.check(editor.session),
         {:ok, request} <- Coconut.request(session),
         {:ok, pins} <- Neume.Editor.lowered_pins(%{editor | session: session}, request),
         {:ok, packets} <-
           editor.pipeline.output_packets(
             editor.pipeline_state,
             request.snapshot,
             pins,
             request.globals,
             editor.track_id
           ) do
      entries =
        Enum.flat_map(packets, & &1.entries) |> Enum.map(&Map.put(&1, :track_id, editor.track_id))

      regions =
        Enum.reduce(packets, %{}, fn packet, regions ->
          Enum.reduce(packet.projections, regions, fn {channel, projections}, regions ->
            Enum.reduce(projections, regions, fn
              {note_id, {:ok, projection}}, acc ->
                blocked =
                  channel == :pitch and Enum.any?(packet.entries, &(&1.channel == :duration))

                projection = Map.put(projection, :blocked, blocked)

                Map.update(
                  acc,
                  note_id,
                  %{channel => projection},
                  &Map.put(&1, channel, projection)
                )

              _, acc ->
                acc
            end)
          end)
        end)

      {:ok, %{regions: regions, entries: entries}}
    else
      false -> {:error, :output_intervention_unsupported}
      {:error, reason} -> {:error, reason}
    end
  end

  def put(editor, note_id, channel, values, expected_digest)
      when channel in [:pitch, :duration] do
    with {:ok, extracted} <- extract(editor),
         {:ok, projection} <- projection(extracted, note_id, channel),
         true <- expected_digest == projection.digest do
      put_projection(editor, note_id, channel, values, projection)
    else
      false -> {:error, :output_context_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  def put(_editor, _note_id, _channel, _values, _digest), do: {:error, :invalid_output_channel}

  defp put_projection(editor, note_id, channel, values, projection) do
    with :ok <- Neume.Output.validate(channel, values, projection),
         {:ok, track} <- Workspace.fetch_track(Coconut.workspace(editor.session), editor.track_id),
         existing <-
           Enum.filter(track.patches, &(&1.channel == channel and &1.anchor.refs == [note_id])),
         true <- Enum.all?(existing, &Neume.Output.payload?(&1.tamale_patch.payload)),
         payload = %{
           schema: Neume.Output.schema(),
           channel: Atom.to_string(channel),
           values: values
         },
         {:ok, tamale} <- Tamale.Patch.new(projection.base, payload),
         {:ok, patch} <-
           Patch.new(%{
             track_id: editor.track_id,
             channel: channel,
             anchor: %Tamale.Anchor.Ordinal{refs: [note_id], at_version: track.space.version},
             tamale_patch: tamale
           }),
         discards = Enum.map(existing, &{&1.track_id, &1.id, :replaced}),
         {:ok, session} <- Coconut.run(editor.session, Command.repatch_patches(discards, [patch])) do
      {:ok, %{editor | session: session}}
    else
      false -> {:error, :legacy_pin_requires_explicit_removal}
      {:error, reason} -> {:error, reason}
    end
  end

  def repatch(editor, patch_id) do
    with {:ok, track} <- Workspace.fetch_track(Coconut.workspace(editor.session), editor.track_id),
         %Patch{tamale_patch: %{payload: %{schema: "model_output_v1", values: values}}} = patch <-
           Enum.find(track.patches, &(&1.id == patch_id)),
         [note_id] <- patch.anchor.refs,
         {:ok, extracted} <- extract(editor),
         {:ok, projection} <- projection(extracted, note_id, patch.channel) do
      case put_projection(editor, note_id, patch.channel, values, projection) do
        {:ok, next} ->
          {:ok, next, %{patch_id: patch_id, status: :repatched}}

        {:error, reason} ->
          {:ok, editor, %{patch_id: patch_id, status: :degraded, reason: reason}}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:output_pin_not_found, patch_id}}
    end
  end

  defp projection(extracted, note_id, channel) do
    case get_in(extracted, [:regions, note_id, channel]) do
      %{blocked: false} = projection -> {:ok, projection}
      %{blocked: true} -> {:error, :upstream_output_conflict}
      _ -> {:error, {:output_region_unavailable, note_id, channel}}
    end
  end
end
