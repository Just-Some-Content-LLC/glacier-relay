defmodule GlacierRelay.Command.ReversalTest do
  @moduledoc """
  M5 C-2A: the reversal planner over journal files written for the test — the complete prior tuple
  from verified, durable evidence; every missing, degraded, conflicting or unaudited condition
  fails closed with a named reason; the in-memory record is cross-checked, never trusted alone.
  No native command is performed.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.{Journal, Reversal}

  @id "9c8f3a75-7054-457c-919d-ee87e77f57d9"
  @adapter "aaf540dd-c6df-4429-8fa5-84bc8933a13e"
  @gen "2516103519921974492-5fd4f3e1-0fa5-408f-bce8-b58923581360"
  @suit "874c4c48-0a8b-49e9-883e-49fc5f1fb051"
  @target "4fc9396e-2619-4e66-a51e-2bd366230da7"
  @journal_id "86f8a2d7-c92d-43c3-a7b7-03310b9d3719"

  @previous %{"disguise_repository_id" => @suit, "charset" => 0, "variation" => 0}
  @current %{"disguise_repository_id" => @target, "charset" => 0, "variation" => 0}

  defp field(status, value \\ nil),
    do: if(value == nil, do: %{"status" => status}, else: %{"status" => status, "value" => value})

  defp observed(previous, current, effect) do
    %{
      "previous_outfit_id" => field("observed", previous["disguise_repository_id"]),
      "previous_charset" => field("observed", previous["charset"]),
      "previous_variation" => field("observed", previous["variation"]),
      "current_outfit_id" => field("observed", current["disguise_repository_id"]),
      "current_charset" => field("observed", current["charset"]),
      "current_variation" => field("observed", current["variation"]),
      "setter_called" => field("observed", true),
      "effect" => field("observed", effect)
    }
  end

  defp stage(event, fields \\ %{}) do
    Map.merge(
      %{
        "event" => event,
        "command_id" => @id,
        "link_generation" => 1,
        "name" => "player.outfit.set",
        "version" => 2
      },
      fields
    )
  end

  defp accepted,
    do:
      stage("command.accepted", %{
        "params" => Map.put(@current, "expect_current", @previous),
        "preconditions" => %{"mission_generation" => @gen}
      })

  defp terminal(effect \\ "changed", previous \\ @previous, current \\ @current),
    do:
      stage("command.terminal", %{
        "status" => "applied",
        "observed" => observed(previous, current, effect),
        "mission_generation" => @gen
      })

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

  # Writes entries as the journal would, with its own fields; `opts` can break the invariants.
  defp write(entries, opts \\ []) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glacier-relay-reversal-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "commands-#{@journal_id}.ndjson")

    lines =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, seq} ->
        seq = if opts[:gap] && seq == opts[:gap], do: seq + 1, else: seq
        id = if opts[:mixed] && seq == opts[:mixed], do: "other", else: @journal_id

        JSON.encode!(
          Map.merge(entry, %{
            "journal" => Journal.version(),
            "journal_id" => id,
            "seq" => seq,
            "at" => "2026-10-14T03:34:20.000Z",
            "mono_ms" => seq
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
        result: %{observed: observed(@previous, @current, "changed")}
      },
      overrides
    )
  end

  test "the plan carries the complete prior tuple, the identities, the generation and what issuing it still requires" do
    path = write(base_entries())
    assert {:ok, plan} = Reversal.plan(path, @id, record: record())

    assert plan.reversal_of == @id and plan.adapter_instance_id == @adapter and
             plan.link_generation == 1 and plan.mission_generation == @gen

    assert plan.original_expect_current == @previous and plan.original_target == @current
    assert plan.previous == @previous and plan.current == @current and plan.effect == "changed"
    assert plan.params == Map.put(@previous, "expect_current", @current)
    assert plan.journal_id == @journal_id and plan.journal_seq == 7 and plan.audit == :continuous

    assert plan.requires == [
             :fresh_expect_current_confirmation,
             :same_mission_generation,
             :effectful_arming
           ]

    assert plan.consequences == :unknown
    # without the in-memory record the journal alone suffices (it is the evidence)
    assert {:ok, ^plan} = Reversal.plan(path, @id)
  end

  test "every incomplete, ambiguous or unknown outcome fails closed with a named reason" do
    [h, c, p, a, t, r, term] = base_entries()
    other = %{"event" => "command.unknown", "command_id" => @id, "link_generation" => 1}

    cases = [
      {:command_not_in_journal, [h, c, p]},
      {{:received_entries, 0}, [h, c, p, a, t, term]},
      {{:transmitted_entries, 0}, [h, c, p, a, r, term]},
      {{:accepted_entries, 0}, [h, c, p, t, r, term]},
      {{:terminal_entries, 2}, [h, c, p, a, t, r, term, term]},
      {{:terminal_entries, 0}, [h, c, p, a, t, r]},
      {:outcome_unknown, [h, c, p, a, t, r, other]},
      {:outcome_refined_unknown,
       [h, c, p, a, t, r, other, Map.put(other, "event", "command.unknown_refined")]},
      {:stages_out_of_order, [h, c, p, a, r, t, term]},
      {{:not_applied, "precondition_failed"},
       [h, c, p, a, t, r, Map.put(term, "status", "precondition_failed")]},
      {:previous_tuple_unobserved,
       [h, c, p, a, t, r, put_in(term, ["observed", "previous_charset"], field("unavailable"))]},
      {:current_tuple_unobserved,
       [h, c, p, a, t, r, put_in(term, ["observed", "current_outfit_id"], field("unavailable"))]},
      {:effect_unchanged, [h, c, p, a, t, r, terminal("unchanged", @previous, @previous)]},
      {:effect_uncertain, [h, c, p, a, t, r, terminal("uncertain")]},
      {:effect_unreported,
       [h, c, p, a, t, r, put_in(term, ["observed", "effect"], field("unavailable"))]},
      {{:effect_unexpected, "maybe"}, [h, c, p, a, t, r, terminal("maybe")]},
      {:adapter_identity_not_journaled, [h, c, a, t, r, term]},
      {:not_an_effectful_outfit_command,
       [h, c, p, Map.merge(a, %{"name" => "relay.probe", "version" => 1}), t, r, term]},
      {:expect_current_incomplete,
       [
         h,
         c,
         p,
         put_in(a, ["params", "expect_current"], %{"disguise_repository_id" => @suit}),
         t,
         r,
         term
       ]},
      {:mission_generation_missing, [h, c, p, Map.put(a, "preconditions", %{}), t, r, term]}
    ]

    for {reason, entries} <- cases do
      assert {:error, ^reason} = Reversal.plan(write(entries), @id), inspect(reason)
    end

    # an uncertain effect is planable only with a journaled consistent later-frame read-back
    later = %{
      "event" => "operator.observation",
      "command_id" => @id,
      "type" => "later_frame_read_back",
      "conclusion" => "consistent"
    }

    assert {:ok, plan} =
             Reversal.plan(write([h, c, p, a, t, r, terminal("uncertain"), later]), @id)

    assert plan.effect =~ "uncertain; later-frame read-back consistent"
    inconsistent = Map.put(later, "conclusion", "inconsistent")

    assert {:error, :effect_uncertain} =
             Reversal.plan(write([h, c, p, a, t, r, terminal("uncertain"), inconsistent]), @id)
  end

  test "an unreadable, non-contiguous or mixed journal, a degraded journal or audit, fails closed" do
    assert {:error, {:unreadable_line, 7}} =
             Reversal.plan(write(base_entries(), truncate: true), @id)

    assert {:error, :sequence_not_contiguous} = Reversal.plan(write(base_entries(), gap: 4), @id)
    assert {:error, :mixed_journal_ids} = Reversal.plan(write(base_entries(), mixed: 3), @id)
    assert {:error, :no_header} = Reversal.plan(write(tl(base_entries())), @id)
    assert {:error, :enoent} = Reversal.plan("/nonexistent/commands-x.ndjson", @id)
    path = write(base_entries())
    assert {:error, :journal_degraded} = Reversal.plan(path, @id, journal_status: :degraded)
    assert {:error, :audit_degraded} = Reversal.plan(path, @id, audit: :degraded)
    assert {:ok, read} = Journal.read(path)
    assert read.journal_id == @journal_id and length(read.entries) == 7 and not read.closed?
  end

  test "the in-memory record is cross-checked against the journal and never trusted alone" do
    path = write(base_entries())
    assert {:ok, _} = Reversal.plan(path, @id, record: record())

    assert {:error, {:record_audit, {:gap, [:applied]}}} =
             Reversal.plan(path, @id, record: record(%{audit: {:gap, [:applied]}}))

    assert {:error, {:record_status, :unknown}} =
             Reversal.plan(path, @id, record: record(%{status: :unknown}))

    assert {:error, :record_generation_disagrees} =
             Reversal.plan(path, @id, record: record(%{link_generation: 2}))

    assert {:error, :record_adapter_disagrees} =
             Reversal.plan(path, @id, record: record(%{adapter_instance_id: @target}))

    assert {:error, :record_previous_disagrees} =
             Reversal.plan(path, @id,
               record: record(%{result: %{observed: observed(@current, @current, "changed")}})
             )

    assert {:error, :record_current_disagrees} =
             Reversal.plan(path, @id,
               record: record(%{result: %{observed: observed(@previous, @previous, "changed")}})
             )
  end
end
