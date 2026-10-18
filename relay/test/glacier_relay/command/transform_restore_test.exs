defmodule GlacierRelay.Command.TransformRestoreTest do
  @moduledoc """
  M6-F: the restoration planner over journal files written for the test — the exact preimage group
  from verified, durable evidence; every incomplete, ambiguous, uncertain, drifted or unaudited
  condition fails closed with a named reason; the inspection binding accepts only a later exact
  inspection of this adapter, link and generation whose words equal the lift's postimage, and
  reports `already_at_baseline` when they equal the preimage; the in-memory record is cross-checked.
  No native command is performed.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.{Journal, TransformRestore, TransformWords}

  @id "9c8f3a75-7054-457c-919d-ee87e77f57d9"
  @inspection "1b7a3c2d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  @adapter "aaf540dd-c6df-4429-8fa5-84bc8933a13e"
  @gen "2516103519921974492-5fd4f3e1-0fa5-408f-bce8-b58923581360"
  @journal_id "86f8a2d7-c92d-43c3-a7b7-03310b9d3719"
  @brick "007c57a6ea581f8c"
  @pre "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfc5099e"
  @target "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfa5099e"
  @local "00000000,00000000,bfc5099e,00000000,00000000,00000000,3f800000"

  defp field(status, value \\ nil),
    do: if(value == nil, do: %{"status" => status}, else: %{"status" => status, "value" => value})

  defp observed(overrides \\ %{}) do
    Map.merge(
      %{
        "mode" => field("observed", "lift"),
        "generation_fresh" => field("observed", @gen),
        "generation_post" => field("observed", @gen),
        "preimage_world_words" => field("observed", @pre),
        "preimage_local_words" => field("observed", @local),
        "preimage_parent" => field("observed", @brick),
        "preimage_dirty" => field("observed", false),
        "requested_world_words" => field("observed", @target),
        "postimage_world_words" => field("observed", @target),
        "postimage_local_words" => field("observed", @local),
        "postimage_parent" => field("observed", @brick),
        "postimage_dirty" => field("observed", false),
        "post_same_entity" => field("observed", true),
        "world_match" => field("observed", "target"),
        "local_match" => field("observed", "unchanged"),
        "hero_control" => field("observed", "unchanged"),
        "setter_called" => field("observed", true),
        "effect" => field("observed", "changed")
      },
      overrides
    )
  end

  defp stage(event, fields \\ %{}, id \\ @id) do
    Map.merge(
      %{
        "event" => event,
        "command_id" => id,
        "link_generation" => 1,
        "name" => "candidate.transform.set",
        "version" => 1
      },
      fields
    )
  end

  defp accepted(params \\ %{}),
    do:
      stage("command.accepted", %{
        "params" =>
          Map.merge(
            %{
              "mode" => "lift",
              "expect_world" => @pre,
              "expect_local" => @local,
              "expect_parent" => @brick
            },
            params
          ),
        "preconditions" => %{"mission_generation" => @gen}
      })

  defp terminal(overrides \\ %{}),
    do:
      stage("command.terminal", %{
        "status" => "applied",
        "observed" => observed(overrides),
        "mission_generation" => @gen,
        "frame" => 20_000
      })

  defp inspection_observed(world, overrides) do
    Map.merge(
      %{
        "cand_resolved" => field("observed", true),
        "cand_distinct" => field("observed", true),
        "cand_in_registry" => field("observed", false),
        "cand_world_words" => field("observed", world),
        "cand_local_words" => field("observed", @local),
        "cand_dirty" => field("observed", false),
        "cand_parent" => field("observed", @brick)
      },
      overrides
    )
  end

  defp inspection_entries(world, overrides \\ %{}, fields \\ %{}) do
    [
      stage(
        "command.accepted",
        %{"name" => "relay.inspect.candidate_transform", "params" => %{}, "preconditions" => %{}},
        @inspection
      ),
      stage("command.transmitted", %{}, @inspection),
      stage("command.received", %{}, @inspection),
      stage(
        "command.terminal",
        Map.merge(
          %{
            "name" => "relay.inspect.candidate_transform",
            "status" => "applied",
            "observed" => inspection_observed(world, overrides),
            "mission_generation" => @gen,
            "frame" => 20_300
          },
          fields
        ),
        @inspection
      )
    ]
  end

  defp base_entries do
    [
      %{"event" => "journal.opened"},
      %{"event" => "link.connected", "link_generation" => 1},
      %{"event" => "peer.identified", "link_generation" => 1, "adapter_instance_id" => @adapter},
      accepted(),
      stage("command.transmitted"),
      stage("command.received"),
      terminal()
    ]
  end

  defp write(entries, opts \\ []) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-trestore-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "commands-#{@journal_id}.ndjson")

    lines =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, seq} ->
        JSON.encode!(
          Map.merge(entry, %{
            "journal" => Journal.version(),
            "journal_id" => @journal_id,
            "seq" => seq,
            "at" => "2026-10-17T06:00:00.000Z",
            "mono_ms" => seq * 100
          })
        )
      end)

    text = Enum.join(lines, "\n") <> "\n"
    text = if opts[:truncate], do: String.slice(text, 0, byte_size(text) - 5), else: text
    File.write!(path, text)
    path
  end

  defp record(overrides \\ %{}) do
    Map.merge(
      %{
        id: @id,
        status: :applied,
        audit: :intact,
        link_generation: 1,
        adapter_instance_id: @adapter,
        result: %{observed: observed()}
      },
      overrides
    )
  end

  defp entries_of(path) do
    {:ok, journal} = Journal.read(path)
    journal.entries
  end

  test "the plan carries the exact preimage and postimage groups, the identities and what issuing still requires" do
    path = write(base_entries())
    assert {:ok, plan} = TransformRestore.plan(path, @id, record: record())

    assert plan.restore_of == @id and plan.adapter_instance_id == @adapter and
             plan.link_generation == 1 and plan.mission_generation == @gen

    assert TransformWords.encode(plan.preimage_world) == @pre and
             TransformWords.encode(plan.postimage_world) == @target

    assert plan.target_world == @pre and plan.preimage_parent == @brick and
             plan.postimage_parent == @brick

    assert plan.effect == "changed" and plan.frame == 20_000 and plan.journal_seq == 7 and
             plan.audit == :continuous

    assert plan.requires == [
             :qualifying_exact_inspection,
             :same_mission_generation,
             :effectful_arming
           ]

    assert plan.consequences == :unknown and plan.label =~ "never assigned"
  end

  # M6-G1: the v2 step's journal records: the accepted and terminal stages of a v2 step_y.
  defp v2_entries(accepted_mode, terminal_mode, version \\ 2) do
    v = %{"version" => version}

    [
      %{"event" => "journal.opened"},
      %{"event" => "link.connected", "link_generation" => 1},
      %{"event" => "peer.identified", "link_generation" => 1, "adapter_instance_id" => @adapter},
      Map.merge(accepted(%{"mode" => accepted_mode}), v),
      Map.merge(stage("command.transmitted"), v),
      Map.merge(stage("command.received"), v),
      Map.merge(terminal(%{"mode" => field("observed", terminal_mode)}), v)
    ]
  end

  test "M6-G1: a v2 step plans at version 2; historical v1 records plan at version 1 unchanged; every other version or mode pairing fails closed" do
    assert {:ok, v1} = TransformRestore.plan(write(base_entries()), @id, record: record())
    assert v1.version == 1 and v1.forward_mode == "lift"

    assert {:ok, v2} = TransformRestore.plan(write(v2_entries("step_y", "step_y")), @id)
    assert v2.version == 2 and v2.forward_mode == "step_y" and v2.target_world == @pre

    assert {:error, :not_a_step} =
             TransformRestore.plan(write(v2_entries("lift", "step_y")), @id)

    assert {:error, :not_a_step} =
             TransformRestore.plan(write(v2_entries("step_y", "lift")), @id)

    assert {:error, :not_a_lift} =
             TransformRestore.plan(write(v2_entries("step_y", "step_y", 1)), @id)

    assert {:error, :not_a_transform_command} =
             TransformRestore.plan(write(v2_entries("step_y", "step_y", 3)), @id)
  end

  test "every incomplete, ambiguous, uncertain or drifted lift fails closed with a named reason" do
    refusals = [
      {"unknown command", [], :command_not_in_journal,
       "0000000000000000-0000-4000-8000-000000000000" |> String.slice(0, 36)},
      {"not a lift", [accepted(%{"mode" => "restore"})], :not_a_lift, @id},
      {"not a transform",
       [
         stage("command.accepted", %{
           "name" => "player.outfit.set",
           "version" => 2,
           "params" => %{},
           "preconditions" => %{"mission_generation" => @gen}
         })
       ], :not_a_transform_command, @id},
      {"effect unchanged",
       [
         terminal(%{
           "effect" => field("observed", "unchanged"),
           "world_match" => field("observed", "preimage"),
           "postimage_world_words" => field("observed", @pre)
         })
       ], :effect_unchanged, @id},
      {"effect uncertain", [terminal(%{"effect" => field("observed", "uncertain")})],
       :effect_uncertain, @id},
      {"effect unreported", [terminal(%{"effect" => field("unavailable")})], :effect_unreported,
       @id},
      {"dirty post cache",
       [
         terminal(%{
           "effect" => field("observed", "uncertain"),
           "world_match" => field("observed", "indeterminate_dirty"),
           "postimage_dirty" => field("observed", true)
         })
       ], :effect_uncertain, @id},
      {"world match neither", [terminal(%{"world_match" => field("observed", "neither")})],
       {:world_match, "neither"}, @id},
      {"control changed", [terminal(%{"hero_control" => field("observed", "changed")})],
       {:hero_control, "changed"}, @id},
      {"entity changed", [terminal(%{"post_same_entity" => field("observed", false)})],
       :post_entity_changed, @id},
      {"preimage unobserved", [terminal(%{"preimage_world_words" => field("unavailable")})],
       :preimage_world_unobserved, @id},
      {"postimage unobserved", [terminal(%{"postimage_world_words" => field("unavailable")})],
       :postimage_world_unobserved, @id},
      {"preimage dirty", [terminal(%{"preimage_dirty" => field("observed", true)})],
       :preimage_dirty, @id},
      {"postimage not the requested words",
       [
         terminal(%{
           "postimage_world_words" =>
             field("observed", String.replace(@target, "bfa5099e", "bfa5099f"))
         })
       ], :postimage_not_requested, @id},
      {"parent changed by the lift",
       [terminal(%{"postimage_parent" => field("observed", "none")})], :parent_changed_by_lift,
       @id},
      {"not applied", [terminal(%{}) |> Map.put("status", "failed")], {:not_applied, "failed"},
       @id},
      {"unknown outcome", [stage("command.unknown", %{"reason" => "link lost"})],
       :outcome_unknown, @id},
      {"two terminals", [terminal()], {:terminal_entries, 2}, @id}
    ]

    for {label, extra, reason, id} <- refusals do
      entries =
        case label do
          "not a lift" -> List.replace_at(base_entries(), 3, hd(extra))
          "not a transform" -> List.replace_at(base_entries(), 3, hd(extra))
          "effect " <> _ -> List.replace_at(base_entries(), 6, hd(extra))
          "dirty post cache" -> List.replace_at(base_entries(), 6, hd(extra))
          "world match neither" -> List.replace_at(base_entries(), 6, hd(extra))
          "control changed" -> List.replace_at(base_entries(), 6, hd(extra))
          "entity changed" -> List.replace_at(base_entries(), 6, hd(extra))
          "preimage unobserved" -> List.replace_at(base_entries(), 6, hd(extra))
          "postimage unobserved" -> List.replace_at(base_entries(), 6, hd(extra))
          "preimage dirty" -> List.replace_at(base_entries(), 6, hd(extra))
          "postimage not the requested words" -> List.replace_at(base_entries(), 6, hd(extra))
          "parent changed by the lift" -> List.replace_at(base_entries(), 6, hd(extra))
          "not applied" -> List.replace_at(base_entries(), 6, hd(extra))
          _ -> base_entries() ++ extra
        end

      path = write(entries)
      assert {:error, ^reason} = TransformRestore.plan(path, id), label
    end
  end

  test "the inspection binding: only a later exact inspection of this adapter, link and generation whose words equal the postimage; the preimage means no restoration is needed" do
    path = write(base_entries() ++ inspection_entries(@target))
    {:ok, plan} = TransformRestore.plan(path, @id)
    opts = [now_mono_ms: 1_200, link_generation: 1, max_age_ms: 60_000]

    assert {:ok, binding} =
             TransformRestore.verify_inspection(entries_of(path), plan, @inspection, opts)

    assert binding.expect_world == @target and binding.expect_local == @local and
             binding.expect_parent == @brick

    assert binding.frame == 20_300 and binding.command_frame == 20_000 and
             binding.later_class == :held and binding.age_ms == 100

    refusals = [
      {"already at baseline", inspection_entries(@pre), :already_at_baseline, opts},
      {"near the target (tolerance, not equality)",
       inspection_entries(String.replace(@target, "bfa5099e", "bfa5099f")),
       {:state_drifted, :near_target}, opts},
      {"drifted", inspection_entries(String.replace(@target, "bfa5099e", "bf000000")),
       {:state_drifted, :drifted}, opts},
      {"dirty cache", inspection_entries(@target, %{"cand_dirty" => field("observed", true)}),
       :inspection_cache_dirty, opts},
      {"parent changed",
       inspection_entries(@target, %{"cand_parent" => field("observed", "none")}),
       {:inspection_parent_changed, "none"}, opts},
      {"candidate unresolved",
       inspection_entries(@target, %{"cand_resolved" => field("unavailable")}),
       :inspection_candidate_unresolved, opts},
      {"candidate in a slot",
       inspection_entries(@target, %{"cand_in_registry" => field("observed", true)}),
       :inspection_candidate_in_registry, opts},
      {"words unobserved",
       inspection_entries(@target, %{"cand_world_words" => field("unavailable")}),
       :inspection_world_unobserved, opts},
      {"other generation", inspection_entries(@target, %{}, %{"mission_generation" => "other"}),
       :inspection_generation_mismatch, opts},
      {"not later", inspection_entries(@target, %{}, %{"frame" => 20_000}), :inspection_not_later,
       opts},
      {"stale", inspection_entries(@target), :inspection_stale,
       Keyword.put(opts, :now_mono_ms, 100_000)},
      {"other link", inspection_entries(@target), :inspection_link_not_current,
       Keyword.put(opts, :link_generation, 2)},
      {"not an exact inspection",
       inspection_entries(@target)
       |> List.update_at(0, &Map.put(&1, "name", "relay.inspect.candidate")),
       :not_an_exact_inspection, opts},
      {"not applied", inspection_entries(@target, %{}, %{"status" => "expired"}),
       {:inspection_not_applied, "expired"}, opts}
    ]

    for {label, extra, reason, o} <- refusals do
      path = write(base_entries() ++ extra)
      {:ok, plan} = TransformRestore.plan(path, @id)

      assert {:error, ^reason} =
               TransformRestore.verify_inspection(entries_of(path), plan, @inspection, o),
             label
    end

    assert {:error, :inspection_command_id_required} =
             TransformRestore.verify_inspection(entries_of(path), plan, nil, opts)

    assert {:error, :inspection_not_in_journal} =
             TransformRestore.verify_inspection(
               entries_of(path),
               plan,
               "00000000-0000-4000-8000-000000000000",
               opts
             )
  end

  test "an unreadable journal, a degraded journal or audit, and a disagreeing record fail closed" do
    path = write(base_entries(), truncate: true)
    assert {:error, {:unreadable_line, 7}} = TransformRestore.plan(path, @id)
    path = write(base_entries())

    assert {:error, :journal_degraded} =
             TransformRestore.plan(path, @id, journal_status: :degraded)

    assert {:error, :audit_degraded} = TransformRestore.plan(path, @id, audit: :degraded)

    assert {:error, {:record_status, :unknown}} =
             TransformRestore.plan(path, @id, record: record(%{status: :unknown}))

    assert {:error, {:record_audit, :degraded}} =
             TransformRestore.plan(path, @id, record: record(%{audit: :degraded}))

    assert {:error, :record_generation_disagrees} =
             TransformRestore.plan(path, @id, record: record(%{link_generation: 2}))

    assert {:error, :record_adapter_disagrees} =
             TransformRestore.plan(path, @id, record: record(%{adapter_instance_id: "other"}))

    assert {:error, :record_preimage_disagrees} =
             TransformRestore.plan(path, @id,
               record:
                 record(%{
                   result: %{
                     observed: observed(%{"preimage_world_words" => field("observed", @target)})
                   }
                 })
             )

    assert {:error, :record_postimage_disagrees} =
             TransformRestore.plan(path, @id,
               record:
                 record(%{
                   result: %{
                     observed: observed(%{"postimage_world_words" => field("observed", @pre)})
                   }
                 })
             )

    assert {:ok, _} = TransformRestore.plan(path, @id, record: record())
  end
end
