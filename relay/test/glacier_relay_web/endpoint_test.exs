defmodule GlacierRelayWeb.EndpointTest do
  @moduledoc """
  M3-A web-enabled behaviour, over real HTTP against the real application: the endpoint binds to
  loopback only, the two GET diagnostics serve exactly the existing report and summary text, every
  other method or path is refused without touching the session's evidence, a fixture replayed
  through the wire listener is reflected by the routes, and a web failure never restarts the
  ingestion processes.

  HTTP is spoken over a raw socket (HTTP/1.1, `Connection: close`) so the test depends on nothing
  but the endpoint itself.
  """
  # Not async: starts the shared web subtree and feeds the shared MissionSession.
  use ExUnit.Case, async: false

  alias GlacierRelay.MissionSession
  alias GlacierRelay.Wire.Listener
  alias GlacierRelayWeb.Endpoint

  @fixture File.read!("test/b6_run1_envelopes.ndjson") |> String.split("\n", trim: true)
  @b6_instance "6e1b19b6-e265-4016-aa2a-d9a68ab08c9a"

  setup do
    start_supervised!(GlacierRelayWeb.Supervisor)
    {:ok, {ip, port}} = Endpoint.server_info(:http)
    :ok = MissionSession.subscribe()
    %{ip: ip, port: port}
  end

  # -- a minimal HTTP/1.1 client ---------------------------------------------------------------

  defp request(method, port, path, body \\ nil) do
    verb = method |> Atom.to_string() |> String.upcase()

    head =
      "#{verb} #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nConnection: close\r\n" <>
        if(body,
          do: "Content-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n",
          else: ""
        )

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    :ok = :gen_tcp.send(socket, head <> "\r\n" <> (body || ""))
    raw = recv_all(socket, "")
    :gen_tcp.close(socket)

    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    [_, status | _] = String.split(status_line, " ")

    headers =
      for line <- header_lines, [k, v] = String.split(line, ":", parts: 2) do
        {String.downcase(k), String.trim(v)}
      end

    {String.to_integer(status), headers, body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, bytes} -> recv_all(socket, acc <> bytes)
      {:error, :closed} -> acc
    end
  end

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp replay_fixture do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, Listener.port(), [:binary, active: false])
    :ok = :gen_tcp.send(socket, Enum.join(@fixture, "\n") <> "\n")
    assert_receive {:relay_event, %{sequence: 16, adapter_instance_id: @b6_instance}}, 2_000
    :gen_tcp.close(socket)
    assert_receive {:relay_connection, :closed, %{instance_id: @b6_instance}}, 2_000
  end

  defp web_child(id_filter) do
    GlacierRelayWeb.Supervisor
    |> Supervisor.which_children()
    |> Enum.find(fn {id, _, _, _} -> id_filter.(id) end)
    |> elem(1)
  end

  # -- bind -----------------------------------------------------------------------------------

  test "binds to 127.0.0.1 only, on a port distinct from the wire listener", %{ip: ip, port: port} do
    assert ip == {127, 0, 0, 1}
    assert port > 0
    assert {{127, 0, 0, 1}, wire_port} = Listener.address()
    assert port != wire_port

    # The endpoint configuration itself names loopback, in every environment.
    assert Application.get_env(:glacier_relay, GlacierRelayWeb.Endpoint)[:http][:ip] ==
             {127, 0, 0, 1}

    # The same port is not reachable on any non-loopback IPv4 address this host has.
    {:ok, ifaddrs} = :inet.getifaddrs()

    non_loopback =
      for {_name, opts} <- ifaddrs,
          {:addr, {a, b, c, d}} <- opts,
          a != 127,
          do: {a, b, c, d}

    assert non_loopback != [], "no non-loopback interface to prove the negative against"

    for addr <- non_loopback do
      assert {:error, _} = :gen_tcp.connect(addr, port, [:binary], 500),
             "endpoint reachable on #{:inet.ntoa(addr)}"
    end
  end

  # -- the two diagnostics --------------------------------------------------------------------

  test "GET /report.txt serves the existing report text as UTF-8 plain text", %{port: port} do
    {200, headers, body} = request(:get, port, "/report.txt")
    assert header(headers, "content-type") == "text/plain; charset=utf-8"
    assert body == MissionSession.report_text()
  end

  test "GET /summary.txt serves the existing summary text as UTF-8 plain text", %{port: port} do
    {200, headers, body} = request(:get, port, "/summary.txt")
    assert header(headers, "content-type") == "text/plain; charset=utf-8"
    assert body == MissionSession.summary_text()
  end

  test "HEAD is answered as GET without a body", %{port: port} do
    {200, headers, body} = request(:head, port, "/report.txt")
    assert header(headers, "content-type") == "text/plain; charset=utf-8"
    assert body == ""
  end

  test "a fixture replayed through the wire listener is reflected by both routes", %{port: port} do
    replay_fixture()

    {200, _, report} = request(:get, port, "/report.txt")
    assert report == MissionSession.report_text()
    assert report =~ "adapter #{@b6_instance}: 16 event(s), last sequence 16, gaps []"
    assert report =~ "attempt 1: Peacock"
    assert report =~ "disposition: exited to menu"

    {200, _, summary} = request(:get, port, "/summary.txt")
    assert summary == MissionSession.summary_text()
    assert summary =~ @b6_instance
  end

  # -- read-only: nothing else is served, nothing is changed ---------------------------------

  test "every other method on the known paths is 405 and changes nothing", %{port: port} do
    before = MissionSession.state()
    envelope_like = hd(@fixture)

    for path <- ["/report.txt", "/summary.txt", "/", "/report"] do
      for method <- [:post, :put, :patch] do
        {405, headers, _} = request(method, port, path, envelope_like)
        assert header(headers, "allow") == "GET, HEAD"
      end

      {405, _, _} = request(:delete, port, path)
    end

    refute_receive {:relay_event, _}, 200
    assert MissionSession.state() == before
  end

  test "unknown paths are 404 for any method and change nothing", %{port: port} do
    before = MissionSession.state()

    {404, _, "not found"} = request(:get, port, "/nowhere")
    {404, _, "not found"} = request(:get, port, "/report/extra")
    {404, _, "not found"} = request(:get, port, "/nowhere/websocket")
    {404, _, "not found"} = request(:post, port, "/events", hd(@fixture))
    {405, _, "method not allowed"} = request(:post, port, "/", hd(@fixture))
    {405, _, "method not allowed"} = request(:post, port, "/report", hd(@fixture))
    # Plug normalises the trailing slash, so this is the known path and is refused as 405.
    {405, _, "method not allowed"} = request(:post, port, "/report.txt/", hd(@fixture))

    refute_receive {:relay_event, _}, 200
    assert MissionSession.state() == before
  end

  test "the pages and the client assets are served read-only, GET only", %{port: port} do
    {200, headers, body} = request(:get, port, "/")
    assert header(headers, "content-type") =~ "text/html"
    assert body =~ "Glacier Relay"
    assert body =~ ~s(<meta name="csrf-token")
    {200, _, _} = request(:get, port, "/report")
    {200, h1, b1} = request(:get, port, "/assets/phoenix/phoenix.min.js")
    assert header(h1, "content-type") =~ "javascript" and b1 =~ "var Phoenix="
    {200, _, b2} = request(:get, port, "/assets/live_view/phoenix_live_view.min.js")
    assert b2 =~ "var LiveView="
    {200, _, b3} = request(:get, port, "/assets/app.js")
    assert b3 =~ "LiveSocket"
    {200, h4, _} = request(:get, port, "/assets/app.css")
    assert header(h4, "content-type") =~ "text/css"
    {404, _, _} = request(:get, port, "/assets/phoenix/phoenix.js")
    {404, _, _} = request(:get, port, "/assets/../mix.exs")
    # The LiveView socket path without an upgrade is refused, never served.
    {status, _, _} = request(:get, port, "/live/websocket")
    assert status in 400..499
  end

  test "the router exposes the two LiveViews, the two GET diagnostics and the refusing fallback" do
    routes =
      GlacierRelayWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(&{&1.verb, &1.path, &1.plug, &1.plug_opts})
      |> Enum.sort()

    assert routes == [
             {:*, "/*path", GlacierRelayWeb.TextController, :fallback},
             {:get, "/", Phoenix.LiveView.Plug, GlacierRelayWeb.DashboardLive},
             {:get, "/report", Phoenix.LiveView.Plug, GlacierRelayWeb.ReportLive},
             {:get, "/report.txt", GlacierRelayWeb.TextController, :report},
             {:get, "/summary.txt", GlacierRelayWeb.TextController, :summary}
           ]
  end

  # -- failure isolation ----------------------------------------------------------------------

  test "a web failure never restarts the ingestion processes" do
    session = Process.whereis(MissionSession)
    listener = Process.whereis(Listener)
    endpoint = Process.whereis(Endpoint)

    Process.exit(endpoint, :kill)
    wait_until(fn -> endpoint_restarted?(endpoint) end)
    assert Process.whereis(Endpoint) != endpoint

    assert Process.whereis(MissionSession) == session
    assert Process.whereis(Listener) == listener

    # rest_for_one: a crash of the PubSub child restarts the endpoint after it, nothing else.
    pubsub = web_child(&(&1 != GlacierRelayWeb.Endpoint))
    endpoint2 = Process.whereis(Endpoint)
    Process.exit(pubsub, :kill)
    wait_until(fn -> endpoint_restarted?(endpoint2) end)
    assert Process.whereis(Endpoint) != endpoint2

    assert Process.whereis(MissionSession) == session
    assert Process.whereis(Listener) == listener
    assert web_child(&(&1 != GlacierRelayWeb.Endpoint)) != pubsub

    # The routes still answer from the restarted subtree.
    {:ok, {_, port2}} = Endpoint.server_info(:http)
    {200, _, body} = request(:get, port2, "/summary.txt")
    assert body == MissionSession.summary_text()
  end

  test "stopping the web subtree frees its port", %{port: port} do
    :ok = stop_supervised!(GlacierRelayWeb.Supervisor)

    wait_until(fn ->
      match?({:error, :econnrefused}, :gen_tcp.connect({127, 0, 0, 1}, port, [], 200))
    end)

    assert Process.whereis(Endpoint) == nil
    assert is_pid(Process.whereis(MissionSession))
    assert is_pid(Process.whereis(Listener))
  end

  # The endpoint has restarted when a new endpoint supervisor is registered and has started all of
  # its children (the predicate of Dashboard.ProjectionTest, 1f7c2fc): its name is registered
  # before its init/1 runs, and the configuration table `server_info/1` reads is created by its
  # first child, so asking for the listener earlier raises (the table does not exist yet) rather
  # than answering "not yet" — the M7-L1 gate's failure here (an ArgumentError from :ets.lookup);
  # `which_children/1` is answered only once init/1 has returned. After a :kill, the endpoint's
  # first restart attempt can also fail to start its LiveView socket child (`:already_started`:
  # the killed endpoint's still terminating) and the web supervisor starts another: that attempt's
  # `which_children/1` exits and the attempt is gone — not yet; the next one is waited for. A
  # persistent failure is not hidden: an endpoint that never comes back leaves this false until the
  # bounded wait raises, and any other exit, or one from a process that is still running, is not
  # caught.
  defp endpoint_restarted?(old) do
    case Process.whereis(Endpoint) do
      pid when is_pid(pid) and pid != old ->
        try do
          _ = Supervisor.which_children(pid)
          match?({:ok, _}, Endpoint.server_info(:http))
        catch
          :exit, {{:shutdown, {:failed_to_start_child, _, _}}, _} = reason ->
            if Process.alive?(pid), do: exit(reason), else: false
        end

      _ ->
        false
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end
end
