defmodule GlacierRelayWeb.BoundaryTest do
  @moduledoc """
  M3-A read-only boundary (ADR 0007): the web namespace reads OTP-owned presentations and
  nothing else. Proven two ways: from the compiled modules' remote-call tables (what the code
  actually calls, as the compiler emitted it) and from the source text (what it mentions).
  """
  use ExUnit.Case, async: true

  @web_dir "lib/glacier_relay_web"

  # Modules the web namespace may never call.
  @forbidden_modules [
    GlacierRelay.Wire.Listener,
    GlacierRelay.Wire.Connection,
    GlacierRelay.Wire.Framing,
    GlacierRelay.Wire.Envelope,
    GlacierRelay.Lifecycle,
    GlacierRelay.Events,
    :gen_tcp,
    :socket,
    :inet,
    :ssl
  ]

  # The only MissionSession functions the web namespace may call (read-only presentations).
  @allowed_session_calls [{:report_text, 0}, {:summary_text, 0}]

  # Source tokens that must not appear: wire and socket access, evidence delivery, process
  # messaging toward the session, the pure model, and native SDK types or paths.
  @forbidden_tokens ~w(
    Wire. gen_tcp :socket :inet Lifecycle apply_event handle_event connection_opened
    connection_closed GenServer. send( Process.send ZString ZRepositoryID ZDynamicObject
    ZHMModSDK Mods/ Glacier/ TelemetryIntake RelayAdapter TcpRelaySink
  )

  defp web_modules do
    {:ok, modules} = :application.get_key(:glacier_relay, :modules)
    Enum.filter(modules, &String.starts_with?(Atom.to_string(&1), "Elixir.GlacierRelayWeb"))
  end

  defp remote_calls(module) do
    path = :code.which(module)
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(path, [:imports])
    imports
  end

  test "the web namespace exists and is compiled" do
    modules = web_modules()
    assert GlacierRelayWeb.Endpoint in modules
    assert GlacierRelayWeb.Router in modules
    assert GlacierRelayWeb.TextController in modules
    assert GlacierRelayWeb.Supervisor in modules
  end

  test "no compiled web module calls the wire, sockets, the pure model or evidence delivery" do
    for module <- web_modules(), {m, f, a} <- remote_calls(module) do
      refute m in @forbidden_modules, "#{inspect(module)} calls #{inspect(m)}.#{f}/#{a}"

      if m == GlacierRelay.MissionSession do
        assert {f, a} in @allowed_session_calls,
               "#{inspect(module)} calls MissionSession.#{f}/#{a}, which is not a read-only presentation"
      end

      refute {m, f} == {GenServer, :cast}, "#{inspect(module)} casts"
      refute {m, f} == {GenServer, :call}, "#{inspect(module)} calls a GenServer directly"
    end
  end

  test "only the text controller reaches MissionSession, and only for the two presentations" do
    callers =
      for module <- web_modules(),
          {GlacierRelay.MissionSession, f, a} <- remote_calls(module),
          do: {module, f, a}

    assert Enum.sort(callers) == [
             {GlacierRelayWeb.TextController, :report_text, 0},
             {GlacierRelayWeb.TextController, :summary_text, 0}
           ]
  end

  test "the web sources mention no wire, socket, model, evidence-delivery or native SDK token" do
    sources = Path.wildcard("#{@web_dir}/**/*.ex")
    assert sources != []

    for path <- sources, token <- @forbidden_tokens do
      refute File.read!(path) =~ token, "#{path} mentions #{inspect(token)}"
    end
  end

  test "the evidence-delivery functions are the session's, never exported by the web" do
    for module <- web_modules(),
        {f, a} <- module.__info__(:functions),
        {f, a} in [{:handle_event, 2}, {:connection_opened, 2}, {:connection_closed, 2}] do
      flunk("#{inspect(module)} exports #{f}/#{a}")
    end
  end
end
