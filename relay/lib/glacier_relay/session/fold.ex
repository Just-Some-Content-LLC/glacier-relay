defmodule GlacierRelay.Session.Fold do
  @moduledoc """
  The pure evidence fold of `GlacierRelay.MissionSession` (M4-B, ADR 0008): the one
  implementation that both the live session and an offline replay run. No process, no clock,
  no I/O, no pid or monitor: connections are keyed by the session-assigned connection number.

  Three kinds of evidence enter, in the order the session received them, and are folded into
  `Lifecycle.Instance` values exactly as the M2–M4-A session did:

  - `connection_opened/4` — a connection accepted (transport evidence; unidentified until it
    delivers an envelope).
  - `event/4` — a validated envelope on a connection: the connection is attributed to the
    envelope's instance on its first envelope (`:identified`), re-attributed if the same
    connection later names another instance (`:reattributed`; the earlier instance's connection
    record stays open — the M2 behaviour, preserved and documented in the M4 design, section
    17.11), then the envelope is folded with `Lifecycle.apply_event/3`.
  - `connection_closed/4` — the connection closed with a reason: an unidentified one joins the
    bounded `unidentified` list (newest first, 32); an identified one records an interruption on
    its instance's open attempt and nothing else (`Lifecycle.connection_closed/3`).

  Each function returns `{state, effects}`. Effects are facts about what the fold decided, for
  the caller to notify, record or log; they never carry state of their own:
  `{:identified, info}`, `{:reattributed, info}`, `{:note, instance_id, note}` (the lifecycle
  fold's notes), `{:closed, info}` (with `playing_attempt` when an attempt was last known
  playing), `{:unknown_connection, conn}` (evidence naming a connection the fold never saw;
  impossible live, possible in a replay with missing records).
  """

  alias GlacierRelay.Lifecycle
  alias GlacierRelay.Wire.Envelope

  defmodule State do
    @moduledoc "The fold's state: instances by adapter id, open connections by number, closed unidentified connections."
    defstruct instances: %{}, connections: %{}, unidentified: [], max_unidentified: 32
  end

  @type conn :: pos_integer() | nil
  @type effect :: {atom(), term()} | {:note, String.t(), term()}

  @spec new(keyword()) :: State.t()
  def new(opts \\ []),
    do: %State{max_unidentified: Keyword.get(opts, :max_unidentified, 32)}

  @spec connection_opened(State.t(), pos_integer(), String.t(), DateTime.t() | nil) ::
          {State.t(), [effect()]}
  def connection_opened(%State{} = s, conn, peer, at) when is_integer(conn) do
    connection = %{peer: peer, opened_at: at, instance_id: nil}
    {put_in(s.connections[conn], connection), []}
  end

  @spec event(State.t(), conn(), Envelope.t(), DateTime.t() | nil) :: {State.t(), [effect()]}
  def event(%State{} = s, conn, %Envelope{} = envelope, received_at) do
    id = envelope.adapter_instance_id
    instance = Map.get_lazy(s.instances, id, fn -> Lifecycle.new(id) end)

    {s, instance, effects} = identify(s, conn, id, instance, received_at)
    {instance, notes} = Lifecycle.apply_event(instance, envelope, received_at)

    {put_in(s.instances[id], instance), effects ++ Enum.map(notes, &{:note, id, &1})}
  end

  @spec connection_closed(State.t(), conn(), term(), DateTime.t() | nil) ::
          {State.t(), [effect()]}
  def connection_closed(%State{} = s, conn, reason, at) do
    case Map.pop(s.connections, conn) do
      {nil, _} ->
        {s, [{:unknown_connection, conn}]}

      {connection, connections} ->
        s = %{s | connections: connections}

        info = %{
          conn: conn,
          peer: connection.peer,
          instance: connection.instance_id,
          reason: reason,
          at: at
        }

        case connection.instance_id do
          nil ->
            record = %{
              peer: connection.peer,
              opened_at: connection.opened_at,
              closed_at: at,
              close_reason: reason
            }

            unidentified = Enum.take([record | s.unidentified], s.max_unidentified)
            {%{s | unidentified: unidentified}, [{:closed, Map.put(info, :playing_attempt, nil)}]}

          id ->
            instance = Lifecycle.connection_closed(s.instances[id], at, reason)
            playing = Lifecycle.current_attempt(instance)
            playing_number = playing && playing.number

            {put_in(s.instances[id], instance),
             [{:closed, Map.put(info, :playing_attempt, playing_number)}]}
        end
    end
  end

  # Attributes the connection to the instance on its first valid envelope. A connection that was
  # never announced (nil) is treated as opened at identification time, as before.
  defp identify(s, nil, _id, instance, _at), do: {s, instance, []}

  defp identify(s, conn, id, instance, at) do
    case s.connections[conn] do
      nil ->
        {s, instance, [{:unknown_connection, conn}]}

      %{instance_id: ^id} ->
        {s, instance, []}

      %{instance_id: nil} = connection ->
        instance =
          Lifecycle.connection_identified(instance, connection.peer, connection.opened_at, at)

        info = %{conn: conn, peer: connection.peer, instance: id, previous_instance: nil, at: at}

        {put_in(s.connections[conn], %{connection | instance_id: id}), instance,
         [{:identified, info}]}

      %{instance_id: other} = connection ->
        # The same socket switched instance ids: not something the native adapter does, but it is
        # evidence, so it is recorded as a new attribution rather than dropped.
        instance =
          Lifecycle.connection_identified(instance, connection.peer, connection.opened_at, at)

        info = %{
          conn: conn,
          peer: connection.peer,
          instance: id,
          previous_instance: other,
          at: at
        }

        {put_in(s.connections[conn], %{connection | instance_id: id}), instance,
         [{:reattributed, info}]}
    end
  end
end
