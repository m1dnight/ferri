defmodule Ferri.Tunnel.HandlerRegistryTest do
  # async: false because Ferri.Tunnel.Registry is a named singleton (named
  # GenServer + named ETS table). Tests that exercise the register flow
  # need a live Registry, so they share one and run serially.
  use ExUnit.Case, async: false

  alias Ferri.Tunnel.Handler
  alias Ferri.Tunnel.Registry

  # Stand-in for a Yamux.Stream pid: handles the GenServer.call({:send, data})
  # that send_control_message/2 makes, and forwards the data to the test pid
  # so we can assert on the response frame.
  defmodule FakeStream do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_call({:send, data}, _from, parent) do
      send(parent, {:fake_stream_send, data})
      {:reply, :ok, parent}
    end
  end

  setup do
    # The application supervision tree already runs Ferri.Tunnel.Registry, so
    # we just use that one and clean up any registered subdomain on exit.
    {:ok, fake_stream} = FakeStream.start_link(self())
    %{fake_stream: fake_stream}
  end

  defp register_frame do
    json = Jason.encode!(%{type: "register"})
    <<byte_size(json)::32-big, json::binary>>
  end

  describe "register flow" do
    test "register message assigns a subdomain and replies on the control stream",
         %{fake_stream: fake_stream} do
      state = %Handler{control_stream: {1, fake_stream}}

      assert {:ok, new_state} =
               Handler.stream_data(1, register_frame(), fake_stream, state)

      # The handler casts the response back through the (fake) control stream.
      assert_receive {:fake_stream_send, response_frame}, 500

      <<_len::32-big, response_json::binary>> = response_frame
      assert {:ok, response} = Jason.decode(response_json)

      assert response["type"] == "registered"
      assert is_binary(response["subdomain"]) and response["subdomain"] != ""
      assert is_binary(response["url"])
      assert response["url"] =~ response["subdomain"]

      # Handler state is updated with the subdomain.
      assert new_state.subdomain == response["subdomain"]

      # The Registry now resolves the subdomain to the test process (the
      # handler called Registry.register(subdomain, self())).
      assert {:ok, pid} = Registry.lookup(response["subdomain"])
      assert pid == self()

      on_exit(fn -> Registry.unregister(response["subdomain"]) end)
    end

    test "terminate/2 unregisters the subdomain", %{fake_stream: fake_stream} do
      state = %Handler{control_stream: {1, fake_stream}}

      {:ok, new_state} = Handler.stream_data(1, register_frame(), fake_stream, state)
      subdomain = new_state.subdomain

      # Sanity: it's there.
      assert {:ok, _} = Registry.lookup(subdomain)

      assert :ok == Handler.terminate(:tcp_closed, new_state)

      assert :error = Registry.lookup(subdomain)
    end
  end
end
