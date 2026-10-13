defmodule GlacierRelay.Recording.Writer do
  @moduledoc """
  The file-writing primitive behind a segment (M4-A): open, append, sync, close. The production
  writer is `GlacierRelay.Recording.FileWriter`; tests inject one that fails or stalls on
  command. `append` succeeding is not durability; only `sync` succeeding is.
  """

  @type fd :: term()

  @callback open(path :: String.t(), opts :: term()) :: {:ok, fd()} | {:error, term()}
  @callback append(fd(), iodata(), opts :: term()) :: :ok | {:error, term()}
  @callback sync(fd(), opts :: term()) :: :ok | {:error, term()}
  @callback close(fd(), opts :: term()) :: :ok | {:error, term()}
end

defmodule GlacierRelay.Recording.FileWriter do
  @moduledoc "The production writer: a raw file opened exclusively (never over an existing file), `:file.datasync` for durability."
  @behaviour GlacierRelay.Recording.Writer

  @impl true
  def open(path, _opts), do: :file.open(path, [:write, :exclusive, :raw, :binary])

  @impl true
  def append(fd, iodata, _opts), do: :file.write(fd, iodata)

  @impl true
  def sync(fd, _opts), do: :file.datasync(fd)

  @impl true
  def close(fd, _opts), do: :file.close(fd)
end
