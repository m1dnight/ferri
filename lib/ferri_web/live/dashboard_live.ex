defmodule FerriWeb.DashboardLive do
  use FerriWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Dashboard — Ferri")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ferri-landing">
      <div class="ferri-page">
        <header class="ferri-top">
          <a class="ferri-brand" href={~p"/"}>
            <svg class="ferri-brand-mark" viewBox="0 0 60 60" fill="none" aria-hidden="true">
              <circle class="ring-outer" cx="30" cy="30" r="26" stroke-width="2.4" />
              <circle class="ring-inner" cx="30" cy="30" r="16" stroke-width="1.6" />
              <path
                class="arrow"
                d="M14 30 H46 M40 24 L46 30 L40 36"
                stroke-width="2.4"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
            </svg>
            <span class="ferri-brand-name">Ferri</span>
          </a>

          <nav class="ferri-nav">
            <a href={~p"/dashboard"}>Dashboard</a>
          </nav>

          <div class="ferri-meta">
            <span class="dot"></span>
            <span>v{Application.spec(:ferri, :vsn)} — current</span>
          </div>
        </header>

        <section class="ferri-hero">
          <div class="ferri-section-label">Dashboard</div>

          <h1>Live numbers,<br /><em>soon.</em></h1>

          <p class="ferri-lede">
            Tunnel counts, traffic, and uptime will live here. Wired up
            with LiveView so the figures update without a refresh.
          </p>
        </section>
      </div>
    </div>
    """
  end
end
