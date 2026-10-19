defmodule GlacierRelay.Motion.Clock do
  @moduledoc """
  M7-B1: this node's monotonic clock for the motion and peer paths, in milliseconds since the VM
  started — never negative, never adjusted, and comparable only with itself. A value from another
  node, the native adapter or another machine is a different clock domain and is never subtracted
  from it (`docs/design/M7_NETWORK_GHOST.md` section 15.6).
  """

  @doc "Milliseconds since this VM started (monotonic)."
  def now_ms do
    System.monotonic_time(:millisecond) -
      System.convert_time_unit(:erlang.system_info(:start_time), :native, :millisecond)
  end
end
