defmodule Ferri.Tunnel.Handler do
  @moduledoc """
  Yamux handler for Ferri tunnel control sessions.

  When a Rust client connects on port 4433 and opens a yamux session, this
  handler manages the control protocol:

  1. Client opens stream 1 (control stream)
  2. Client sends `{"type": "register"}` on stream 1
  3. Handler assigns a subdomain and registers it
  4. Handler sends `{"type": "registered", ...}` back on stream 1

  After registration, visitor streams are opened by the server (even IDs) and
  carry raw HTTP bytes.
  """

  use Yamux.Handler

  alias Ferri.Tunnel.Registry

  require Logger

  defstruct [:control_stream, :subdomain, :session_pid, buffer: <<>>]

  @impl true
  def init(_mode) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def new_stream(stream_id, stream_pid, state) do
    # The first stream opened by the client is the control stream.
    if state.control_stream == nil do
      Logger.info("Control stream opened: #{stream_id}")
      {:ok, %{state | control_stream: {stream_id, stream_pid}}}
    else
      {:ok, state}
    end
  end

  @impl true
  def stream_data(stream_id, data, _stream_pid, state) do
    Logger.debug("Data received: #{inspect(data)}")
    {control_id, _control_pid} = state.control_stream

    if stream_id == control_id do
      handle_control_data(data, state)
    else
      # Visitor stream data — handled by the proxy, not the control handler
      {:ok, state}
    end
  end

  @impl true
  def stream_closed(_stream_id, _stream_pid, state) do
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    if state.subdomain do
      Logger.info("Tunnel #{state.subdomain} disconnected: #{reason}")
      Registry.unregister(state.subdomain)
    end

    :ok
  end

  # -- Control protocol --

  # Control messages are length-prefixed JSON:
  # <<length::32-big, json::binary-size(length)>>
  defp handle_control_data(data, state) do
    buffer = state.buffer <> data

    drain_control_messages(buffer, state)
  end

  # matches if the buffer starts with a length header and enough bytes that
  # constitute an entire json payload.
  defp drain_control_messages(
         <<length::32-big, json::binary-size(length), rest::binary>>,
         state
       ) do
    message = Jason.decode!(json)
    state = handle_control_message(message, state)
    drain_control_messages(rest, %{state | buffer: <<>>})
  end

  # we might have a length header, but were missing the entire body
  defp drain_control_messages(remaining, state) do
    {:ok, %{state | buffer: remaining}}
  end

  defp handle_control_message(%{"type" => "register"}, state) do
    {_control_id, control_pid} = state.control_stream
    subdomain = Registry.generate_subdomain()

    case Registry.register(subdomain, self()) do
      :ok ->
        url = "https://#{subdomain}.#{FerriWeb.Endpoint.host()}"
        Logger.info("Tunnel registered: #{url}")

        response = Jason.encode!(%{type: "registered", subdomain: subdomain, url: url})

        :ok = send_control_message(control_pid, response)
        %{state | subdomain: subdomain, session_pid: self()}

      {:error, :taken} ->
        response = Jason.encode!(%{type: "error", reason: "subdomain_taken"})
        :ok = send_control_message(control_pid, response)
        state
    end
  end

  defp handle_control_message(message, state) do
    Logger.warning("Unknown control message: #{inspect(message)}")
    state
  end

  defp send_control_message(stream_pid, json) when is_binary(json) do
    frame = <<byte_size(json)::32-big, json::binary>>
    Yamux.Stream.send_data(stream_pid, frame)
  end
end
