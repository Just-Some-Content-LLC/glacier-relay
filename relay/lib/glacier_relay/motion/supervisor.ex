defmodule GlacierRelay.Motion.Supervisor do
  @moduledoc """
  M7-B1: the optional motion subtree of a game host (`docs/design/M7_NETWORK_GHOST.md` section 15;
  ADR 0010 as amended), started only inside `Command.Supervisor` and only when `config
  :glacier_relay, :motion, enabled: true` — so never without the command authority, and never on a
  headless peer (`GlacierRelay.HeadlessPeer`). When disabled nothing of it starts and the command
  subtree is exactly M6's.

  Children, `rest_for_one`: the motion trace (required evidence; its loss restarts everything after
  it), `Motion.Hub`, the motion-link supervisor, the motion-link listener (`127.0.0.1:4750`), and —
  when a peer is configured — the peer endpoint, which on a game host only **connects out** to the
  one allowlisted peer (loopback only in B1). A hub restart drops every link, and the native closes
  its share and session on the loss.
  """

  use Supervisor

  alias GlacierRelay.Motion.{Hub, Listener, Trace}
  alias GlacierRelay.Peer.Endpoint

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    trace_opts =
      [name: Trace, role: "host", dir: Keyword.get(opts, :trace_dir)] ++
        Keyword.take(opts, [:trace_max_records, :trace_max_bytes, :trace_flush_ms])
        |> Enum.map(fn
          {:trace_max_records, v} -> {:max_records, v}
          {:trace_max_bytes, v} -> {:max_bytes, v}
          {:trace_flush_ms, v} -> {:flush_ms, v}
          other -> other
        end)

    peer =
      case Keyword.get(opts, :peer) do
        nil ->
          []

        peer_opts ->
          [
            {Endpoint,
             Keyword.merge(peer_opts,
               role: :connect,
               name: GlacierRelay.Motion.PeerEndpoint,
               handler: {Hub, Hub}
             )}
          ]
      end

    children =
      [
        %{id: Trace, start: {Trace, :start_link, [trace_opts]}},
        {Hub, trace: Trace},
        {DynamicSupervisor, name: GlacierRelay.Motion.LinkSupervisor, strategy: :one_for_one},
        {Listener, Keyword.take(opts, [:ip, :port, :hello_timeout_ms])}
      ] ++ peer

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
