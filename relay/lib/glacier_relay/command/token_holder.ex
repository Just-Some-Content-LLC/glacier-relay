defmodule GlacierRelay.Command.TokenHolder do
  @moduledoc """
  M6-F1a token-guard correction: the run token's holder, owned by `Command.Authority`. The token
  is read once per authority lifetime — from `:token_file` (the live path: the runtime
  configuration carries the file's PATH, never the token) or `:token` (tests) — validated (64
  lowercase hex characters) and kept in ONE private, unnamed ETS table created by the calling
  process (the authority), with no heir. The authority's ordinary state holds only the opaque
  table reference and the non-secret source (`:file`, `:configured`, `:none`, `:invalid`,
  `:unreadable`, `:load_failed`), so a crash report, a caller's exit reason, a monitor's DOWN
  reason or a supervisor report that prints the state — including the function-clause stack
  frames whose arguments OTP reports unformatted (`gen_server:error_info/7` pairs the formatted
  reason with the original stacktrace) — never carries the token.

  Lifetime: the table belongs to the authority; it is destroyed when the authority dies (no
  heir, no transfer); a restarted authority opens a new holder and reads the file again under the
  same policy. The holder carries no arming and no command state.

  Operations: `open/1` (in the owner), `available?/1`, `verify/5`, `verify_motion/6` (M7-B1). There is no read operation:
  the token leaves the table only inside `verify/5`, where every exception of the lookup or the
  MAC computation is contained and reported as a fixed, non-secret error — never success and
  never a stacktrace whose arguments could hold the token.

  Not an isolation boundary against code executing inside this BEAM node (the owner can read
  its table; tracing `:crypto` calls shows their arguments), an OS-level memory reader, or a VM
  or core dump; no memory erasure is claimed.
  """

  require Logger

  alias GlacierRelay.Command.Schema

  @token_hex ~r/^[0-9a-f]{64}$/

  @typedoc "The holder: the private table's reference (opaque to callers), or nil when none could be created."
  @type t :: :ets.tid() | nil

  @doc """
  Creates the holder in the calling process (the authority) and loads the token from `config`
  (`:token`, else `:token_file`). Returns `{holder, source}`. A failure anywhere in the load is
  contained: no token is held and the source says why, without the value.
  """
  @spec open(keyword()) :: {t(), atom()}
  def open(config) do
    holder = :ets.new(__MODULE__, [:set, :private])
    {holder, store(holder, config)}
  rescue
    _ -> {nil, :load_failed}
  catch
    _, _ -> {nil, :load_failed}
  end

  @doc "Whether a valid token is held."
  @spec available?(t()) :: boolean()
  def available?(nil), do: false

  def available?(holder) do
    :ets.member(holder, :token)
  rescue
    _ -> false
  end

  @doc """
  Verifies a peer's attestation MAC over `nonce|generation|adapter_id` with the held token.
  `:ok`, or `{:error, reason}` with `:no_token_configured`, `:mac_mismatch`, `:token_unavailable`
  (the holder cannot be read) or `:token_operation_failed` (the MAC computation raised).
  """
  @spec verify(t(), term(), term(), term(), term()) :: :ok | {:error, atom()}
  def verify(nil, _nonce, _generation, _adapter_id, _presented),
    do: {:error, :no_token_configured}

  def verify(holder, nonce, generation, adapter_id, presented) do
    case lookup(holder) do
      {:ok, token} -> compare(token, nonce, generation, adapter_id, presented)
      {:error, _} = error -> error
    end
  end

  @doc """
  M7-B1: verifies a native motion link's attestation MAC over
  `motion|nonce|motion_generation|command_generation|adapter_id` with the held token
  (`Schema.motion_attest_mac/5`; design section 15.5). The same contained failures as `verify/5`.
  """
  @spec verify_motion(t(), term(), term(), term(), term(), term()) :: :ok | {:error, atom()}
  def verify_motion(nil, _nonce, _mg, _cg, _adapter_id, _presented),
    do: {:error, :no_token_configured}

  def verify_motion(holder, nonce, motion_generation, command_generation, adapter_id, presented) do
    case lookup(holder) do
      {:ok, token} ->
        compare_with(
          fn ->
            Schema.motion_attest_mac(
              token,
              nonce,
              motion_generation,
              command_generation,
              adapter_id
            )
          end,
          presented
        )

      {:error, _} = error ->
        error
    end
  end

  defp lookup(holder) do
    case :ets.lookup(holder, :token) do
      [{:token, token}] -> {:ok, token}
      [] -> {:error, :no_token_configured}
    end
  rescue
    _ -> {:error, :token_unavailable}
  catch
    _, _ -> {:error, :token_unavailable}
  end

  defp compare(token, nonce, generation, adapter_id, presented) do
    if Schema.mac_equal?(Schema.attest_mac(token, nonce, generation, adapter_id), presented),
      do: :ok,
      else: {:error, :mac_mismatch}
  rescue
    _ -> {:error, :token_operation_failed}
  catch
    _, _ -> {:error, :token_operation_failed}
  end

  defp compare_with(expected_fun, presented) do
    if Schema.mac_equal?(expected_fun.(), presented),
      do: :ok,
      else: {:error, :mac_mismatch}
  rescue
    _ -> {:error, :token_operation_failed}
  catch
    _, _ -> {:error, :token_operation_failed}
  end

  # The token reaches the table and nothing else: the source is the only result.
  defp store(holder, config) do
    case load(config) do
      {:ok, value, source} ->
        true = :ets.insert(holder, {:token, value})
        source

      {:none, source} ->
        source
    end
  rescue
    _ -> :load_failed
  catch
    _, _ -> :load_failed
  end

  defp load(config) do
    token = Keyword.get(config, :token)
    file = Keyword.get(config, :token_file)

    cond do
      is_binary(token) and Regex.match?(@token_hex, token) ->
        {:ok, token, :configured}

      token != nil ->
        Logger.error(
          "command authority: the configured token is not 64 lowercase hex characters; ignored"
        )

        {:none, :invalid}

      is_binary(file) ->
        load_file(file)

      true ->
        {:none, :none}
    end
  end

  defp load_file(file) do
    case File.read(file) do
      {:ok, bytes} ->
        value = String.trim(bytes)

        if Regex.match?(@token_hex, value) do
          {:ok, value, :file}
        else
          Logger.error(
            "command authority: token file is not 64 lowercase hex characters; ignored"
          )

          {:none, :invalid}
        end

      {:error, reason} ->
        Logger.error("command authority: token file unreadable (#{inspect(reason)}); no token")
        {:none, :unreadable}
    end
  end
end
