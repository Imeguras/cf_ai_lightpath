defmodule LightpathWeb.ChatLive do
  @moduledoc """
  The chat page, at `/chat`: questions about the homelab, answered through
  the Worker's triage Workflow (small model first, the large one when the
  routing rules escalate or "Ask the large model" is ticked), with memory
  kept by the Worker's Session Durable Object.

  The conversation is `?c=<id>` (1 to 64 letters, digits, `-` or `_`), or
  `chat-<visitor>` without one or with an invalid one. "New conversation"
  links to a fresh random id. The stored messages load without blocking the
  page; assistant messages carry their model and the AI labels. Asking
  trims the question (a blank one is ignored), shows it at once, starts a
  triage, polls it, then reloads the conversation and says which model
  answered and why. Failures are notices. All text is shown as text, never
  as HTML. Without the Worker the page says what to configure.
  """
  use LightpathWeb, :live_view

  import LightpathWeb.Live.Helpers

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign_common(session)
     |> assign(page_title: "Chat", messages: [], pending: nil, last: nil, error: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    c = params["c"]

    conversation =
      if is_binary(c) and Regex.match?(~r/^[A-Za-z0-9_-]{1,64}$/, c),
        do: c,
        else: "chat-" <> socket.assigns.visitor

    socket =
      socket
      |> assign(
        conversation: conversation,
        fresh: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      )
      |> load_history()

    {:noreply, socket}
  end

  @impl true
  def handle_event("ask", params, socket) do
    message = String.trim(params["message"] || "")

    cond do
      message == "" or socket.assigns.pending != nil or not socket.assigns.can_ai ->
        {:noreply, socket}

      true ->
        %{worker: worker, visitor: visitor, conversation: c} = socket.assigns
        hard = params["hard"] == "true"

        {:noreply,
         socket
         |> assign(pending: message, error: nil, last: nil)
         |> start_async(:triage, fn -> worker.triage(visitor, c, message, hard) end)}
    end
  end

  @impl true
  def handle_async(:history, {:ok, {:ok, messages}}, socket),
    do: {:noreply, assign(socket, messages: messages, pending: nil)}

  def handle_async(:history, {:ok, {:error, reason}}, socket),
    do:
      {:noreply,
       assign(socket, error: "could not load the conversation: #{reason}", pending: nil)}

  def handle_async(:triage, {:ok, {:ok, instance}}, socket) do
    send(self(), {:poll, instance, 1})
    {:noreply, socket}
  end

  def handle_async({:poll, instance, attempt}, {:ok, {:ok, status}}, socket) do
    cond do
      status.status == "complete" ->
        {:noreply, socket |> assign(last: status.output) |> load_history()}

      finished?(status.status) ->
        {:noreply, failed(socket, status.error || "the Workflow #{status.status}")}

      attempt >= max_polls() ->
        {:noreply, failed(socket, "no answer after #{attempt} checks")}

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
       worker.triage_status(visitor, instance)
     end)}
  end

  defp failed(socket, reason), do: assign(socket, error: reason, pending: nil)

  defp load_history(socket) do
    if socket.assigns.can_ai do
      %{worker: worker, visitor: visitor, conversation: c} = socket.assigns
      start_async(socket, :history, fn -> worker.history(visitor, c) end)
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:chat} usage={@usage}>
      <section class="lp-chat">
        <header class="lp-chat__head">
          <div>
            <p class="lp-eyebrow">Chat</p>
            <h1>Ask about the server</h1>
          </div>
          <.link :if={@can_ai} navigate={~p"/chat?#{[c: @fresh]}"} class="lp-new-chat">
            New conversation
          </.link>
        </header>

        <%= if @can_ai do %>
          <ol class="lp-messages">
            <li :for={m <- @messages} class={["lp-msg", "lp-msg--" <> m["role"]]}>
              <p :if={m["role"] == "assistant"} class="lp-ai__label">
                AI-generated · unscored · <code>{m["model"]}</code> · AI can make mistakes.
              </p>
              <p class="lp-msg__text">{m["content"]}</p>
            </li>
            <li :if={@pending} class="lp-msg lp-msg--user is-pending">
              <p class="lp-msg__text">{@pending}</p>
              <p class="lp-hint">Thinking…</p>
            </li>
          </ol>

          <p :if={@last} class="lp-hint lp-why">
            Answered by <code>{@last["model"]}</code>: {@last["reason"]}
            <span :if={is_number(@last["neurons"])}>
              · ≈ {Float.round(@last["neurons"] * 1.0, 1)} neurons
            </span>
          </p>
          <p :if={@error} class="lp-notice">{@error}</p>

          <form class="lp-ask" phx-submit="ask">
            <textarea
              name="message"
              rows="3"
              maxlength="4000"
              placeholder="Why is kubelet restarting?"
              disabled={@pending != nil}
            ></textarea>
            <div class="lp-ask__row">
              <label><input type="checkbox" name="hard" value="true" /> Ask the large model</label>
              <button type="submit" class="lp-button" disabled={@pending != nil}>Ask</button>
            </div>
          </form>
        <% else %>
          <p class="lp-notice">
            Chat needs the Worker: set <code>LIGHTPATH_WORKER_URL</code>
            and <code>LIGHTPATH_JWT_SECRET</code>.
          </p>
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
