defmodule GlacierRelay.Command.Supervisor do
  @moduledoc """
  The optional command subtree (M5-A, ADR 0009), placed last under the application supervisor and
  started only when `config :glacier_relay, :command, enabled: true` (`GLACIER_RELAY_COMMAND=1`).
  When disabled nothing of it starts and the M4 tree is unchanged.

  Children, `rest_for_one`: the journal first (every decision is audited before it is acted on),
  the authority, the link supervisor, the listener last. A journal failure therefore restarts the
  authority (disarmed, no link) and drops every link; a listener failure rebinds without touching
  the authority's state.
  """

  use Supervisor

  alias GlacierRelay.Command.{Authority, Journal, Listener}

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    config = :glacier_relay |> Application.get_env(:command, []) |> Keyword.merge(opts)

    children = [
      {Journal, Keyword.take(config, [:journal_dir, :writer]) |> rename(:journal_dir, :dir)},
      {Authority,
       Keyword.take(config, [
         :ack_timeout_ms,
         :grace_ms,
         :default_ttl_ms,
         :max_ttl_ms,
         :min_ttl_ms
       ])},
      {DynamicSupervisor, name: GlacierRelay.Command.LinkSupervisor, strategy: :one_for_one},
      {Listener, Keyword.take(config, [:ip, :port, :max_line_bytes, :hello_timeout_ms])}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp rename(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, rest} -> rest
      {value, rest} -> Keyword.put(rest, to, value)
    end
  end
end
