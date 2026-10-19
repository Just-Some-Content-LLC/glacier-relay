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
    GlacierRelay.Command,
    GlacierRelay.Command.Authority,
    GlacierRelay.Command.Link,
    GlacierRelay.Command.Listener,
    GlacierRelay.Command.Journal,
    GlacierRelay.Command.Schema,
    GlacierRelay.Command.Supervisor,
    GlacierRelay.Command.Reversal,
    GlacierRelay.Command.Correlation,
    GlacierRelay.Command.MotionControl,
    # M7-B1: the motion and peer paths and the headless peer
    GlacierRelay.Motion,
    GlacierRelay.Motion.Hub,
    GlacierRelay.Motion.Link,
    GlacierRelay.Motion.Listener,
    GlacierRelay.Motion.Supervisor,
    GlacierRelay.Motion.Destination,
    GlacierRelay.Motion.Source,
    GlacierRelay.Motion.Trace,
    GlacierRelay.Motion.Codec,
    GlacierRelay.Peer.Endpoint,
    GlacierRelay.Peer.Connection,
    GlacierRelay.Peer.Codec,
    GlacierRelay.Peer.TLS,
    GlacierRelay.HeadlessPeer,
    GlacierRelay.HeadlessPeer.Driver,
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
    Command. 4749 Wire. gen_tcp :socket :inet Lifecycle apply_event MissionSession.handle_event connection_opened
    connection_closed GenServer. send( Process.send ZString ZRepositoryID ZDynamicObject
    ZHMModSDK Mods/ Glacier/ TelemetryIntake RelayAdapter TcpRelaySink
  )

  @dashboard_tokens ~w(
    Command. 4749 gen_tcp :socket :inet apply_event connection_identified MissionSession.handle_event connection_opened
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

  # M5-A (ADR 0009): the observer path never references the command path, and the command path
  # never reaches the session's evidence delivery or the wire.
  @observer_prefixes ~w(
    Elixir.GlacierRelay.Wire Elixir.GlacierRelay.MissionSession Elixir.GlacierRelay.Session
    Elixir.GlacierRelay.Lifecycle Elixir.GlacierRelay.Recording Elixir.GlacierRelay.Statistics
    Elixir.GlacierRelay.Summary Elixir.GlacierRelay.Report Elixir.GlacierRelay.Dashboard
    Elixir.GlacierRelayWeb Elixir.GlacierRelay.Test.FixturePlayer Elixir.GlacierRelay.Test.RecordingFixtures
    Elixir.GlacierRelay.Test.StubWriter Elixir.GlacierRelay.Test.RenderingChecks Elixir.GlacierRelay.Application
  )

  test "no observer, web, recording, replay, fixture or test-support module calls the command path" do
    {:ok, modules} = :application.get_key(:glacier_relay, :modules)

    observers =
      Enum.filter(modules, fn m ->
        Enum.any?(@observer_prefixes, &String.starts_with?(Atom.to_string(m), &1))
      end)

    assert GlacierRelay.Recording.Replay in observers and
             GlacierRelay.Test.FixturePlayer in observers

    for module <- observers, {m, f, a} <- remote_calls(module) do
      refute String.starts_with?(Atom.to_string(m), "Elixir.GlacierRelay.Command"),
             "#{inspect(module)} calls #{inspect(m)}.#{f}/#{a}"
    end

    for path <-
          Path.wildcard("lib/glacier_relay/{wire,session,recording,dashboard}/**/*.ex") ++
            [
              "lib/glacier_relay/mission_session.ex",
              "lib/glacier_relay/lifecycle.ex",
              "lib/glacier_relay/statistics.ex"
            ] do
      refute File.read!(path) =~ "Command.", "#{path} mentions the command path"
    end
  end

  # M7-B1 (ADR 0010 as amended, decision 6): the observer path never references the motion or peer
  # paths, which never deliver evidence; the peer link and the headless peer never reach the
  # command path or the engine-writing path; the hub only journals through the authority.
  @motion_prefixes ~w(Elixir.GlacierRelay.Motion Elixir.GlacierRelay.Peer Elixir.GlacierRelay.HeadlessPeer)

  defp prefixed(module, prefixes),
    do: Enum.any?(prefixes, &String.starts_with?(Atom.to_string(module), &1))

  test "no observer, web, recording, replay, fixture or test-support module calls the motion or peer path" do
    {:ok, modules} = :application.get_key(:glacier_relay, :modules)
    observers = Enum.filter(modules, &prefixed(&1, @observer_prefixes))

    for module <- observers, {m, f, a} <- remote_calls(module) do
      refute prefixed(m, @motion_prefixes), "#{inspect(module)} calls #{inspect(m)}.#{f}/#{a}"
    end

    for path <-
          Path.wildcard("lib/glacier_relay/{wire,session,recording,dashboard}/**/*.ex") ++
            Path.wildcard("lib/glacier_relay_web/**/*.ex") ++
            [
              "lib/glacier_relay/mission_session.ex",
              "lib/glacier_relay/lifecycle.ex",
              "lib/glacier_relay/statistics.ex",
              "lib/glacier_relay/application.ex"
            ],
        token <- ["Motion.", "Peer.", "HeadlessPeer", "4750", "4760"] do
      refute File.read!(path) =~ token, "#{path} mentions #{inspect(token)}"
    end
  end

  test "the motion and peer paths never deliver evidence, fold, record or touch the telemetry wire" do
    {:ok, modules} = :application.get_key(:glacier_relay, :modules)
    motion = Enum.filter(modules, &prefixed(&1, @motion_prefixes))
    assert GlacierRelay.Motion.Hub in motion and GlacierRelay.HeadlessPeer.Driver in motion

    for module <- motion, {m, f, a} <- remote_calls(module) do
      refute m in [
               GlacierRelay.MissionSession,
               GlacierRelay.Lifecycle,
               GlacierRelay.Session.Fold,
               GlacierRelay.Recording.Recorder,
               GlacierRelay.Recording.Writer,
               GlacierRelay.Wire.Listener,
               GlacierRelay.Wire.Connection,
               GlacierRelay.Wire.Envelope,
               GlacierRelay.Events
             ],
             "#{inspect(module)} calls #{inspect(m)}.#{f}/#{a}"
    end
  end

  test "the peer link and the headless peer reach neither the command path nor the engine-writing path" do
    {:ok, modules} = :application.get_key(:glacier_relay, :modules)

    peer_or_headless =
      Enum.filter(
        modules,
        &prefixed(&1, ~w(Elixir.GlacierRelay.Peer Elixir.GlacierRelay.HeadlessPeer))
      )

    assert GlacierRelay.Peer.Connection in peer_or_headless

    for module <- peer_or_headless, {m, f, a} <- remote_calls(module) do
      refute String.starts_with?(Atom.to_string(m), "Elixir.GlacierRelay.Command") and
               m not in [GlacierRelay.Command.Schema, GlacierRelay.Command.TransformWords],
             "#{inspect(module)} calls #{inspect(m)}.#{f}/#{a}"

      refute m in [
               GlacierRelay.Motion,
               GlacierRelay.Motion.Hub,
               GlacierRelay.Motion.Link,
               GlacierRelay.Motion.Listener,
               GlacierRelay.Motion.Supervisor,
               GlacierRelay.Motion.Destination
             ],
             "#{inspect(module)} calls #{inspect(m)}.#{f}/#{a}"

      refute m == :gen_tcp and f == :send, "#{inspect(module)} writes a raw TCP socket"
    end
  end

  test "the motion hub talks to the authority only to journal; it never issues, arms or opens" do
    hub_to_authority =
      for {GlacierRelay.Command.Authority, f, a} <- remote_calls(GlacierRelay.Motion.Hub),
          do: {f, a}

    assert Enum.uniq(hub_to_authority) == [motion_event: 1]

    for pure <- [
          GlacierRelay.Motion.Destination,
          GlacierRelay.Motion.Source,
          GlacierRelay.Motion.Course,
          GlacierRelay.Motion.Codec,
          GlacierRelay.Motion.LineCodec,
          GlacierRelay.Peer.Codec,
          GlacierRelay.Command.MotionControl
        ],
        {m, f, a} <- remote_calls(pure) do
      refute m in [:gen_tcp, :ssl, :inet, :socket, GenServer, GlacierRelay.Command.Authority],
             "#{inspect(pure)} (pure) calls #{inspect(m)}.#{f}/#{a}"
    end
  end

  test "the command path never delivers evidence, folds, touches the recorder or the telemetry wire" do
    commands = modules("Elixir.GlacierRelay.Command")
    assert GlacierRelay.Command.Authority in commands

    for module <- commands, {m, f, a} <- remote_calls(module) do
      refute m in [
               GlacierRelay.MissionSession,
               GlacierRelay.Lifecycle,
               GlacierRelay.Session.Fold,
               GlacierRelay.Recording.Recorder,
               GlacierRelay.Wire.Listener,
               GlacierRelay.Wire.Connection,
               GlacierRelay.Wire.Envelope,
               GlacierRelay.Events
             ],
             "#{inspect(module)} calls #{inspect(m)}.#{f}/#{a}"
    end

    # No Phoenix route for commands or arming.
    routes = GlacierRelayWeb.Router.__routes__() |> Enum.map(& &1.path)
    refute Enum.any?(routes, &(&1 =~ ~r/command|arm|probe/)), inspect(routes)
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
