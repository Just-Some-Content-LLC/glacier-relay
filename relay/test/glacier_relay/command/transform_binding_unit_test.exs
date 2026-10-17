defmodule GlacierRelay.Command.TransformBindingUnitTest do
  @moduledoc """
  M6-F1a binding correction: `Command.TransformBinding` over hand-built journal evidence — the
  contradictory, duplicated, missing and out-of-order cases a fake peer cannot produce through
  the real authority, a disagreeing in-memory record, the identity and token entries, and the
  clock domain of the age. Pure functions; no process, no peer, no Glacier.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.TransformBinding

  @id "11111111-1111-4111-8111-111111111111"
  @adapter "22222222-2222-4222-8222-222222222222"
  @gen "2516103519921974492-5fd4f3e1-0fa5-408f-bce8-b58923581360"
  @brick "007c57a6ea581f8c"
  @pre "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfc5099e"
  @local "00000000,00000000,bfc5099e,00000000,00000000,00000000,3f800000"
  @hero_world "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,c2a77ccf,416b27f0,bfc2d6bb"
  @hero_local "c2a77ccf,416b27f0,bfc2d6bb,00000000,00000000,00000000,3f800000"

  defp f(value), do: %{"status" => "observed", "value" => value}

  defp observed,
    do: %{
      "generation_fresh" => f(@gen),
      "targets" => f("#{@brick},feede715906f747f"),
      "snapshot_version" => f(1),
      "cand_brick_present" => f(true),
      "cand_index_check" => f("in_range"),
      "cand_resolved" => f(true),
      "cand_hitman5" => f(true),
      "cand_id_match" => f(true),
      "cand_distinct" => f(true),
      "cand_brick_owner" => f(@brick),
      "cand_spatial" => f(true),
      "cand_spatial_distinct" => f(true),
      "cand_in_registry" => f(false),
      "cand_world_words" => f(@pre),
      "cand_local_words" => f(@local),
      "cand_dirty" => f(false),
      "cand_parent" => f(@brick),
      "hero_world_words" => f(@hero_world),
      "hero_local_words" => f(@hero_local),
      "hero_parent" => f("00b6cedd6778f19c"),
      "reads_on_frame" => f(true)
    }

  defp cmd_entry(event, seq, extra \\ %{}),
    do:
      Map.merge(
        %{
          "event" => event,
          "seq" => seq,
          "command_id" => @id,
          "link_generation" => 3,
          "name" => "relay.inspect.candidate_transform",
          "version" => 1
        },
        extra
      )

  defp entries,
    do: [
      %{"event" => "journal.opened", "seq" => 1},
      %{
        "event" => "peer.identified",
        "seq" => 2,
        "link_generation" => 3,
        "adapter_instance_id" => @adapter
      },
      %{
        "event" => "peer.token_verified",
        "seq" => 3,
        "link_generation" => 3,
        "adapter_instance_id" => @adapter
      },
      cmd_entry("command.accepted", 4, %{"params" => %{}}),
      cmd_entry("command.transmitted", 5),
      cmd_entry("command.received", 6, %{"frame" => 19_000}),
      cmd_entry("command.terminal", 7, %{
        "status" => "applied",
        "frame" => 19_001,
        "mission_generation" => @gen,
        "observed" => observed(),
        "mono_ms" => 10_000
      })
    ]

  defp record,
    do: %{
      name: "relay.inspect.candidate_transform",
      version: 1,
      status: :applied,
      link_generation: 3,
      result: %{frame: 19_001, mission_generation: @gen, observed: observed()}
    }

  defp ctx(overrides \\ %{}),
    do:
      Map.merge(
        %{
          journal: %{journal_id: "j", entries: entries()},
          now_mono_ms: 12_000,
          max_age_ms: 60_000,
          link: %{generation: 3, adapter_instance_id: @adapter, token_verified: true},
          mission_generation: @gen,
          records: %{@id => record()}
        },
        overrides
      )

  defp with_entries(list), do: ctx(%{journal: %{journal_id: "j", entries: list}})

  defp replace(list, event, fun),
    do: Enum.map(list, fn e -> if e["event"] == event, do: fun.(e), else: e end)

  test "a complete, coherent, recent, qualifying inspection qualifies; its facts are the journal's" do
    assert {:ok, q} = TransformBinding.qualify(ctx(), @id)

    assert q.journal_seq == 7 and q.frame == 19_001 and q.mono_ms == 10_000 and q.age_ms == 2_000 and
             q.adapter == @adapter and q.link_generation == 3 and q.parent == @brick
  end

  test "the lift derives the canonical groups; a supplied group must equal them exactly" do
    assert {:ok, params, binding} = TransformBinding.lift(ctx(), @id, %{})

    assert params == %{
             "mode" => "lift",
             "expect_world" => @pre,
             "expect_local" => @local,
             "expect_parent" => @brick
           }

    assert binding["verified_by"] == "authority" and binding["journal_seq"] == 7 and
             binding["age_ms"] == 2_000

    assert {:ok, ^params, _} = TransformBinding.lift(ctx(), @id, %{"expect_world" => @pre})

    assert {:error, {:expectation_mismatch, "expect_world"}} =
             TransformBinding.lift(ctx(), @id, %{
               "expect_world" => String.replace(@pre, "9e", "9f")
             })
  end

  test "missing, duplicated and out-of-order stages are refusals, never repaired" do
    base = entries()

    assert {:error, {:inspection_accepted_entries, 2}} =
             TransformBinding.qualify(
               with_entries(base ++ [cmd_entry("command.accepted", 8)]),
               @id
             )

    assert {:error, {:inspection_terminal_entries, 2}} =
             TransformBinding.qualify(
               with_entries(
                 base ++
                   [
                     cmd_entry("command.terminal", 8, %{
                       "status" => "applied",
                       "mono_ms" => 10_500
                     })
                   ]
               ),
               @id
             )

    assert {:error, {:inspection_transmitted_entries, 0}} =
             TransformBinding.qualify(
               with_entries(Enum.reject(base, &(&1["event"] == "command.transmitted"))),
               @id
             )

    assert {:error, {:inspection_received_entries, 0}} =
             TransformBinding.qualify(
               with_entries(Enum.reject(base, &(&1["event"] == "command.received"))),
               @id
             )

    assert {:error, :inspection_not_terminal} =
             TransformBinding.qualify(
               with_entries(Enum.reject(base, &(&1["event"] == "command.terminal"))),
               @id
             )

    assert {:error, :inspection_stages_out_of_order} =
             TransformBinding.qualify(
               with_entries(replace(base, "command.received", &Map.put(&1, "seq", 9))),
               @id
             )
  end

  test "an unknown outcome or a refinement is a contradictory outcome, never a qualifying inspection" do
    for event <- ["command.unknown", "command.unknown_refined"] do
      assert {:error, :inspection_outcome_unknown} =
               TransformBinding.qualify(with_entries(entries() ++ [cmd_entry(event, 8)]), @id)
    end
  end

  test "the in-memory record must exist and agree with the journal" do
    assert {:error, :inspection_record_missing} =
             TransformBinding.qualify(ctx(%{records: %{}}), @id)

    disagreeing = [
      {%{record() | status: :unknown}, {:inspection_record_status, :unknown}},
      {%{record() | link_generation: 2}, :inspection_record_disagrees},
      {%{record() | name: "relay.inspect.candidate"}, :inspection_record_disagrees},
      {put_in(record(), [:result, :frame], 19_002), :inspection_record_disagrees},
      {put_in(record(), [:result, :mission_generation], "other"), :inspection_record_disagrees},
      {put_in(
         record(),
         [:result, :observed, "cand_world_words"],
         f(String.replace(@pre, "9e", "9f"))
       ), :inspection_record_disagrees}
    ]

    for {r, reason} <- disagreeing do
      assert {:error, ^reason} = TransformBinding.qualify(ctx(%{records: %{@id => r}}), @id)
    end
  end

  test "the identity and token entries of the inspection's link are required, unambiguous and the current link's" do
    base = entries()

    assert {:error, :adapter_identity_not_journaled} =
             TransformBinding.qualify(
               with_entries(Enum.reject(base, &(&1["event"] == "peer.identified"))),
               @id
             )

    assert {:error, :adapter_identity_ambiguous} =
             TransformBinding.qualify(
               with_entries(
                 base ++
                   [
                     %{
                       "event" => "peer.identified",
                       "seq" => 8,
                       "link_generation" => 3,
                       "adapter_instance_id" => "x"
                     }
                   ]
               ),
               @id
             )

    assert {:error, :inspection_link_not_token_verified} =
             TransformBinding.qualify(
               with_entries(Enum.reject(base, &(&1["event"] == "peer.token_verified"))),
               @id
             )

    assert {:error, :inspection_link_not_token_verified} =
             TransformBinding.qualify(
               with_entries(
                 replace(base, "peer.token_verified", &Map.put(&1, "adapter_instance_id", "x"))
               ),
               @id
             )

    assert {:error, :inspection_link_not_token_verified} =
             TransformBinding.qualify(
               ctx(%{
                 link: %{generation: 3, adapter_instance_id: @adapter, token_verified: false}
               }),
               @id
             )

    assert {:error, :inspection_adapter_mismatch} =
             TransformBinding.qualify(
               ctx(%{link: %{generation: 3, adapter_instance_id: "other", token_verified: true}}),
               @id
             )

    assert {:error, :inspection_link_not_current} =
             TransformBinding.qualify(
               ctx(%{
                 link: %{generation: 4, adapter_instance_id: @adapter, token_verified: true}
               }),
               @id
             )
  end

  test "the age is the journal's own clock: a terminal without one, a clock behind it or past the bound is stale; no generation is no binding" do
    assert {:error, :inspection_stale} =
             TransformBinding.qualify(
               with_entries(replace(entries(), "command.terminal", &Map.delete(&1, "mono_ms"))),
               @id
             )

    assert {:error, :inspection_stale} = TransformBinding.qualify(ctx(%{now_mono_ms: 9_000}), @id)

    assert {:error, :inspection_stale} =
             TransformBinding.qualify(ctx(%{now_mono_ms: 70_001}), @id)

    assert {:ok, _} = TransformBinding.qualify(ctx(%{now_mono_ms: 70_000}), @id)

    assert {:error, :inspection_generation_mismatch} =
             TransformBinding.qualify(ctx(%{mission_generation: nil}), @id)
  end
end
