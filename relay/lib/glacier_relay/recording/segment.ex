defmodule GlacierRelay.Recording.Segment do
  @moduledoc """
  One segment file of a recording (M4-A): `segment-NNNNNN.ndjson`, opened exclusively, appended
  sequentially, hashed incrementally over the bytes that `append` reported written, closed with
  the final SHA-256. The recorder decides what to write and when to sync; this module owns the
  file and the running hash and nothing else.
  """

  alias GlacierRelay.Recording.Writer

  @type t :: %__MODULE__{
          number: pos_integer(),
          name: String.t(),
          path: String.t(),
          fd: Writer.fd(),
          writer: {module(), term()},
          bytes: non_neg_integer(),
          lines: non_neg_integer(),
          hash: term()
        }

  defstruct [:number, :name, :path, :fd, :writer, bytes: 0, lines: 0, hash: nil]

  @doc "The file name of segment `n`."
  def name(n) when is_integer(n) and n > 0,
    do: "segment-" <> String.pad_leading(Integer.to_string(n), 6, "0") <> ".ndjson"

  @spec open(String.t(), pos_integer(), {module(), term()}) :: {:ok, t()} | {:error, term()}
  def open(dir, number, {mod, opts} = writer) do
    name = name(number)
    path = Path.join(dir, name)

    case mod.open(path, opts) do
      {:ok, fd} ->
        {:ok,
         %__MODULE__{
           number: number,
           name: name,
           path: path,
           fd: fd,
           writer: writer,
           hash: :crypto.hash_init(:sha256)
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc "Appends `lines` (a list of iodata lines). Not durable until `sync/1` succeeds."
  @spec append(t(), [iodata()]) :: {:ok, t()} | {:error, term()}
  def append(%__MODULE__{writer: {mod, opts}} = seg, lines) when is_list(lines) do
    bin = IO.iodata_to_binary(lines)

    case mod.append(seg.fd, bin, opts) do
      :ok ->
        {:ok,
         %{
           seg
           | bytes: seg.bytes + byte_size(bin),
             lines: seg.lines + length(lines),
             hash: :crypto.hash_update(seg.hash, bin)
         }}

      {:error, _} = error ->
        error
    end
  end

  @spec sync(t()) :: :ok | {:error, term()}
  def sync(%__MODULE__{writer: {mod, opts}} = seg), do: mod.sync(seg.fd, opts)

  @doc "Closes the file and returns the hex SHA-256 of everything appended."
  @spec close(t()) :: {:ok, String.t()} | {:error, term()}
  def close(%__MODULE__{writer: {mod, opts}} = seg) do
    case mod.close(seg.fd, opts) do
      :ok -> {:ok, Base.encode16(:crypto.hash_final(seg.hash), case: :lower)}
      {:error, _} = error -> error
    end
  end
end
