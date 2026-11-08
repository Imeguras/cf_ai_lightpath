defmodule LightpathWeb.NewsLive do
  @moduledoc """
  The Arch news page, at `/news`: the Worker's latest digest of the last 30
  days of Arch Linux news, matched against the installed packages.

  The latest digest loads without blocking the page ("No digest yet" when
  there is none): the large model's text with the AI labels, then every
  item with its date, a link to the announcement (opened as a new page,
  `noopener noreferrer`) and the installed packages it mentions
  (`.lp-match`). "Update digest" uploads the package names from the newest
  evidence set (`Lightpath.Packages`), starts the news Workflow, polls it
  and shows the new digest; the Worker reuses a cached digest when neither
  the news nor the packages changed. Failures are notices. All text is
  shown as text. Without the Worker the page says what to configure.
  """
  use LightpathWeb, :live_view

  import LightpathWeb.Live.Helpers

  alias Lightpath.{Fixtures, Packages}

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign_common(session)
      |> assign(page_title: "Arch news", digest: nil, loaded: false, updating: false, error: nil)

    socket =
      if socket.assigns.can_ai do
        %{worker: worker, visitor: visitor} = socket.assigns
        start_async(socket, :latest, fn -> worker.news_latest(visitor) end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("update", _params, socket) do
    if socket.assigns.updating or not socket.assigns.can_ai do
      {:noreply, socket}
    else
      %{worker: worker, visitor: visitor} = socket.assigns
      root = Application.fetch_env!(:lightpath, :fixtures_root)

      packages =
        case Fixtures.latest(root) do
          {:ok, set} -> Packages.names(set)
          {:error, _} -> []
        end

      {:noreply,
       socket
       |> assign(updating: true, error: nil)
       |> start_async(:start, fn ->
         with {:ok, _} <- worker.upload_packages(visitor, packages), do: worker.news(visitor)
       end)}
    end
  end

  @impl true
  def handle_async(:latest, {:ok, {:ok, digest}}, socket),
    do: {:noreply, assign(socket, digest: digest, loaded: true)}

  def handle_async(:start, {:ok, {:ok, instance}}, socket) do
    send(self(), {:poll, instance, 1})
    {:noreply, socket}
  end

  def handle_async({:poll, instance, attempt}, {:ok, {:ok, status}}, socket) do
    cond do
      status.status == "complete" ->
        {:noreply, assign(socket, digest: status.output, loaded: true, updating: false)}

      finished?(status.status) ->
        {:noreply, failed(socket, status.error || "the Workflow #{status.status}")}

      attempt >= max_polls() ->
        {:noreply, failed(socket, "no digest after #{attempt} checks")}

      true ->
        Process.send_after(self(), {:poll, instance, attempt + 1}, poll_ms())
        {:noreply, socket}
    end
  end

  def handle_async(_name, {:ok, {:error, reason}}, socket), do: {:noreply, failed(socket, reason)}

  def handle_async(_name, {:exit, reason}, socket),
    do: {:noreply, failed(socket, "crashed: #{inspect(reason)}")}

  @impl true
  def handle_info({:poll, instance, attempt}, socket) do
    %{worker: worker, visitor: visitor} = socket.assigns

    {:noreply,
     start_async(socket, {:poll, instance, attempt}, fn ->
       worker.news_status(visitor, instance)
     end)}
  end

  defp failed(socket, reason), do: assign(socket, error: reason, updating: false, loaded: true)

  defp date(ms) when is_integer(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date() |> Date.to_iso8601()

  defp date(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:news} usage={@usage}>
      <section class="lp-news">
        <header class="lp-chat__head">
          <div>
            <p class="lp-eyebrow">Arch Linux news</p>
            <h1>Last 30 days, against the installed packages</h1>
          </div>
          <button
            :if={@can_ai}
            type="button"
            class="lp-button"
            phx-click="update"
            disabled={@updating}
          >
            {if @updating, do: "Updating…", else: "Update digest"}
          </button>
        </header>

        <%= cond do %>
          <% not @can_ai -> %>
            <p class="lp-notice">
              The news digest needs the Worker: set <code>LIGHTPATH_WORKER_URL</code>
              and <code>LIGHTPATH_JWT_SECRET</code>.
            </p>
          <% @digest -> %>
            <section class="lp-ai">
              <p class="lp-ai__label">
                <%= if @digest["model"] in [nil, ""] do %>
                  No model needed
                <% else %>
                  AI-generated · unscored · <code>{@digest["model"]}</code> · AI can make mistakes.
                <% end %>
                <span :if={@digest["cached"]}>· cached</span>
                <span>· made {date(@digest["created"])}</span>
              </p>
              <p class="lp-ai__text">{@digest["text"]}</p>
            </section>
            <ul class="lp-news__items">
              <li :for={item <- @digest["items"] || []}>
                <time>{date(item["published"])}</time>
                <a href={item["link"]} target="_blank" rel="noopener noreferrer">{item["title"]}</a>
                <span :for={m <- item["matches"] || []} class="lp-match">{m}</span>
              </li>
            </ul>
          <% @loaded -> %>
            <p class="lp-hint">No digest yet. "Update digest" makes one.</p>
          <% true -> %>
            <p class="lp-hint">Loading…</p>
        <% end %>
        <p :if={@error} class="lp-notice">{@error}</p>
      </section>
    </Layouts.app>
    """
  end
end
