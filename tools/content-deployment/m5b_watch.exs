# M5-B in-node watcher (read-only; a script run inside the node, not production code). As the M4
# watcher: one subscriber prints every MissionSession notification with BEAM receipt time. At
# start it also prints the command subtree's listener address, the authority status (disarmed,
# no link), the journal status, and checks that the web subtree is not registered. It never
# arms, issues or disarms; the operator does that through cmd.exs over RPC. The VM stays up.
defmodule M5BW do
  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  def session_loop do
    receive do
      {:relay_event, e} ->
        IO.puts("#{now()} SESSION EVENT #{e.event_type} ##{e.sequence} ts=#{e.timestamp} #{inspect(e.payload, limit: :infinity, printable_limit: :infinity)}")

      {:relay_connection, kind, info} ->
        IO.puts("#{now()} SESSION CONNECTION #{kind} #{inspect(info)}")

      other ->
        IO.puts("#{now()} SESSION OTHER #{inspect(other)}")
    end

    session_loop()
  end
end

:ok = GlacierRelay.MissionSession.subscribe()
children = Supervisor.which_children(GlacierRelay.Supervisor) |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
IO.puts("#{M5BW.now()} watch: node #{node()} wire #{inspect(GlacierRelay.Wire.Listener.address())} dashboard_enabled=#{GlacierRelay.Application.dashboard_enabled?()}")
IO.puts("#{M5BW.now()} watch: application children #{inspect(children)}")
IO.puts("#{M5BW.now()} watch: web supervisor registered: #{Process.whereis(GlacierRelayWeb.Supervisor) != nil}; endpoint registered: #{Process.whereis(GlacierRelayWeb.Endpoint) != nil}; pubsub registered: #{Process.whereis(GlacierRelay.PubSub) != nil}")
IO.puts("#{M5BW.now()} watch: recorder health #{inspect(GlacierRelay.Recording.Recorder.health(), limit: :infinity, printable_limit: :infinity)}")
IO.puts("#{M5BW.now()} watch: command enabled #{GlacierRelay.Command.enabled?()}; command listener #{inspect(GlacierRelay.Command.Listener.address())}")
cmd_children = Supervisor.which_children(GlacierRelay.Command.Supervisor) |> Enum.map(&elem(&1, 0)) |> Enum.reverse()
IO.puts("#{M5BW.now()} watch: command children #{inspect(cmd_children)}")
IO.puts("#{M5BW.now()} watch: command status #{inspect(GlacierRelay.Command.status(), limit: :infinity, printable_limit: :infinity)}")
IO.puts("#{M5BW.now()} watch: command journal #{inspect(GlacierRelay.Command.Journal.status())}")
M5BW.session_loop()
