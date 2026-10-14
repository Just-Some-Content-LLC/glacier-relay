defmodule GlacierRelay.Command do
  @moduledoc """
  The operator-facing command API (M5-A): the smallest surface needed to arm, disarm, probe and
  inspect, for an explicitly controlled local IEx or RPC context. There is no browser path, no
  Phoenix route and no persistence of arming; every call below is refused unless the command
  subtree is enabled (`GLACIER_RELAY_COMMAND=1`) and running.

  M5-A proves that BEAM can govern a bounded command exchange with a peer; it authorizes no
  action on Glacier: the only issuable command is `relay.probe`, which has no effect.
  """

  alias GlacierRelay.Command.Authority

  @doc "Whether the command subtree is running in this node."
  def enabled?, do: Process.whereis(GlacierRelay.Command.Supervisor) != nil

  @doc "Arms the authority for the current identified link."
  def arm, do: guarded(fn -> Authority.arm() end)

  @doc "Disarms the authority."
  def disarm, do: guarded(fn -> Authority.disarm() end)

  @doc "Issues `relay.probe` v1 (no effect). Returns `{:ok, command_id}` or `{:error, reason}`."
  def probe(opts \\ []), do: guarded(fn -> Authority.issue("relay.probe", 1, %{}, opts) end)

  @doc "The authority's status, or `{:error, :command_disabled}`."
  def status, do: guarded(fn -> Authority.status() end)

  @doc "One command's record by id."
  def command(id), do: guarded(fn -> Authority.command(id) end)

  defp guarded(fun), do: if(enabled?(), do: fun.(), else: {:error, :command_disabled})
end
