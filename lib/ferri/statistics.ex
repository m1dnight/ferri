defmodule Ferri.Statistics do
  @moduledoc """
  Live counters for the dashboard: total bytes proxied in each direction plus
  the current session count.

  Byte counters are backed by `:counters` and stored in `:persistent_term` so
  the HTTP data path can bump them lock-free. Rates (bytes/sec) are computed
  by the consumer (the LiveView) by sampling the totals on a tick and
  differencing against the previous sample.
  """

  alias Ferri.Tunnel.Registry

  @typedoc "Point-in-time totals returned by `snapshot/0`."
  @type snapshot :: %{
          up: non_neg_integer(),
          down: non_neg_integer(),
          sessions: non_neg_integer()
        }

  @key __MODULE__
  @up 1
  @down 2

  @doc """
  Allocate the byte counters and stash the ref in `:persistent_term`. Must be
  called once before any process bumps or reads counters — `Ferri.Application`
  invokes this before the supervision tree starts.
  """
  @spec init :: :ok
  def init do
    :persistent_term.put(@key, :counters.new(2, [:write_concurrency]))
  end

  @doc """
  Add `n` bytes to the upload (visitor → tunnel client) total.
  """
  @spec bump_up(non_neg_integer()) :: :ok
  def bump_up(0), do: :ok
  def bump_up(n) when n > 0, do: :counters.add(ref(), @up, n)

  @doc """
  Add `n` bytes to the download (tunnel client → visitor) total.
  """
  @spec bump_down(non_neg_integer()) :: :ok
  def bump_down(0), do: :ok
  def bump_down(n) when n > 0, do: :counters.add(ref(), @down, n)

  @doc "Total bytes uploaded since `init/0`."
  @spec bytes_up :: non_neg_integer()
  def bytes_up, do: :counters.get(ref(), @up)

  @doc "Total bytes downloaded since `init/0`."
  @spec bytes_down :: non_neg_integer()
  def bytes_down, do: :counters.get(ref(), @down)

  @doc "Current count of active tunnel sessions, sourced from the registry."
  @spec session_count :: non_neg_integer()
  def session_count, do: Registry.session_count()

  @doc """
  Read all three counters at once. Prefer this over three separate reads when
  computing a rate so the upload/download numbers come from the same instant.
  """
  @spec snapshot :: snapshot()
  def snapshot do
    %{up: bytes_up(), down: bytes_down(), sessions: session_count()}
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # returns the ref to the persistent term for the stats.
  defp ref, do: :persistent_term.get(@key)
end
