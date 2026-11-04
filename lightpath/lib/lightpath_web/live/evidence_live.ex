defmodule LightpathWeb.EvidenceLive do
  @moduledoc """
  The evidence page, at `/`.

  Shows the newest fixture set under the configured `:fixtures_root`:

    * a header with the set's name, when it was recorded and the (scrubbed)
      target, plus how many fixtures are ok, failed and not run;
    * one entry per fixture, in manifest order, each with its status
      (`Lightpath.Fixtures.status/1`) as a CSS class `lp-status--ok`,
      `lp-status--failed` or `lp-status--not-run`, linking to `/?id=<id>`;
    * for the selected fixture (`?id=`), its command line, exit code, stdout
      and stderr, and the error when it could not run.

  An unknown `?id=` shows a "no fixture" notice instead of a detail panel.
  When there is no fixture set at all, the page says so and explains how to
  make one. All recorded output is shown as text, never as HTML.
  """
  use LightpathWeb, :live_view

  alias Lightpath.Fixtures

  @impl true
  def mount(_params, _session, socket) do
    root = Application.fetch_env!(:lightpath, :fixtures_root)

    socket =
      case Fixtures.latest(root) do
        {:ok, set} -> assign(socket, set: set, counts: counts(set))
        {:error, :no_sets} -> assign(socket, set: nil, counts: %{})
      end

    {:ok, assign(socket, root: root, page_title: "Evidence")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    id = params["id"]

    selected =
      case {socket.assigns.set, id} do
        {nil, _} -> nil
        {_, nil} -> nil
        {set, id} -> Fixtures.get(set, id)
      end

    {:noreply, assign(socket, id: id, selected: selected)}
  end

  defp counts(set) do
    Enum.frequencies_by(set.fixtures, &Fixtures.status/1)
  end

  defp status_class(fixture), do: "lp-status--" <> status_name(Fixtures.status(fixture))

  defp status_name(:ok), do: "ok"
  defp status_name(:failed), do: "failed"
  defp status_name(:not_run), do: "not-run"

  defp status_label(:ok), do: "ok"
  defp status_label(:failed), do: "failed"
  defp status_label(:not_run), do: "not run"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%= if @set do %>
        <section class="lp-set">
          <div>
            <p class="lp-eyebrow">Evidence set</p>
            <h1 class="lp-set__name">{@set.name}</h1>
            <p class="lp-set__meta">
              recorded <time datetime={@set.created_at}>{@set.created_at}</time>
              on <code>{@set.target}</code>
            </p>
          </div>
          <ul class="lp-counts">
            <li :for={s <- [:ok, :failed, :not_run]} class={"lp-status--" <> status_name(s)}>
              <span class="lp-counts__n">{Map.get(@counts, s, 0)}</span>
              <span class="lp-counts__label">{status_label(s)}</span>
            </li>
          </ul>
        </section>

        <div class="lp-evidence">
          <nav class="lp-list" aria-label="Fixtures">
            <.link
              :for={f <- @set.fixtures}
              patch={~p"/?id=#{f.id}"}
              class={["lp-list__item", status_class(f), @id == f.id && "is-selected"]}
            >
              <span class="lp-dot" aria-hidden="true"></span>
              <span class="lp-list__id">{f.id}</span>
              <span class="lp-list__exit">{f.exit_code}</span>
            </.link>
          </nav>

          <article class="lp-detail">
            <%= case @selected do %>
              <% {:ok, f} -> %>
                <header class="lp-detail__head">
                  <h2>{f.id}</h2>
                  <span class={["lp-chip", status_class(f)]}>
                    {status_label(Fixtures.status(f))} · exit {f.exit_code}
                  </span>
                </header>
                <pre class="lp-cmd"><code>$ {Enum.join(f.argv, " ")}</code></pre>
                <p :if={f.error != ""} class="lp-error">{f.error}</p>
                <section :if={f.stdout != ""}>
                  <h3>stdout</h3>
                  <pre class="lp-out"><code>{f.stdout}</code></pre>
                </section>
                <section :if={f.stderr != ""}>
                  <h3>stderr</h3>
                  <pre class="lp-out lp-out--err"><code>{f.stderr}</code></pre>
                </section>
                <p :if={f.stdout == "" and f.stderr == ""} class="lp-hint">No output.</p>
              <% {:error, :not_found} -> %>
                <p class="lp-notice">No fixture called <code>{@id}</code> in this set.</p>
              <% nil -> %>
                <p class="lp-hint">Pick a fixture to see what the command printed.</p>
            <% end %>
          </article>
        </div>
      <% else %>
        <section class="lp-empty">
          <h1>No fixture set yet</h1>
          <p>Nothing found under <code>{@root}</code>. Record and scrub one:</p>
          <pre class="lp-cmd"><code>probe/bin/inventory -target user@host
    probe/bin/scrub -config private/scrub.json -out fixtures/public/NAME fixtures/raw/RUN</code></pre>
        </section>
      <% end %>
    </Layouts.app>
    """
  end
end
