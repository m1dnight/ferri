defmodule Yamux.Handler do
  @moduledoc """
  Behaviour for handling yamux session events.

  Implement this behaviour to define how your application responds to yamux
  sessions and streams. The session will invoke these callbacks as events
  occur on the underlying TCP connection.

  ## Example

      defmodule MyApp.EchoHandler do
        @behaviour Yamux.Handler

        @impl true
        def init(_mode), do: {:ok, %{}}

        @impl true
        def new_stream(stream_id, _stream_pid, state) do
          {:ok, state}
        end

        @impl true
        def stream_data(stream_id, data, stream_pid, state) do
          Yamux.Stream.send_data(stream_pid, data)
          {:ok, state}
        end

        @impl true
        def stream_closed(stream_id, _stream_pid, state) do
          {:ok, state}
        end

        @impl true
        def stream_error(stream_id, _stream_pid, state) do
          {:ok, state}
        end

        @impl true
        def ping(opaque, state) do
          {:ok, state}
        end

        @impl true
        def terminate(_reason, _state), do: :ok
      end
  """

  @doc """
  Called when the session starts.

  `mode` is `:client` or `:server`. Return `{:ok, state}` where `state` is
  the handler's initial state that will be threaded through all callbacks.
  """
  @callback init(mode :: :client | :server) :: {:ok, state :: term()}

  @doc """
  Called when a remote peer opens a new stream (SYN received and ACK'd).

  `stream_pid` is the `Yamux.Stream` process — you can call `Yamux.Stream.send_data/2`
  and `Yamux.Stream.recv/2` on it.
  """
  @callback new_stream(
              stream_id :: non_neg_integer(),
              stream_pid :: pid(),
              state :: term()
            ) :: {:ok, new_state :: term()}

  @doc """
  Called when data arrives on an existing stream.
  """
  @callback stream_data(
              stream_id :: non_neg_integer(),
              data :: binary(),
              stream_pid :: pid(),
              state :: term()
            ) :: {:ok, new_state :: term()}

  @doc """
  Called when a stream is half-closed by the remote (FIN received).
  """
  @callback stream_closed(
              stream_id :: non_neg_integer(),
              stream_pid :: pid(),
              state :: term()
            ) :: {:ok, new_state :: term()}

  @doc """
  Called when a stream is abruptly reset by the remote (RST received).
  """
  @callback stream_error(
              stream_id :: non_neg_integer(),
              stream_pid :: pid(),
              state :: term()
            ) :: {:ok, new_state :: term()}

  @doc """
  Called when a ping is received (before the automatic pong is sent).

  `opaque` is the 32-bit value from the ping frame.
  """
  @callback ping(opaque :: non_neg_integer(), state :: term()) :: {:ok, new_state :: term()}

  @doc """
  Called when the session is shutting down (go_away received or TCP closed).
  """
  @callback terminate(reason :: :go_away | :tcp_closed, state :: term()) :: :ok

  @optional_callbacks [ping: 2, terminate: 2, stream_error: 3]

  defmacro __using__(_opts) do
    quote do
      @behaviour Yamux.Handler

      @impl Yamux.Handler
      def ping(_opaque, state), do: {:ok, state}

      @impl Yamux.Handler
      def terminate(_reason, _state), do: :ok

      @impl Yamux.Handler
      def stream_error(_stream_id, _stream_pid, state), do: {:ok, state}

      defoverridable ping: 2, terminate: 2, stream_error: 3
    end
  end
end
