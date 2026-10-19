defmodule GlacierRelay.Test.HeadlessHarness do
  @moduledoc """
  M7-B1 test support: runs the headless peer (`GlacierRelay.HeadlessPeer`) in a **second, ordinary
  BEAM operating-system process** for the two-process tests. The child is not distributed (no
  `--sname` / `--name`: `nonode@nohost`, no epmd contact); it is driven over its standard input
  and answers on its standard output, one JSON object per line prefixed `@@` — an administrative
  channel that is neither the peer link nor Erlang distribution. It loads the already compiled
  test build (`-pa`), compiles nothing, starts only `:ssl` and the headless peer (not the
  `:glacier_relay` application: no wire listener, no command or motion subtree), and halts when
  its standard input closes, so it never outlives its test.

  Parent side: `start_child/2`, `request/3`, `close/2`.
  """

  alias GlacierRelay.HeadlessPeer
  alias GlacierRelay.HeadlessPeer.Driver
  alias GlacierRelay.Motion.{Course, Trace}
  alias GlacierRelay.Peer.{Connection, Endpoint}

  # the harness's own request keys (test input, never wire input), mapped explicitly
  @course_keys Map.new(
                 ~w(distance_m heading_rad hold_ms prefix_ms speed_mps interval_ms a b laps x y c1 c2 loops center radius_m direction),
                 &{&1, String.to_atom(&1)}
               )

  # -- child ------------------------------------------------------------------------------------------

  @doc false
  def main do
    :logger.remove_handler(:default)
    {:ok, _} = Application.ensure_all_started(:ssl)
    cfg = read!()

    {:ok, _sup} =
      HeadlessPeer.start_link(
        ip: {127, 0, 0, 1},
        port: cfg["port"] || 0,
        credentials: Enum.flat_map(cfg["credentials"], &credential/1),
        label: cfg["label"],
        expected: %{label: cfg["expected_label"], client_kind: "game"},
        trace_dir: cfg["trace_dir"],
        sink_bounds: sink_bounds(cfg["sink_bounds"])
      )

    emit(%{
      "event" => "ready",
      "port" => Endpoint.port(HeadlessPeer.endpoint()),
      "node" => to_string(node()),
      "distributed" => Node.alive?(),
      "os_pid" => System.pid(),
      "otp" => System.otp_release()
    })

    loop()
  end

  @credential_keys %{
    "cert_file" => :cert_file,
    "key_file" => :key_file,
    "peer_ca_file" => :peer_ca_file,
    "peer_pin" => :peer_pin
  }

  defp credential({k, v}) do
    case Map.fetch(@credential_keys, k) do
      {:ok, key} -> [{key, v}]
      :error -> []
    end
  end

  defp sink_bounds(nil), do: nil

  defp sink_bounds(b),
    do: %{
      center: List.to_tuple(b["center"]),
      half_extent_m: b["half_extent_m"],
      min_interval_ms: b["min_interval_ms"]
    }

  defp loop do
    case IO.gets("") do
      :eof ->
        System.halt(0)

      {:error, _} ->
        System.halt(0)

      line ->
        req = JSON.decode!(line)
        emit(Map.put(handle(req), "id", req["id"]))
        loop()
    end
  end

  defp handle(%{"op" => "start_course"} = r) do
    origin = {r["origin"] |> Enum.at(0), r["origin"] |> Enum.at(1)}

    opts =
      Enum.flat_map(r["opts"] || %{}, fn {k, v} ->
        case Map.fetch(@course_keys, k) do
          {:ok, key} -> [{key, course_value(k, v)}]
          :error -> []
        end
      end)

    course =
      case r["profile"] do
        "out_and_back" -> Course.out_and_back(origin, opts)
        "shuttle" -> Course.shuttle(origin, opts)
        "rectangle" -> Course.rectangle(origin, opts)
        "figure_eight" -> Course.figure_eight(origin, opts)
        "circle" -> Course.circle(origin, opts)
      end

    case Driver.start_course(course,
           label: r["label"] || "synthetic course (headless peer, two-process test)"
         ) do
      {:ok, id} -> %{"ok" => true, "stream_id" => id, "samples" => length(Course.samples(course))}
      {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
    end
  end

  defp handle(%{"op" => "stop_course"}), do: %{"ok" => Driver.stop_course() == :ok}

  defp handle(%{"op" => "status"}) do
    s = Driver.status()
    %{"ok" => true, "status" => JSON.decode!(JSON.encode!(jsonable(s)))}
  end

  defp handle(%{"op" => "suspend_connection", "ms" => ms}) do
    case Endpoint.status(HeadlessPeer.endpoint()).connection do
      %{pid: pid} ->
        :sys.suspend(pid)
        spawn(fn -> Process.sleep(ms) && :sys.resume(pid) end)
        %{"ok" => true}

      nil ->
        %{"ok" => false, "error" => "no connection"}
    end
  end

  defp handle(%{"op" => "connection"}) do
    case Endpoint.status(HeadlessPeer.endpoint()).connection do
      %{pid: pid} -> %{"ok" => true, "connection" => jsonable(Connection.status(pid))}
      nil -> %{"ok" => false}
    end
  end

  defp handle(%{"op" => "trace"}) do
    :ok = Trace.flush(HeadlessPeer.trace())
    %{"ok" => true, "trace" => jsonable(Trace.status(HeadlessPeer.trace()))}
  end

  defp handle(%{"op" => "quit"}) do
    spawn(fn -> Process.sleep(50) && System.halt(0) end)
    %{"ok" => true}
  end

  defp handle(other), do: %{"ok" => false, "error" => "unknown op #{inspect(other["op"])}"}

  defp course_value(k, v) when k in ["a", "b", "c1", "c2", "center", "x", "y"] and is_list(v),
    do: List.to_tuple(v)

  defp course_value("direction", "reverse"), do: :reverse
  defp course_value("direction", _), do: :forward
  defp course_value(_k, v), do: v

  defp jsonable(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&jsonable/1)

  defp jsonable(m) when is_map(m) and not is_struct(m),
    do: Map.new(m, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(l) when is_list(l), do: Enum.map(l, &jsonable/1)
  defp jsonable(p) when is_pid(p) or is_reference(p) or is_port(p), do: inspect(p)
  defp jsonable(a) when is_atom(a) and a not in [true, false, nil], do: Atom.to_string(a)
  defp jsonable(v), do: v

  defp read! do
    case IO.gets("") do
      line when is_binary(line) -> JSON.decode!(line)
      _ -> System.halt(1)
    end
  end

  defp emit(map), do: IO.write("@@" <> JSON.encode!(map) <> "\n")

  # -- parent -----------------------------------------------------------------------------------------

  @doc """
  Spawns the child with `cfg` (`"credentials"` — file-based `Peer.TLS.credentials/1` options with
  string keys — `"label"`, `"expected_label"`, `"trace_dir"`, `"port"`, `"sink_bounds"`) and waits for
  its `ready` line. Returns `{port, ready}`.
  """
  def start_child(cfg, timeout \\ 20_000) do
    elixir = System.find_executable("elixir") || raise "elixir not found"
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    args =
      Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", "GlacierRelay.Test.HeadlessHarness.main()"]

    port =
      Port.open({:spawn_executable, elixir}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:line, 262_144},
        args: args
      ])

    Port.command(port, JSON.encode!(cfg) <> "\n")
    {:ok, ready} = await(port, fn m -> m["event"] == "ready" end, timeout)
    {port, ready}
  end

  @doc "Sends one request and waits for its answer (matched by id)."
  def request(port, req, timeout \\ 10_000) do
    id = System.unique_integer([:positive])
    Port.command(port, JSON.encode!(Map.put(req, "id", id)) <> "\n")
    await(port, fn m -> m["id"] == id end, timeout)
  end

  @doc "Closes the child's standard input (it halts) and makes sure its OS process is gone."
  def close(port, os_pid) do
    if Port.info(port), do: Port.close(port)

    Enum.reduce_while(1..50, nil, fn _, _ ->
      if alive?(os_pid), do: Process.sleep(100) && {:cont, nil}, else: {:halt, :ok}
    end)

    if alive?(os_pid), do: System.cmd("kill", ["-9", to_string(os_pid)])
    :ok
  end

  def alive?(os_pid), do: File.exists?("/proc/#{os_pid}")

  defp await(port, match, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_loop(port, match, deadline)
  end

  defp await_loop(port, match, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, "@@" <> json}}} ->
        msg = JSON.decode!(json)
        if match.(msg), do: {:ok, msg}, else: await_loop(port, match, deadline)

      {^port, {:data, {_, _other}}} ->
        await_loop(port, match, deadline)

      {^port, {:exit_status, status}} ->
        {:error, {:child_exited, status}}
    after
      left -> {:error, :timeout}
    end
  end
end
