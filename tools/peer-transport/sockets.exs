# M7-L3 — ONE observation of this BEAM's own TCP sockets (operator measurement, not a monitor; README.md "Socket observation").
# Loaded with Code.require_file by peer.exs and game-peer.exs AFTER the bundle check, and by the M7-L3 run console.
#
# It replaces M7-L1's PeerKit.listeners(), which counted every TCP port without a peer as a listener: a client socket that is
# still connecting has no peer either, so M7-L2's connector record listed its own outbound socket (M7L2 record section 13).
# Here no-peer / :enotconn means nothing. Each socket is classified by its explicit state:
#   - the VM's view (always): every tcp_inet port of this VM, its inet-driver state (:inet.info/1 "states": listen | connecting |
#     connected | closed), its local and remote address, and the Erlang process that owns it (registered name or initial call);
#   - the kernel's view of this OS process (when available): Linux `ss -tanpH`, lines owned by this pid only; macOS
#     `lsof -nP -a -p <pid> -iTCP -F pnT` (field output). The macOS branch is parsed by the same code, but it was NOT executed
#     on a Mac in M7-L3's preparation: the Mac operator's second-terminal lsof stays the runtime check there.
# The two views are two queries, taken back to back, each with its own time; they are reported side by side, never merged into
# one "atomic" result. The verdict:
#   observed     the VM listing is complete, every entry classified, and the kernel listing (when available) has exactly the same
#                listening set;
#   ambiguous    complete, but an entry is unclassified or has no address, or the kernel's listening set differs;
#   unavailable  the VM listing failed (the port enumeration, or a live port's state query): never an empty successful result.
# A socket that closes between the enumeration and its query is counted (closed_during_observation), not classified. Only
# public socket facts are recorded: addresses, states and process names, never options or data.
defmodule PeerKit.Sockets do
  @moduledoc false
  @schema "glacier-relay.peer-socket-observation/1"

  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # opts (test seams only): :ports (fn -> ports), :info (fn port -> :inet.info map), :kernel (fn os_pid -> kernel map)
  def observe(opts \\ []) do
    os_pid = System.pid()
    vm = vm(Keyword.get(opts, :ports, &:erlang.ports/0), Keyword.get(opts, :info, &:inet.info/1))
    kernel = safe(fn -> Keyword.get(opts, :kernel, &kernel/1).(os_pid) end)
    kernel = case kernel, do: ({:ok, k} -> k; {:error, why} -> %{"available" => false, "error" => why})
    %{"schema" => @schema, "os_pid" => os_pid, "vm" => vm, "kernel" => kernel} |> Map.merge(verdict(vm, kernel))
  end

  # ---- the VM's view ------------------------------------------------------------------------------------------------------------
  defp vm(ports_fun, info_fun) do
    t = now()
    base = %{"method" => "inet_info_states", "utc" => t}

    case safe(ports_fun) do
      {:ok, ports} when is_list(ports) ->
        es = Enum.map(ports, &entry(&1, info_fun)) |> Enum.reject(&(&1 == :not_tcp))
        errors = for {:error, e} <- es, do: e
        pick = fn k -> for({^k, e} <- es, do: e) |> Enum.sort_by(&{&1["local"], &1["remote"]}) end

        Map.merge(base, %{
          "complete" => errors == [],
          "listening" => pick.(:listening),
          "connecting" => pick.(:connecting),
          "connected" => pick.(:connected),
          "unclassified" => pick.(:unclassified),
          "closed_during_observation" => Enum.count(es, &(&1 == :closed)),
          "errors" => errors
        })

      {:ok, other} ->
        Map.merge(base, %{"complete" => false, "errors" => ["the port enumeration returned #{inspect(other, limit: 5)}"]})

      {:error, why} ->
        Map.merge(base, %{"complete" => false, "errors" => ["the port enumeration failed: #{why}"]})
    end
  end

  defp entry(p, info_fun) do
    case safe(fn -> Port.info(p, :name) end) do
      {:ok, {:name, ~c"tcp_inet"}} -> classify(p, info_fun)
      # gone before its name could be read: its kind is unknown, so it is neither counted nor classified
      {:ok, nil} -> :not_tcp
      {:ok, _} -> :not_tcp
      {:error, _} -> :not_tcp
    end
  end

  defp classify(p, info_fun) do
    case safe(fn -> info_fun.(p) end) do
      {:ok, %{states: states}} when is_list(states) ->
        e = %{"local" => addr(:inet.sockname(p)), "remote" => addr(:inet.peername(p)), "states" => Enum.map(states, &to_string/1), "owner" => owner(p)}

        cond do
          :closed in states -> :closed
          :listen in states -> {:listening, e}
          :connecting in states -> {:connecting, e}
          :connected in states -> {:connected, e}
          true -> {:unclassified, e}
        end

      {:ok, other} ->
        if gone?(p), do: :closed, else: {:error, "inet.info returned #{inspect(other, limit: 5)} for #{inspect(p)}"}

      {:error, why} ->
        if gone?(p), do: :closed, else: {:error, "the state query of #{inspect(p)} failed: #{why}"}
    end
  end

  defp gone?(p), do: Port.info(p) == nil

  defp addr({:ok, {ip, port}}) when is_tuple(ip), do: "#{:inet.ntoa(ip)}:#{port}"
  defp addr(_), do: nil

  defp owner(p) do
    with {:connected, pid} <- Port.info(p, :connected),
         info when is_list(info) <- Process.info(pid, [:registered_name, :dictionary]) do
      case info[:registered_name] do
        name when is_atom(name) and name not in [nil, []] -> inspect(name)
        _ -> case info[:dictionary][:"$initial_call"], do: ({m, f, a} -> "#{inspect(m)}.#{f}/#{a}"; _ -> inspect(pid))
      end
    else
      _ -> nil
    end
  end

  # ---- the kernel's view of this OS process ---------------------------------------------------------------------------------
  def kernel(os_pid) do
    case :os.type() do
      {:unix, :linux} -> run("ss", ["-tanpH"], &parse_ss(&1, os_pid))
      {:unix, :darwin} -> run("lsof", ["-nP", "-a", "-p", os_pid, "-iTCP", "-F", "pnT"], &parse_lsof(&1, os_pid))
      other -> %{"available" => false, "error" => "no kernel listing for #{inspect(other)}"}
    end
  end

  defp run(exe, args, parse) do
    t = now()

    case System.find_executable(exe) || Enum.find(["/usr/sbin/#{exe}", "/usr/bin/#{exe}", "/sbin/#{exe}"], &File.exists?/1) do
      nil ->
        %{"available" => false, "method" => exe, "utc" => t, "error" => "#{exe} not found"}

      path ->
        {out, rc} = System.cmd(path, args, stderr_to_stdout: true)
        m = %{"method" => Enum.join([exe | args], " "), "utc" => t}

        cond do
          rc == 0 -> Map.merge(m, Map.put(parse.(out), "available", true))
          # lsof exits 1 when its selection matched nothing (a process with no TCP socket): complete, and empty
          exe == "lsof" and rc == 1 and String.trim(out) == "" -> Map.merge(m, %{"available" => true, "listening" => [], "other" => [], "note" => "lsof exit 1, empty: no TCP socket listed"})
          true -> Map.merge(m, %{"available" => false, "error" => "#{exe} exit #{rc}: #{String.slice(out, 0, 200)}"})
        end
    end
  end

  # ss -tanpH: State Recv-Q Send-Q Local Peer [users:(("beam.smp",pid=N,fd=M))]; only this process's lines
  def parse_ss(out, os_pid) do
    rows =
      for l <- String.split(out, "\n", trim: true), String.contains?(l, "pid=#{os_pid},"),
          [state, _rq, _sq, local, peer | _] <- [String.split(l)], do: %{"state" => state, "local" => local, "remote" => peer}

    %{"listening" => rows |> Enum.filter(&(&1["state"] == "LISTEN")) |> Enum.map(& &1["local"]) |> Enum.sort(),
      "other" => rows |> Enum.reject(&(&1["state"] == "LISTEN")) |> Enum.sort_by(&{&1["local"], &1["remote"]})}
  end

  # lsof -F pnT: "p<pid>", then per file "f<fd>", "n<name>" (local, or local->remote), "TST=<state>" (and other T fields)
  def parse_lsof(out, os_pid) do
    {rows, cur, pid} =
      Enum.reduce(String.split(out, "\n", trim: true), {[], nil, nil}, fn l, {rows, cur, pid} ->
        case l do
          "p" <> p -> {flush(rows, cur), nil, p}
          "f" <> _ -> {flush(rows, cur), %{}, pid}
          "n" <> n -> {rows, Map.put(cur || %{}, "name", n), pid}
          "TST=" <> st -> {rows, Map.put(cur || %{}, "state", st), pid}
          _ -> {rows, cur, pid}
        end
      end)

    rows = flush(rows, cur) |> Enum.reverse()
    rows = if pid == nil or pid == os_pid, do: rows, else: []

    rows =
      for r <- rows do
        case String.split(r["name"] || "", "->", parts: 2) do
          [l, rem] -> %{"state" => r["state"], "local" => l, "remote" => rem}
          [l] -> %{"state" => r["state"], "local" => l, "remote" => nil}
        end
      end

    %{"listening" => rows |> Enum.filter(&(&1["state"] == "LISTEN")) |> Enum.map(& &1["local"]) |> Enum.sort(),
      "other" => rows |> Enum.reject(&(&1["state"] == "LISTEN")) |> Enum.sort_by(&{&1["local"], &1["remote"] || ""}),
      "pid_field" => pid}
  end

  defp flush(rows, nil), do: rows
  defp flush(rows, cur), do: [cur | rows]

  # ---- the verdict ------------------------------------------------------------------------------------------------------------
  defp verdict(vm, kernel) do
    listening = Enum.map(vm["listening"] || [], & &1["local"]) |> Enum.sort()
    k_available = kernel["available"] == true
    k_agrees = if k_available, do: Enum.sort(kernel["listening"] || []) == listening, else: nil
    unaddressed = Enum.any?(vm["listening"] || [], &(&1["local"] == nil))

    status =
      cond do
        vm["complete"] != true -> "unavailable"
        (vm["unclassified"] || []) != [] or unaddressed or k_agrees == false -> "ambiguous"
        true -> "observed"
      end

    %{"status" => status, "listening" => listening, "kernel_agrees" => k_agrees}
  end

  # the consumers' two questions; anything but an "observed" result answers false (never "none" from a failed query)
  def no_listener?(obs), do: obs["status"] == "observed" and obs["listening"] == []
  def only_listener?(obs, address), do: obs["status"] == "observed" and obs["listening"] == [address]

  def describe(obs) do
    vm = obs["vm"]
    k = obs["kernel"]
    short = fn l -> Enum.map(l || [], &"#{&1["local"]}#{if &1["remote"], do: "->" <> &1["remote"], else: ""}#{if &1["owner"], do: " (" <> &1["owner"] <> ")", else: ""}") end

    "socket observation #{obs["status"]}: listening #{inspect(obs["listening"])}; connecting #{inspect(short.(vm["connecting"]))}; " <>
      "connected #{inspect(short.(vm["connected"]))}; unclassified #{length(vm["unclassified"] || [])}; closed during observation " <>
      "#{vm["closed_during_observation"] || 0}; vm #{vm["utc"]}#{if vm["errors"] not in [nil, []], do: " errors " <> inspect(vm["errors"]), else: ""}; " <>
      "kernel #{if k["available"], do: "#{k["method"]} #{k["utc"]} listening #{inspect(k["listening"])} agrees #{obs["kernel_agrees"]}", else: "unavailable (#{k["error"]})"}"
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, Exception.message(e) |> String.slice(0, 200)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason, limit: 5) |> String.slice(0, 200)}"}
  end
end
