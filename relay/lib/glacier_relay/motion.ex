defmodule GlacierRelay.Motion do
  @moduledoc """
  M7-B1: the operator-facing motion API on a game host (`docs/design/M7_NETWORK_GHOST.md` section
  15; ADR 0010 as amended), for an explicitly controlled local IEx or RPC context like
  `GlacierRelay.Command`. There is no browser path and no Phoenix route; every call is refused
  unless the motion subtree is running (`config :glacier_relay, :motion, enabled: true`, inside the
  command subtree).

  Opening and restoring go through `Command.Authority` only: this module prepares the hub for the
  id, then asks the authority to issue the motion-gated command under its own arming, binding and
  exclusivity rules; the hub activates the share or session only when the authority reports the
  native's confirmation. Closing needs no arming and never goes through the authority (it travels
  on the motion link). In B1 the native peer is a test fake: nothing here has run against HITMAN.
  """

  alias GlacierRelay.Command.{Authority, Schema}
  alias GlacierRelay.Motion.{Admission, Destination, Hub}

  @doc "Whether the motion subtree is running in this node."
  def enabled?, do: Process.whereis(GlacierRelay.Motion.Supervisor) != nil

  @doc "The hub's and the authority's motion state."
  def status, do: guarded(fn -> %{hub: Hub.status(), authority: Authority.status().motion} end)

  @doc """
  Opens a share of the local hero's samples to the connected peer. `opts`: `:duration_ms`
  (required, ≤ 300,000), `:interval_ms` (50), `:label`, `:expected_generation` (required: the
  mission generation precondition), `:ttl_ms`, `:peer_boot_id` / `:peer_connection_generation`
  (optional assertions about the peer the operator means). Needs inert arming. Returns
  `{:ok, %{share_id, command_id}}` or `{:error, reason}`.
  """
  def open_share(opts) when is_list(opts) do
    guarded(fn ->
      with {:ok, hub} <- hub(),
           {:ok, peer} <- peer(hub, opts),
           {:ok, link} <- link(hub),
           true <-
             is_binary(opts[:expected_generation]) or {:error, :expected_generation_required} do
        st = %{
          share_id: Schema.uuid4(),
          motion_link_generation: link.generation,
          duration_ms: Keyword.fetch!(opts, :duration_ms),
          interval_ms: Keyword.get(opts, :interval_ms, 50),
          peer: %{connection_generation: peer.connection_generation, boot_id: peer.boot_id},
          label: Keyword.get(opts, :label)
        }

        with {:ok, st} <- Hub.prepare_share(st) do
          params = %{
            "mode" => "open",
            "share_id" => st.share_id,
            "motion_link_generation" => st.motion_link_generation,
            "duration_ms" => st.duration_ms,
            "interval_ms" => st.interval_ms
          }

          case Authority.issue(
                 "player.pose.share",
                 1,
                 params,
                 issue_opts(opts, share_statement: st)
               ) do
            {:ok, id} ->
              {:ok, %{share_id: st.share_id, command_id: id}}

            error ->
              Hub.abandon(st.share_id)
              error
          end
        end
      end
    end)
  end

  @doc "Closes the share (no arming)."
  def close_share(reason \\ :operator), do: guarded(fn -> Hub.close_share(reason) end)

  @doc """
  Opens one destination session on the compiled candidate for one announced stream of the
  connected peer. `opts`: `:inspection_command_id` (required: ONE completed
  `relay.inspect.candidate_transform/1` of this authority — the opening snapshot), `:expected_generation`
  (required), `:stream_id` and `:source_kind` (required: the stream the operator approves and the
  kind it must declare), `:limits` (a map of `Motion.Destination.limit_bounds/0` keys; defaults
  otherwise), `:ttl_ms`, `:peer_boot_id` / `:peer_connection_generation` (optional assertions), and
  `:admission` (optional; a `synthetic` stream only: a `Motion.Admission` `stationary_prefix`
  condition — design section 29 — which the hub checks against the stream's progress at preparation
  and again at activation, the authority against the inspection, and the destination at its first
  target). Needs the effectful arming. Returns `{:ok, %{session_id, command_id}}` or
  `{:error, reason}`.
  """
  def open_session(opts) when is_list(opts) do
    guarded(fn ->
      with {:ok, hub} <- hub(),
           {:ok, peer} <- peer(hub, opts),
           {:ok, link} <- link(hub),
           true <- is_binary(opts[:stream_id]) or {:error, :stream_id_required},
           true <- opts[:source_kind] in ["game", "synthetic"] or {:error, :source_kind_required},
           true <-
             is_binary(opts[:inspection_command_id]) or {:error, :inspection_command_id_required},
           true <-
             is_binary(opts[:expected_generation]) or {:error, :expected_generation_required},
           {:ok, limits} <- Destination.limits(Keyword.get(opts, :limits, %{})),
           {:ok, admission} <- Admission.validate(opts[:admission]),
           true <-
             admission == nil or opts[:source_kind] == "synthetic" or
               {:error, :admission_requires_synthetic} do
        approval = %{
          session_id: Schema.uuid4(),
          peer: %{
            connection_generation: peer.connection_generation,
            boot_id: peer.boot_id,
            label: peer.label,
            pin: peer.pin
          },
          stream_id: opts[:stream_id],
          source_kind: opts[:source_kind],
          motion_link_generation: link.generation,
          limits: limits,
          mapping: "identity",
          admission: admission
        }

        with {:ok, approval} <- Hub.prepare_session(approval) do
          params = %{"mode" => "open", "session_id" => approval.session_id}

          case Authority.issue(
                 "candidate.motion.session",
                 1,
                 params,
                 issue_opts(opts,
                   motion_approval: approval,
                   inspection_command_id: opts[:inspection_command_id]
                 )
               ) do
            {:ok, id} ->
              {:ok, %{session_id: approval.session_id, command_id: id}}

            error ->
              Hub.abandon(approval.session_id)
              error
          end
        end
      end
    end)
  end

  @doc "Ends the destination session (no arming; the native confirms or the close becomes unknown)."
  def close_session(reason \\ :operator), do: guarded(fn -> Hub.close_session(reason) end)

  @doc """
  Restores a closed session's candidate to its opening preimage. `opts`: `:inspection_command_id`
  (required: a completed exact inspection after the close), `:expected_generation`, `:ttl_ms`.
  Needs fresh effectful arming; `{:error, :already_at_baseline}` submits nothing.
  """
  def restore_session(session_id, opts) when is_binary(session_id) and is_list(opts) do
    guarded(fn ->
      Authority.issue(
        "candidate.motion.session",
        1,
        %{"mode" => "restore", "session_id" => session_id},
        issue_opts(opts, inspection_command_id: opts[:inspection_command_id])
      )
    end)
  end

  @doc """
  Releases a cleanly closed session whose candidate is already at its opening preimage (the answer
  `restore_session/2` gives as `{:error, :already_at_baseline}`). `opts`: `:inspection_command_id`
  (a completed exact inspection after the close whose words equal the preimage),
  `:expected_generation`. No arming: nothing is submitted; the release is journaled.
  """
  def confirm_baseline(session_id, opts) when is_binary(session_id) and is_list(opts),
    do: guarded(fn -> Authority.motion_confirm_baseline(session_id, opts) end)

  defp issue_opts(opts, extra) do
    base = Keyword.take(opts, [:ttl_ms])

    base =
      case opts[:expected_generation] do
        gen when is_binary(gen) ->
          Keyword.put(base, :preconditions, %{"mission_generation" => gen})

        _ ->
          base
      end

    Keyword.merge(base, extra)
  end

  defp hub, do: {:ok, Hub.status()}

  defp peer(%{peer: nil}, _opts), do: {:error, :no_peer}

  defp peer(%{peer: p}, opts) do
    cond do
      opts[:peer_boot_id] && opts[:peer_boot_id] != p.boot_id ->
        {:error, :peer_boot_mismatch}

      opts[:peer_connection_generation] &&
          opts[:peer_connection_generation] != p.connection_generation ->
        {:error, :peer_connection_mismatch}

      true ->
        {:ok, p}
    end
  end

  defp link(%{link: nil}), do: {:error, :no_bound_motion_link}
  defp link(%{link: l}), do: {:ok, l}

  defp guarded(fun), do: if(enabled?(), do: fun.(), else: {:error, :motion_disabled})
end
