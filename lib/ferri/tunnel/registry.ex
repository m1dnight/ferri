defmodule Ferri.Tunnel.Registry do
  @moduledoc """
  Maps subdomains to yamux session PIDs.

  Uses an ETS table so lookups from the HTTP listener are fast and don't
  bottleneck through a single process.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Register a subdomain for the given session. Returns :ok or {:error, :taken}.
  """
  @spec register(String.t(), pid()) :: :ok | {:error, :taken}
  def register(subdomain, session_pid) do
    case :ets.insert_new(@table, {subdomain, session_pid}) do
      true ->
        # Monitor the session so we can clean up when it dies
        GenServer.cast(__MODULE__, {:monitor, subdomain, session_pid})
        :ok

      false ->
        {:error, :taken}
    end
  end

  @doc """
  Look up which session owns a subdomain. Returns {:ok, pid} or :error.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(subdomain) do
    case :ets.lookup(@table, subdomain) do
      [{^subdomain, pid}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Remove a subdomain from the registry.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(subdomain) do
    :ets.delete(@table, subdomain)
    :ok
  end

  @doc """
  Generate a random subdomain that isn't taken.
  """
  @spec generate_subdomain() :: String.t()
  def generate_subdomain do
    subdomain = HorseStapleBattery.generate_compound(:kebab_case, [:adjective, :noun])

    case :ets.lookup(@table, subdomain) do
      [] -> subdomain
      _ -> generate_subdomain()
    end
  end

  # -- GenServer callbacks --

  @impl true
  def init([]) do
    @table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:monitor, subdomain, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, Map.put(state, ref, subdomain)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {subdomain, state} ->
        :ets.delete(@table, subdomain)
        {:noreply, state}
    end
  end
end
