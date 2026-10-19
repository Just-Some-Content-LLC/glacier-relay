defmodule GlacierRelay.Command.Supervisor do
  @moduledoc """
  The optional command subtree (M5-A, ADR 0009), placed last under the application supervisor and
  started only when `config :glacier_relay, :command, enabled: true` (`GLACIER_RELAY_COMMAND=1`).
  When disabled nothing of it starts and the M4 tree is unchanged.

  Children, `rest_for_one`: the journal first (every decision is audited before it is acted on),
  the authority, the link supervisor, the listener. A journal failure therefore restarts the
  authority (disarmed, no link) and drops every link; a listener failure rebinds without touching
  the authority's state. M7-B1: the optional motion subtree (`Motion.Supervisor`) comes last, only
  when `config :glacier_relay, :motion, enabled: true`; disabled, the children are exactly M6's.
  """

  use Supervisor

  alias GlacierRelay.Command.{Authority, Journal, Listener}

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    config = :glacier_relay |> Application.get_env(:command, []) |> Keyword.merge(opts)

    motion =
      :glacier_relay
      |> Application.get_env(:motion, [])
      |> Keyword.merge(Keyword.get(opts, :motion, []))

    children =
      [
        {Journal, Keyword.take(config, [:journal_dir, :writer]) |> rename(:journal_dir, :dir)},
        {Authority,
         Keyword.take(config, [
           :ack_timeout_ms,
           :grace_ms,
           :default_ttl_ms,
           :max_ttl_ms,
           :min_ttl_ms,
           :effectful,
           :token,
           :token_file,
           :effectful_ttl_default_ms,
           :effectful_ttl_max_ms,
           :evidence_max_age_ms,
           :evidence_clock_skew_ms,
           :reversal_inspection_max_age_ms
         ])
         |> Keyword.merge(
           motion: Keyword.get(motion, :enabled, false) == true,
           max_motion_sessions: Keyword.get(motion, :max_sessions, 1),
           # the parent's latch when given (the application creates one at its start), else one
           # per start of this subtree (tests)
           restart_latch: Keyword.get(config, :restart_latch) || make_ref()
         )},
        {DynamicSupervisor, name: GlacierRelay.Command.LinkSupervisor, strategy: :one_for_one},
        {Listener, Keyword.take(config, [:ip, :port, :max_line_bytes, :hello_timeout_ms])}
      ] ++ motion_children(motion)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # M7-B1: the optional motion subtree, last (an authority restart restarts it and drops its
  # links); only when `config :glacier_relay, :motion, enabled: true` (or the `:motion` option).
  defp motion_children(motion) do
    if Keyword.get(motion, :enabled, false) == true,
      do: [{GlacierRelay.Motion.Supervisor, Keyword.delete(motion, :enabled)}],
      else: []
  end

  defp rename(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, rest} -> rest
      {value, rest} -> Keyword.put(rest, to, value)
    end
  end
end
