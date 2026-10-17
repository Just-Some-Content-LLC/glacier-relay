defmodule GlacierRelay.Command.TransformReadbackTest do
  @moduledoc """
  M6-F: the exact-transform read-back decoder and the later-observation classifier — strict word
  groups, unobserved statuses kept visible, the packed restore facts, the later classes under bit
  equality and the declared tolerance, and the control comparison. Pure; no peer, no engine.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.{TransformReadback, TransformWords}

  @pre "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfc5099e"
  @target "3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,00000000,3f800000,00000000,00000000,bfa5099e"
  @local "00000000,00000000,bfc5099e,00000000,00000000,00000000,3f800000"
  @brick "007c57a6ea581f8c"

  defp field(status, value \\ nil, reason \\ nil) do
    %{"status" => status}
    |> then(&if(value != nil, do: Map.put(&1, "value", value), else: &1))
    |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))
  end

  defp inspection(world, opts \\ []) do
    %{
      "generation_fresh" => field("observed", "gen"),
      "targets" => field("observed", "#{@brick},feede715906f747f"),
      "snapshot_version" => field("observed", 1),
      "cand_brick_present" => field("observed", true),
      "cand_index_check" => field("observed", "in_range"),
      "cand_resolved" => field("observed", true),
      "cand_hitman5" => field("observed", true),
      "cand_id_match" => field("observed", true),
      "cand_distinct" => field("observed", true),
      "cand_brick_owner" => field("observed", @brick),
      "cand_spatial" => field("observed", true),
      "cand_spatial_distinct" => field("observed", true),
      "registry_slots" => field("observed", "0:local,1:empty,2:empty,3:empty"),
      "cand_in_registry" => field("observed", false),
      "cand_world_words" => field("observed", world),
      "cand_local_words" => field("observed", @local),
      "cand_dirty" => field("observed", Keyword.get(opts, :dirty, false)),
      "cand_parent" => field("observed", @brick),
      "cand_world" => field("observed", "0,0,-1.539356"),
      "cand_local" => field("observed", "0,0,-1.539356|0,0,0,1"),
      "cand_spatial_flags" =>
        field(
          "observed",
          "visible=1,parent_hidden=0,force_visible=0,dynamic=1,scene_child=1,dirty=0,room=1,tparent=1,tchildren=1"
        ),
      "hero_entity_id" => field("observed", "69bdf7f855ea15e0"),
      "hero_flags" => field("observed", 3),
      "hero_world_words" => field("observed", @pre),
      "hero_local_words" => field("observed", @local),
      "hero_dirty" => field("observed", false),
      "hero_parent" => field("observed", "00b6cedd6778f19c"),
      "hero_world" => field("observed", "0,0,-1.539356"),
      "reads_on_frame" => field("observed", true)
    }
  end

  test "the inspection decodes every group strictly and keeps unobserved statuses visible" do
    d = TransformReadback.decode_inspection(inspection(@pre))
    assert {:ok, words} = d.candidate.world_words
    assert TransformWords.encode(words) == @pre
    assert {:ok, _} = d.candidate.local_words
    assert d.candidate.dirty == {:ok, false} and d.candidate.parent == {:ok, @brick}
    assert d.candidate.world == {:ok, {0.0, 0.0, -1.539356}}
    assert d.cand_in_registry == {:ok, false} and d.snapshot_version == {:ok, 1}
    assert {:ok, [%{slot: 0, match: :local, hero: true} | _]} = d.registry_slots
    assert d.hero.parent == {:ok, "00b6cedd6778f19c"}

    unavailable =
      Map.put(
        inspection(@pre),
        "cand_world_words",
        field("unavailable", nil, "spatial interface not resolved")
      )

    assert TransformReadback.decode_inspection(unavailable).candidate.world_words ==
             {:unobserved, "unavailable"}

    invalid = Map.put(inspection(@pre), "cand_world_words", field("observed", "not words"))

    assert TransformReadback.decode_inspection(invalid).candidate.world_words ==
             {:invalid, "not words"}

    assert TransformReadback.decode_inspection(%{}).candidate.world_words == :missing

    nonfinite =
      Map.put(
        inspection(@pre),
        "cand_local_words",
        field("observed", String.replace(@local, "3f800000", "7f800000"))
      )

    assert {:invalid, _} = TransformReadback.decode_inspection(nonfinite).candidate.local_words
  end

  test "the apply result decodes the three exact groups, the facts and the packed restore facts" do
    observed = %{
      "mode" => field("observed", "restore"),
      "preimage_world_words" => field("observed", @target),
      "preimage_local_words" => field("observed", @local),
      "preimage_parent" => field("observed", @brick),
      "preimage_dirty" => field("observed", false),
      "requested_world_words" => field("observed", @pre),
      "postimage_world_words" => field("observed", @pre),
      "postimage_local_words" => field("observed", @local),
      "postimage_parent" => field("observed", @brick),
      "postimage_dirty" => field("observed", false),
      "post_same_entity" => field("observed", true),
      "world_match" => field("observed", "target"),
      "local_match" => field("observed", "unchanged"),
      "hero_control" => field("observed", "unchanged"),
      "restore_of" => field("observed", "9c8f3a75-7054-457c-919d-ee87e77f57d9"),
      "restore_facts" =>
        field("observed", "world=1,local=1,parent=1,dirty=1,snapshot=1,within_tol=1"),
      "setter_called" => field("observed", true),
      "effect" => field("observed", "changed"),
      "budget_remaining" => field("observed", 0),
      "observed_reduced" => true
    }

    d = TransformReadback.decode_apply(observed)
    assert d.mode == {:ok, "restore"} and d.effect == {:ok, "changed"} and d.reduced
    assert {:ok, pre} = d.preimage.world_words
    assert TransformWords.encode(pre) == @target
    assert {:ok, post} = d.postimage.world_words
    assert TransformWords.encode(post) == @pre

    assert d.restore_facts ==
             {:ok,
              %{
                world: true,
                local: true,
                parent: true,
                dirty: true,
                snapshot: true,
                within_tol: true
              }}

    assert TransformReadback.restore_facts(
             field("observed", "world=1,local=0,parent=1,dirty=1,snapshot=0,within_tol=0")
           ) ==
             {:ok,
              %{
                world: true,
                local: false,
                parent: true,
                dirty: true,
                snapshot: false,
                within_tol: false
              }}

    assert {:invalid, _} = TransformReadback.restore_facts(field("observed", "world=1,local=0"))

    assert {:invalid, _} =
             TransformReadback.restore_facts(
               field("observed", "world=1,local=0,parent=1,dirty=1,snapshot=0,within_tol=2")
             )

    assert TransformReadback.restore_facts(field("unavailable", nil, "not a restore")) ==
             {:unobserved, "unavailable"}

    assert TransformReadback.restore_facts(nil) == :missing
  end

  test "the later classes: bit equality decides held / returned; the tolerance decides near; a dirty cache is indeterminate" do
    {:ok, pre} = TransformWords.decode_world(@pre)
    {:ok, target} = TransformWords.decode_world(@target)

    later = fn world, dirty ->
      TransformReadback.decode_inspection(inspection(world, dirty: dirty)).candidate
    end

    assert TransformReadback.classify_later(later.(@target, false), pre, target) == :held

    assert TransformReadback.classify_later(later.(@pre, false), pre, target) ==
             :returned_to_baseline

    near_target =
      TransformWords.encode(
        List.replace_at(target, 11, TransformWords.to_word(-1.289356 + 1.0e-5))
      )

    assert TransformReadback.classify_later(later.(near_target, false), pre, target) ==
             :near_target

    twin = TransformWords.encode(List.replace_at(target, 11, 0xBFA5099F))
    assert TransformReadback.classify_later(later.(twin, false), pre, target) == :near_target

    near_base =
      TransformWords.encode(List.replace_at(pre, 11, TransformWords.to_word(-1.539356 - 5.0e-5)))

    assert TransformReadback.classify_later(later.(near_base, false), pre, target) ==
             :near_baseline

    drifted =
      TransformWords.encode(List.replace_at(target, 11, TransformWords.to_word(-0.789356)))

    assert TransformReadback.classify_later(later.(drifted, false), pre, target) == :drifted
    assert TransformReadback.classify_later(later.(@target, true), pre, target) == :indeterminate

    assert TransformReadback.classify_later(
             %{world_words: {:unobserved, "unavailable"}, dirty: {:ok, false}},
             pre,
             target
           ) == :unavailable

    assert TransformReadback.classify_later(
             %{world_words: {:ok, target}, dirty: :missing},
             pre,
             target
           ) == :unavailable
  end

  test "the control comparison of the local hero across two inspections" do
    before = TransformReadback.decode_inspection(inspection(@pre)).hero
    assert TransformReadback.classify_control(before, before) == :unchanged

    drift =
      TransformWords.encode(
        List.replace_at(elem(before.world_words, 1), 10, TransformWords.to_word(1.0e-5))
      )

    later =
      TransformReadback.decode_inspection(
        Map.put(inspection(@pre), "hero_world_words", field("observed", drift))
      ).hero

    assert TransformReadback.classify_control(before, later) == :within_tolerance

    moved =
      TransformReadback.decode_inspection(
        Map.put(inspection(@pre), "hero_world_words", field("observed", @target))
      ).hero

    assert TransformReadback.classify_control(before, moved) == :changed

    reparented =
      TransformReadback.decode_inspection(
        Map.put(inspection(@pre), "hero_parent", field("observed", "none"))
      ).hero

    assert TransformReadback.classify_control(before, reparented) == :changed

    gone =
      TransformReadback.decode_inspection(
        Map.put(inspection(@pre), "hero_world_words", field("unavailable"))
      ).hero

    assert TransformReadback.classify_control(before, gone) == :unavailable
  end
end
