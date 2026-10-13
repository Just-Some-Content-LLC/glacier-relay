defmodule GlacierRelayWeb.BoundaryTest do
  @moduledoc """
  Read-only boundary (ADR 0007): the web namespace and the dashboard projection read OTP-owned
  presentations and nothing else. Proven from the compiled modules' remote-call tables (what the
  code actually calls, as the compiler emitted it), from the exported functions, and from the
  source text (what it mentions). The behavioural half (HTTP and LiveView events that leave the
  session untouched) lives in endpoint_test.exs and dashboard_live_test.exs.
  """
  use ExUnit.Case, async: true

  # Modules that may never be called from the web or the projection.
  @forbidden_modules [
    GlacierRelay.Wire.Listener,
    GlacierRelay.Wire.Connection,
    GlacierRelay.Wire.Framing,
    GlacierRelay.Wire.Envelope,
    GlacierRelay.Events,
    GlacierRelay.Recording.Recorder,
    GlacierRelay.Recording.Segment,
    GlacierRelay.Recording.Codec,
    :gen_tcp,
    :socket,
    :inet,
    :ssl
  ]

  # Lifecycle functions that fold or rewrite evidence; the projection may only read.
  @forbidden_lifecycle [:apply_event, :connection_identified, :connection_closed, :new]

  # The session's evidence-delivery and subscription functions.
  @delivery [{:handle_event, 2}, {:connection_opened, 2}, {:connection_closed, 2}]

  @allowed_session_calls %{
    GlacierRelayWeb.TextController => [{:report_text, 0}, {:summary_text, 0}],
    GlacierRelay.Dashboard.Projection => [{:subscribe, 0}, {:state, 0}, {:unidentified, 0}]
  }

  @web_tokens ~w(
    Wire. gen_tcp :socket :inet Lifecycle apply_event MissionSession.handle_event connection_opened
    connection_closed GenServer. send( Process.send ZString ZRepositoryID ZDynamicObject
    ZHMModSDK Mods/ Glacier/ TelemetryIntake RelayAdapter TcpRelaySink
  )

  @dashboard_tokens ~w(
    gen_tcp :socket :inet apply_event connection_identified MissionSession.handle_event connection_opened
    connection_closed GenServer.cast send( Process.send( ZString ZRepositoryID ZDynamicObject
    ZHMModSDK Mods/ Glacier/ TelemetryIntake RelayAdapter TcpRelaySink
  )

  defp modules(prefix) do
    {:ok, modules} = :application.get_key(:glacier_relay, :modules)
    Enum.filter(modules, &String.starts_with?(Atom.to_string(&1), prefix))
  end

  defp web_modules, do: modules("Elixir.GlacierRelayWeb")
  defp dashboard_modules, do: modules("Elixir.GlacierRelay.Dashboard")

  defp remote_calls(module) do
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
    imports
  end

  test "the web and dashboard namespaces exist and are compiled" do
    assert GlacierRelayWeb.Endpoint in web_modules()
    assert GlacierRelayWeb.Router in web_modules()
    assert GlacierRelayWeb.TextController in web_modules()
    assert GlacierRelayWeb.DashboardLive in web_modules()
    assert GlacierRelayWeb.ReportLive in web_modules()
    assert GlacierRelay.Dashboard.Projection in dashboard_modules()
  end

  test "no compiled web or dashboard module calls the wire, sockets, validation, evidence folding or delivery" do
    for module <- web_modules() ++ dashboard_modules(), {m, f, a} <- remote_calls(module) do
      refute m in @forbidden_modules, "#{inspect(module)} calls #{inspect(m)}.#{f}/#{a}"

      if m == GlacierRelay.Lifecycle,
        do: refute(f in @forbidden_lifecycle, "#{inspect(module)} calls Lifecycle.#{f}/#{a}")

      if m == GlacierRelay.MissionSession do
        allowed = Map.get(@allowed_session_calls, module, [])
        assert {f, a} in allowed, "#{inspect(module)} calls MissionSession.#{f}/#{a}"
      end

      refute {m, f} == {GenServer, :cast}, "#{inspect(module)} casts"
    end
  end

  test "LiveViews and components never reach the session at all; the projection is the reader" do
    for module <- web_modules(), module != GlacierRelayWeb.TextController do
      session_calls = for {GlacierRelay.MissionSession, f, a} <- remote_calls(module), do: {f, a}

      assert session_calls == [],
             "#{inspect(module)} calls MissionSession: #{inspect(session_calls)}"
    end

    projection_calls =
      for {GlacierRelay.MissionSession, f, a} <- remote_calls(GlacierRelay.Dashboard.Projection),
          do: {f, a}

    assert Enum.sort(Enum.uniq(projection_calls)) == [
             {:state, 0},
             {:subscribe, 0},
             {:unidentified, 0}
           ]

    refute Enum.any?(projection_calls, &(&1 in @delivery))
  end

  test "only GenServer.call reaches the session, and only through its public read API" do
    for module <- web_modules() ++ dashboard_modules(),
        {GenServer, f, _} <- remote_calls(module) do
      refute f in [:cast, :abcast, :multi_call], "#{inspect(module)} uses GenServer.#{f}"
    end
  end

  test "the sources mention no wire, socket, folding, delivery or native SDK token" do
    web = Path.wildcard("lib/glacier_relay_web/**/*.ex")
    dashboard = Path.wildcard("lib/glacier_relay/dashboard/**/*.ex")
    assert web != [] and dashboard != []

    for path <- web, token <- @web_tokens do
      refute File.read!(path) =~ token, "#{path} mentions #{inspect(token)}"
    end

    for path <- dashboard, token <- @dashboard_tokens do
      refute File.read!(path) =~ token, "#{path} mentions #{inspect(token)}"
    end
  end

  test "no web or dashboard module exports an evidence-delivery function" do
    for module <- web_modules() ++ dashboard_modules(),
        {f, a} <- module.__info__(:functions),
        {f, a} in @delivery do
      flunk("#{inspect(module)} exports #{f}/#{a}")
    end
  end

  test "the LiveViews handle only the viewer-choice events" do
    assert GlacierRelayWeb.DashboardLive.__info__(:functions) |> Keyword.has_key?(:handle_event)
    source = File.read!("lib/glacier_relay_web/live/dashboard_live.ex")

    events =
      Regex.scan(~r/handle_event\("([a-z_]+)"/, source)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.sort()

    assert events == ~w(clear_events focus select_attempt select_pane toggle)

    source = File.read!("lib/glacier_relay_web/live/report_live.ex")
    events = Regex.scan(~r/handle_event\("([a-z_]+)"/, source) |> Enum.map(&Enum.at(&1, 1))
    assert events == ["toggle"]
  end
end
