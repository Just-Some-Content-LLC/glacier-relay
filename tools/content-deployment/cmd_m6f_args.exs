# M6-F2a: the argument parsing of cmd-m6f.exs's optional values; M6-F2b preparation: also the other small decisions of cmd-m6f.exs
# that must be testable on their own — the fail-closed stop-marker check (item A). Loaded by cmd-m6f.exs; tested on its own by
# tests/cmd_m6f_args_test.exs (no node, no RPC). Operator tooling, not production code.
#
# The correction it carries (M6-F1b finding, section 13.7): `arm-effectful <owner>` — the documented owner-only form — raised
# client-side before any RPC, because the old code padded the argument list with BOTH defaults and took the second element, which
# for a one-element list was the owner default, not a TTL. Here every documented form supplies the existing default TTL
# (30 000 ms, the same value the empty form always passed — the authority's own effectful_ttl_default_ms) and an explicit TTL
# must be a plain decimal millisecond count. The RANGE stays the authority's to judge (Command.Authority: 1 000..120 000 ms for
# an effectful arming, 100..10 000 ms for a command); nothing here changes or duplicates that policy.
defmodule CmdM6fArgs do
  @moduledoc false

  @owner "HITMAN3.exe"
  @effectful_ttl_ms 30_000
  @lift_ttl_ms 5_000

  def default_owner, do: @owner
  def default_effectful_ttl_ms, do: @effectful_ttl_ms
  def default_lift_ttl_ms, do: @lift_ttl_ms

  @doc "`arm-effectful [expected_exe] [ttl_ms]` -> {:ok, exe, ttl_ms} | {:error, reason}"
  def arm_effectful([]), do: {:ok, @owner, @effectful_ttl_ms}
  def arm_effectful([exe]), do: with(:ok <- exe(exe), do: {:ok, exe, @effectful_ttl_ms})
  def arm_effectful([exe, ttl]), do: with(:ok <- exe(exe), {:ok, t} <- ms(ttl), do: {:ok, exe, t})
  def arm_effectful(more) when is_list(more), do: {:error, {:too_many_arguments, length(more), "arm-effectful [expected_exe] [ttl_ms]"}}

  @doc """
  `lift-follow <inspection_id> <expected_generation> [lift_ttl_ms|-] [schedule_ms|-] [request_timeout_ms|-] [inspection_ttl_ms|-]`
  -> {:ok, %{inspection: id, generation: gen, lift_ttl_ms: t, follow: keyword}} | {:error, reason}. `schedule_ms` is a comma-
  separated list of millisecond offsets after the observed terminal (e.g. 0,250,1000,2000,5000,10000); the follow options are
  validated again, with their bounds, by M6fFollow.plan/1 before anything is issued.
  """
  def lift_follow([insp, gen | more]) when is_binary(insp) and is_binary(gen) do
    with :ok <- nonempty(insp, :inspection_id),
         :ok <- nonempty(gen, :expected_generation),
         true <- length(more) <= 4 || {:error, {:too_many_arguments, length(more) + 2}},
         [lt, sc, rt, it] = more ++ List.duplicate("-", 4 - length(more)),
         {:ok, lift_ttl} <- opt(lt, &ms/1, @lift_ttl_ms),
         {:ok, schedule} <- opt(sc, &schedule/1, nil),
         {:ok, request_timeout} <- opt(rt, &ms/1, nil),
         {:ok, inspection_ttl} <- opt(it, &ms/1, nil) do
      follow =
        [schedule_ms: schedule, request_timeout_ms: request_timeout, inspection_ttl_ms: inspection_ttl]
        |> Enum.reject(fn {_, v} -> v == nil end)

      {:ok, %{inspection: insp, generation: gen, lift_ttl_ms: lift_ttl, follow: follow}}
    end
  end

  def lift_follow(_), do: {:error, {:usage, "lift-follow <inspection_id> <expected_generation> [lift_ttl_ms|-] [schedule_ms|-] [request_timeout_ms|-] [inspection_ttl_ms|-]"}}

  @doc "A plain decimal millisecond count (1-9 digits, no sign, no unit, no spaces)."
  def ms(s) when is_binary(s) do
    if Regex.match?(~r/\A[0-9]{1,9}\z/, s), do: {:ok, String.to_integer(s)}, else: {:error, {:not_a_millisecond_count, s}}
  end

  def ms(other), do: {:error, {:not_a_millisecond_count, other}}

  @doc "A comma-separated list of millisecond counts."
  def schedule(s) when is_binary(s) do
    parts = String.split(s, ",")

    Enum.reduce_while(parts, {:ok, []}, fn p, {:ok, acc} ->
      case ms(p) do
        {:ok, v} -> {:cont, {:ok, acc ++ [v]}}
        {:error, _} -> {:halt, {:error, {:not_a_schedule, s}}}
      end
    end)
  end

  defp opt("-", _f, default), do: {:ok, default}
  defp opt(s, f, _default), do: f.(s)

  # an expected socket owner is an image name (the tool compares it with tasklist's image of the connection's owner)
  defp exe(s) when is_binary(s) do
    if Regex.match?(~r/\A[A-Za-z0-9._-]{1,60}\.exe\z/i, s), do: :ok, else: {:error, {:not_an_image_name, s}}
  end

  defp exe(other), do: {:error, {:not_an_image_name, other}}

  defp nonempty(s, what), do: if(String.trim(s) != "" and s != "-", do: :ok, else: {:error, {:missing, what}})

  @doc """
  M6-F2b preparation (item A): the operator's stop marker `<dir>/stop.marker`, looked at fail-closed. `true` = it exists (any file
  type); `false` ONLY when it is affirmatively absent (`:enoent`) AND `dir` itself is an existing directory; anything else — an
  access or I/O error on the marker, a missing or non-directory `dir` — is `{:error, reason}`: NOT evidence that the operator has not
  stopped. (`File.exists?/1` answers false on every error, so it cannot tell "no marker" from "could not look".)
  """
  def stop_marker(dir) when is_binary(dir) do
    case File.lstat(Path.join(dir, "stop.marker")) do
      {:ok, _} -> true
      {:error, :enoent} ->
        case File.lstat(dir) do
          {:ok, %File.Stat{type: :directory}} -> false
          {:ok, %File.Stat{type: t}} -> {:error, {:evidence_directory_not_a_directory, t}}
          {:error, e} -> {:error, {:evidence_directory, e}}
        end
      {:error, e} -> {:error, {:stop_marker, e}}
    end
  end
end
