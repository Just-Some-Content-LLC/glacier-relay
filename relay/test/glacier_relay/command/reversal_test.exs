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

    assert plan.requires == [:qualifying_inspection, :same_mission_generation, :effectful_arming]

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
  end

  test "an uncertain outcome is never planned, whatever later observations say (correction B / N3): unexpected tuple, post-call generation change, missing read-back, fault, unknown, conflicting observations" do
    [h, c, p, a, t, r, _term] = base_entries()

    elsewhere = %{
      "disguise_repository_id" => "2018db77-aa8a-4bf9-9afb-56bdaa161156",
      "charset" => 0,
      "variation" => 0
    }

    later = %{
      "event" => "operator.observation",
      "command_id" => @id,
      "type" => "later_frame_read_back",
      "conclusion" => "consistent"
    }

    # an unexpected tuple (complete tuples, effect uncertain), with and without a consistent later read-back
    assert {:error, :effect_uncertain} =
             Reversal.plan(
               write([h, c, p, a, t, r, terminal("uncertain", @previous, elsewhere)]),
               @id
             )

    assert {:error, :effect_uncertain} =
             Reversal.plan(
               write([h, c, p, a, t, r, terminal("uncertain", @previous, elsewhere), later]),
               @id
             )

    # a post-call generation change: the tuples equal the request, the effect is still uncertain
    assert {:error, :effect_uncertain} =
             Reversal.plan(
               write([h, c, p, a, t, r, terminal("uncertain", @previous, @current), later]),
               @id
             )

    # a missing read-back: no current tuple at all
    missing = terminal("uncertain", @previous, @current)
    missing = put_in(missing, ["observed", "current_outfit_id"], field("unavailable"))

    assert {:error, :current_tuple_unobserved} =
             Reversal.plan(write([h, c, p, a, t, r, missing, later]), @id)

    # a native fault: a failed terminal with a possible effect
    faulted = terminal("uncertain", @previous, @current) |> Map.put("status", "failed")

    assert {:error, {:not_applied, "failed"}} =
             Reversal.plan(write([h, c, p, a, t, r, faulted, later]), @id)

    # an unknown outcome, even with a later observation
    unknown = %{"event" => "command.unknown", "command_id" => @id, "link_generation" => 1}

    assert {:error, :outcome_unknown} =
             Reversal.plan(write([h, c, p, a, t, r, unknown, later]), @id)

    # conflicting observations change nothing: uncertain stays unplannable; the original journal
    # status and every observation remain in the file
    inconsistent = Map.put(later, "conclusion", "inconsistent")

    path =
      write([h, c, p, a, t, r, terminal("uncertain", @previous, elsewhere), later, inconsistent])

    assert {:error, :effect_uncertain} = Reversal.plan(path, @id)
    assert {:ok, read} = Journal.read(path)
    assert Enum.count(read.entries, &(&1["event"] == "operator.observation")) == 2

    assert Enum.find(read.entries, &(&1["event"] == "command.terminal"))["observed"]["effect"][
             "value"
           ] == "uncertain"
  end

  # -- correction C: the inspection binding ---------------------------------------------------------

  @insp "1d2e3f40-5161-4728-9394-a5b6c7d8e9f0"

  defp inspection_entries(overrides \\ %{}, hero \\ @current, opts \\ []) do
    link = Keyword.get(opts, :link_generation, 1)
    frame = Keyword.get(opts, :frame, 20_300)
    mono = Keyword.get(opts, :mono_ms, 9_000)
    gen = Keyword.get(opts, :generation, @gen)

    observed =
      if hero == :unobserved do
        %{"hero_outfit_id" => field("unavailable")}
      else
        %{
          "hero_outfit_id" => field("observed", hero["disguise_repository_id"]),
          "hero_charset" => field("observed", hero["charset"]),
          "hero_variation" => field("observed", hero["variation"])
        }
      end

    accepted =
      Map.merge(
        %{
          "event" => "command.accepted",
          "command_id" => @insp,
          "link_generation" => link,
          "name" => "relay.inspect.outfit",
          "version" => 1
        },
        Map.get(overrides, :accepted, %{})
      )

    terminal =
      Map.merge(
        %{
          "event" => "command.terminal",
          "command_id" => @insp,
          "link_generation" => link,
          "name" => "relay.inspect.outfit",
          "version" => 1,
          "status" => "applied",
          "frame" => frame,
          "mono_ms" => mono,
          "mission_generation" => gen,
          "observed" => observed
        },
        Map.get(overrides, :terminal, %{})
      )

    [
      accepted,
      %{"event" => "command.transmitted", "command_id" => @insp},
      %{"event" => "command.received", "command_id" => @insp},
      terminal
    ]
  end

  defp plan_from(entries) do
    {:ok, plan} = Reversal.plan(write(entries), @id)
    plan
  end

  test "the inspection binding accepts only a completed inspection of this adapter, link, generation and tuple, later than the command and recent" do
    base = base_entries()
    plan = plan_from(base)
    assert plan.frame == nil or is_integer(plan.frame)
    # the fixture's terminal carries no frame; give the effectful terminal one
    [h, c, p, a, t, r, term] = base
    term = Map.put(term, "frame", 20_000)
    plan = plan_from([h, c, p, a, t, r, term])

    assert plan.frame == 20_000 and
             plan.requires == [
               :qualifying_inspection,
               :same_mission_generation,
               :effectful_arming
             ]

    ok = [h, c, p, a, t, r, term] ++ inspection_entries()

    verify = fn entries, id, opts ->
      Reversal.verify_inspection(
        entries,
        plan,
        id,
        Keyword.merge([now_mono_ms: 10_000, link_generation: 1, max_age_ms: 60_000], opts)
      )
    end

    assert {:ok, binding} = verify.(ok, @insp, [])

    assert binding.frame == 20_300 and binding.command_frame == 20_000 and binding.age_ms == 1_000 and
             binding.hero == @current

    assert binding.label =~ "not proof"

    # missing or unknown inspection id; an operator-supplied map is never enough
    assert {:error, :inspection_command_id_required} = verify.(ok, nil, [])

    assert {:error, :inspection_not_in_journal} =
             verify.(ok, "ffffffff-0000-4000-8000-000000000000", [])

    # not an inspection; not applied; outcome unknown; not terminal
    assert {:error, :not_an_inspection} =
             verify.(
               [h, c, p, a, t, r, term] ++
                 inspection_entries(%{accepted: %{"name" => "relay.probe"}}),
               @insp,
               []
             )

    assert {:error, {:inspection_not_applied, "unavailable"}} =
             verify.(
               [h, c, p, a, t, r, term] ++
                 inspection_entries(%{terminal: %{"status" => "unavailable"}}),
               @insp,
               []
             )

    assert {:error, :inspection_outcome_unknown} =
             verify.(ok ++ [%{"event" => "command.unknown", "command_id" => @insp}], @insp, [])

    assert {:error, :inspection_not_terminal} =
             verify.([h, c, p, a, t, r, term] ++ Enum.take(inspection_entries(), 3), @insp, [])

    # another adapter instance on the inspection's link; a link that is not the current one
    other_link =
      [
        h,
        c,
        p,
        %{"event" => "peer.identified", "link_generation" => 2, "adapter_instance_id" => @target},
        a,
        t,
        r,
        term
      ] ++ inspection_entries(%{}, @current, link_generation: 2)

    assert {:error, :inspection_adapter_mismatch} = verify.(other_link, @insp, link_generation: 2)
    assert {:error, :inspection_link_not_current} = verify.(ok, @insp, link_generation: 2)
    assert {:error, :inspection_link_not_current} = verify.(ok, @insp, link_generation: nil)

    # a previous attempt's inspection (another mission generation) never authorizes the next
    assert {:error, :inspection_generation_mismatch} =
             verify.(
               [h, c, p, a, t, r, term] ++
                 inspection_entries(%{}, @current, generation: "other-attempt"),
               @insp,
               []
             )

    # the hero tuple unobserved or different from the plan's expected-current tuple
    assert {:error, :inspection_hero_unobserved} =
             verify.([h, c, p, a, t, r, term] ++ inspection_entries(%{}, :unobserved), @insp, [])

    assert {:error, {:inspection_tuple_mismatch, @previous}} =
             verify.([h, c, p, a, t, r, term] ++ inspection_entries(%{}, @previous), @insp, [])

    assert {:error, {:inspection_tuple_mismatch, _}} =
             verify.(
               [h, c, p, a, t, r, term] ++
                 inspection_entries(%{}, Map.put(@current, "variation", 1)),
               @insp,
               []
             )

    # not later than the command's applying frame; stale; a clock that ran backwards
    assert {:error, :inspection_not_later} =
             verify.(
               [h, c, p, a, t, r, term] ++ inspection_entries(%{}, @current, frame: 20_000),
               @insp,
               []
             )

    assert {:error, :inspection_not_later} =
             verify.(
               [h, c, p, a, t, r, term] ++ inspection_entries(%{}, @current, frame: 19_000),
               @insp,
               []
             )

    assert {:error, :inspection_stale} = verify.(ok, @insp, now_mono_ms: 70_001)
    assert {:ok, _} = verify.(ok, @insp, now_mono_ms: 69_000)
    assert {:error, :inspection_stale} = verify.(ok, @insp, now_mono_ms: 8_000)
    assert {:error, :inspection_stale} = verify.(ok, @insp, max_age_ms: 500)
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
