defmodule GlacierRelay.Command.TokenHolderTest do
  @moduledoc """
  M6-F1a token-guard correction: `Command.TokenHolder` alone — the sources, the private
  unnamed table without an heir, its owner-bound lifetime, verification, the contained failures
  and the absence of any read operation. Tokens here are generated per test and never printed.
  """
  use ExUnit.Case, async: true

  alias GlacierRelay.Command.{Schema, TokenHolder}

  @nonce "00112233445566778899aabbccddeeff"
  @adapter "22222222-2222-4222-8222-222222222222"

  defp fresh_token, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp token_file(contents) do
    path =
      Path.join(System.tmp_dir!(), "tg-holder-#{System.unique_integer([:positive])}.token")

    File.write!(path, contents)
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # true when the token is absent; asserted as `== true` on a precomputed value so that a failure
  # never prints the token (ExUnit prints a failing call's arguments)
  defp no_token_in(term, token),
    do: not String.contains?(inspect(term, limit: :infinity, printable_limit: :infinity), token)

  test "a valid file token is held: available, verified against the shared MAC definition, wrong MACs refused" do
    token = fresh_token()
    {holder, source} = TokenHolder.open(token_file: token_file(token <> "\n"))

    assert source == :file and TokenHolder.available?(holder)
    good = Schema.attest_mac(token, @nonce, 3, @adapter)
    assert :ok = TokenHolder.verify(holder, @nonce, 3, @adapter, good)

    assert {:error, :mac_mismatch} =
             TokenHolder.verify(holder, @nonce, 4, @adapter, good)

    assert {:error, :mac_mismatch} =
             TokenHolder.verify(holder, @nonce, 3, @adapter, String.duplicate("0", 64))

    absent = no_token_in(holder, token)
    assert absent == true
  end

  test "the configured (test) token, an invalid token, an invalid or unreadable file and no source: only a valid token is ever held" do
    token = fresh_token()
    assert {h, :configured} = TokenHolder.open(token: token)
    assert TokenHolder.available?(h)

    for {config, source} <- [
          {[token: "not-hex"], :invalid},
          {[token: 12_345], :invalid},
          {[token_file: token_file("short")], :invalid},
          {[token_file: token_file(String.upcase(token))], :invalid},
          {[token_file: "/nonexistent/glacier-relay/token"], :unreadable},
          {[], :none}
        ] do
      {holder, got} = TokenHolder.open(config)
      assert got == source
      refute TokenHolder.available?(holder)

      assert {:error, :no_token_configured} =
               TokenHolder.verify(holder, @nonce, 1, @adapter, String.duplicate("a", 64))
    end
  end

  test "a failure while loading is contained: no token, a non-secret source, no exception" do
    assert {holder, :load_failed} = TokenHolder.open(:not_a_keyword_list)
    refute TokenHolder.available?(holder)
  end

  test "the table is private, unnamed, without an heir, and owned by its creator; another process cannot read it" do
    token = fresh_token()
    {holder, :configured} = TokenHolder.open(token: token)

    assert :ets.info(holder, :protection) == :private
    assert :ets.info(holder, :named_table) == false
    assert :ets.info(holder, :heir) == :none
    assert :ets.info(holder, :owner) == self()
    assert :ets.info(holder, :size) == 1

    task =
      Task.async(fn ->
        try do
          {:read, :ets.lookup(holder, :token)}
        rescue
          e in ArgumentError -> {:refused, e.__struct__}
        end
      end)

    assert {:refused, ArgumentError} = Task.await(task)

    # and through the holder's own operations from a non-owner: never a value, never success
    assert {:error, :token_unavailable} =
             Task.await(
               Task.async(fn ->
                 TokenHolder.verify(
                   holder,
                   @nonce,
                   1,
                   @adapter,
                   Schema.attest_mac(token, @nonce, 1, @adapter)
                 )
               end)
             )
  end

  test "the table dies with its owner: no orphaned holder; a dead holder verifies nothing" do
    token = fresh_token()
    parent = self()

    owner =
      spawn(fn ->
        {holder, :configured} = TokenHolder.open(token: token)
        send(parent, {:holder, holder})
        receive do: (:stop -> :ok)
      end)

    holder = receive do: ({:holder, h} -> h)
    ref = Process.monitor(owner)
    assert :ets.info(holder, :owner) == owner
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}
    assert :ets.info(holder) == :undefined
    refute TokenHolder.available?(holder)

    assert {:error, :token_unavailable} =
             TokenHolder.verify(
               holder,
               @nonce,
               1,
               @adapter,
               Schema.attest_mac(token, @nonce, 1, @adapter)
             )
  end

  test "an exception in the MAC computation is contained: a fixed non-secret refusal, never success, nothing carrying the token" do
    token = fresh_token()
    {holder, :configured} = TokenHolder.open(token: token)

    # attest_mac/4's guards raise FunctionClauseError on these inputs inside the holder (the token
    # is one of the raising call's arguments)
    for {nonce, generation, adapter} <- [
          {nil, 1, @adapter},
          {@nonce, "1", @adapter},
          {@nonce, 1, :x}
        ] do
      result = TokenHolder.verify(holder, nonce, generation, adapter, String.duplicate("a", 64))
      assert result == {:error, :token_operation_failed}
      absent = no_token_in(result, token)
      assert absent == true
    end
  end

  test "the holder offers no read operation" do
    exported = TokenHolder.__info__(:functions)
    assert Enum.sort(exported) == [available?: 1, open: 1, verify: 5]
  end
end
