defmodule LightpathWeb.EvidenceLive do
  @moduledoc """
  The evidence page, at `/`.

  Shows one fixture set under the configured `:fixtures_root`: the newest by
  default, or the one named by `?set=` (a dropdown, `form.lp-setpick`, lists
  every set newest first, labelled by when it was recorded; an unknown name
  shows a notice):

    * a header titled with when the set was recorded (`LightpathWeb.Format`),
      then its name and the (scrubbed) target, plus how many fixtures there are of each kind
      (`Lightpath.Fixtures.kind/1`: ok, failed, needs root, inactive, not
      run), leaving out kinds with none;
    * one entry per fixture, in manifest order, with its kind as a CSS class
      (`lp-kind--ok`, `lp-kind--needs-privilege`, ...), linking to `?id=`
      (keeping `?set=` when one was chosen);
    * for the selected fixture, its kind, command line, exit code, stdout and
      stderr, and the error when it could not run.

  Every rule under `priv/rules/` that applies to the set's facts gets a
  diagnosis panel (`.lp-diagnosis[data-rule=<id>]`): the rule's title and
  review status, then every cause (`[data-cause=<id>]`) ranked by
  probability, each with its percentage, the evidence that moved it (title,
  ratio, links to its fixtures), and its runbook (`.lp-runbook`,
  `Lightpath.Runbooks`) or, without one, the file to add.

  When the Worker (`Lightpath.Worker.impl/0`) is available:

    * each panel has "Suggest a fix": it starts a triage Workflow with
      `Lightpath.Suggest.message/4` (the scored ranking and the top cause's
      runbook) in the visitor's `suggest-<visitor>` session, polls it, and
      shows the answer (`.lp-ai`) with its model, why that model answered,
      and the AI labels, or the failure as a notice;
    * the detail panel has "Explain", which asks about the selected fixture;
      answers are kept per fixture while the page is open;
    * the header shows today's rough neuron estimate.

  When the live probe daemon (`Lightpath.Probe.impl/0`) is available:

    * "Re-probe now" asks it to run every probe; the new set is then shown,
      or the failure as a notice;
    * a timeline (`.lp-timeline`) lists the last 7 days of events it
      recorded (package changes, unit failures, kernel warnings, link
      changes), newest first, at most 50, grouped by UTC day
      (`.lp-timeline__day`), each with its time, a badge coloured by its
      change (`.lp-badge--bad|warn|good|neutral`) and "×N" when N identical
      events were folded into it (a flapping unit).

  Every `:refresh_ms` (default 15 s) the page looks for new sets: viewing
  the newest, it switches to a newer one by itself (and reloads the
  timeline); with an older set chosen by `?set=`, it announces the newer
  one ("Newer evidence") with a link instead of switching.

  Without the Worker there are no AI buttons and no estimate. AI requests
  never block the page. All recorded output and AI text is shown as text,
  never as HTML. When there is no fixture set at all, the page says so and
  explains how to make one.
  """
  use LightpathWeb, :live_view

  import LightpathWeb.Live.Helpers

  alias LightpathWeb.Format

  alias Lightpath.{Diagnosis, Fixtures, Probe, Runbooks, Suggest}
  alias Lightpath.Diagnosis.Facts

  @kinds [:ok, :failed, :needs_privilege, :inactive, :not_run]

  @impl true
  def mount(_params, session, socket) do
    root = Application.fetch_env!(:lightpath, :fixtures_root)
    probe = Probe.impl()
    can_probe = probe.available?()

    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign_common(session)
     |> assign(
       root: root,
       sets: Fixtures.list(root),
       page_title: "Evidence",
       explaining: nil,
       explanations: %{},
       suggestions: %{},
       probe: probe,
       can_probe: can_probe,
       probing: false,
       probe_error: nil,
       events: [],
       newer: nil
     )
     |> load_events()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    sets = socket.assigns.sets
    set_param = params["set"]

    set =
      case set_param do
        nil -> List.first(sets)
        name -> Enum.find(sets, &(&1.name == name))
      end

    socket =
      if set && socket.assigns[:set] && set.name == socket.assigns.set.name,
        do: socket,
        else: show_set(socket, set)

    socket = if set_param == nil, do: assign(socket, newer: nil), else: socket

    id = params["id"]
    selected = if set && id, do: Fixtures.get(set, id)

    {:noreply, assign(socket, set_param: set_param, id: id, selected: selected)}
  end

  @impl true
  def handle_event("explain", %{"id" => id}, socket) do
    with %{} = set <- socket.assigns.set,
         {:ok, fixture} <- Fixtures.get(set, id) do
      %{worker: worker, visitor: visitor} = socket.assigns

      {:noreply,
       socket
       |> assign(explaining: id)
       |> start_async({:explain, id}, fn -> worker.explain(fixture, visitor) end)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("pick_set", %{"set" => name}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/?#{[set: name]}")}

  def handle_event("reprobe", _params, socket) do
    if socket.assigns.probing or not socket.assigns.can_probe do
      {:noreply, socket}
    else
      probe = socket.assigns.probe

      {:noreply,
       socket
       |> assign(probing: true, probe_error: nil)
       |> start_async(:reprobe, fn -> probe.probe() end)}
    end
  end

  def handle_event("suggest", %{"rule" => rule_id}, socket) do
    case Enum.find(socket.assigns.diagnoses, &(&1[:rule] && &1.rule.id == rule_id)) do
      nil ->
        {:noreply, socket}

      d ->
        %{worker: worker, visitor: visitor} = socket.assigns
        top = hd(d.causes)

        runbook =
          case Runbooks.get(rule_id, top.id) do
            {:ok, text} -> text
            :none -> nil
          end

        message = Suggest.message(d.rule, d.causes, d.evidence, runbook)
        session = "suggest-" <> visitor

        {:noreply,
         socket
         |> put_suggestion(rule_id, :starting)
         |> start_async({:suggest, rule_id}, fn ->
           worker.triage(visitor, session, message, false)
         end)}
    end
  end

  @impl true
  def handle_async({:explain, id}, result, socket) do
    answer =
      case result do
        {:ok, reply} -> reply
        {:exit, reason} -> {:error, "the explanation crashed: #{inspect(reason)}"}
      end

    {:noreply,
     assign(socket,
       explaining: nil,
       explanations: Map.put(socket.assigns.explanations, id, answer)
     )}
  end

  def handle_async(:reprobe, result, socket) do
    socket = assign(socket, probing: false)

    case result do
      {:ok, {:ok, _name}} ->
        socket =
          socket |> assign(sets: Fixtures.list(socket.assigns.root), newer: nil) |> load_events()

        {:noreply, push_patch(socket, to: ~p"/")}

      {:ok, {:error, reason}} ->
        {:noreply, assign(socket, probe_error: reason)}

      {:exit, reason} ->
        {:noreply, assign(socket, probe_error: "crashed: #{inspect(reason)}")}
    end
  end

  def handle_async(:events, {:ok, {:ok, events}}, socket),
    do: {:noreply, assign(socket, events: events |> Enum.reverse() |> Enum.take(50))}

  def handle_async(:events, _failed, socket), do: {:noreply, assign(socket, events: [])}

  def handle_async({:suggest, rule_id}, result, socket) do
    case result do
      {:ok, {:ok, instance}} ->
        send(self(), {:poll, rule_id, instance, 1})
        {:noreply, put_suggestion(socket, rule_id, {:pending, instance})}

      {:ok, {:error, reason}} ->
        {:noreply, put_suggestion(socket, rule_id, {:error, reason})}

      {:exit, reason} ->
        {:noreply, put_suggestion(socket, rule_id, {:error, "crashed: #{inspect(reason)}"})}
    end
  end

  def handle_async({:poll, rule_id, instance, attempt}, result, socket) do
    case result do
      {:ok, {:ok, %{status: "complete", output: %{} = output}}} ->
        {:noreply, put_suggestion(socket, rule_id, {:ok, output})}

      {:ok, {:ok, %{status: status, error: error}}} ->
        cond do
          finished?(status) ->
            {:noreply,
             put_suggestion(socket, rule_id, {:error, error || "the Workflow #{status}"})}

          attempt >= max_polls() ->
            {:noreply,
             put_suggestion(socket, rule_id, {:error, "no answer after #{attempt} checks"})}

          true ->
            Process.send_after(self(), {:poll, rule_id, instance, attempt + 1}, poll_ms())
            {:noreply, socket}
        end

      {:ok, {:error, reason}} ->
        {:noreply, put_suggestion(socket, rule_id, {:error, reason})}

      {:exit, reason} ->
        {:noreply, put_suggestion(socket, rule_id, {:error, "crashed: #{inspect(reason)}"})}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    sets = Fixtures.list(socket.assigns.root)
    newest = List.first(sets)
    current = socket.assigns[:set]

    cond do
      newest == nil or (current && newest.name == current.name) ->
        {:noreply, assign(socket, sets: sets)}

      socket.assigns.set_param == nil ->
        socket = socket |> assign(sets: sets, newer: nil) |> show_set(newest) |> load_events()
        {:noreply, socket}

      current && newest.created_at > current.created_at ->
        {:noreply, assign(socket, sets: sets, newer: newest.name)}

      true ->
        {:noreply, assign(socket, sets: sets)}
    end
  end

  def handle_info({:poll, rule_id, instance, attempt}, socket) do
    %{worker: worker, visitor: visitor} = socket.assigns

    {:noreply,
     start_async(socket, {:poll, rule_id, instance, attempt}, fn ->
       worker.triage_status(visitor, instance)
     end)}
  end

  defp show_set(socket, set) do
    assign(socket,
      set: set,
      counts: set && Enum.frequencies_by(set.fixtures, &Fixtures.kind/1),
      diagnoses: if(set, do: diagnose(set), else: []),
      suggestions: %{}
    )
  end

  # Events (newest first) grouped by UTC day, keeping that order.
  defp by_day(events) do
    events
    |> Enum.chunk_by(&Format.day(&1["time"]))
    |> Enum.map(fn [first | _] = group -> {Format.day(first["time"]), group} end)
  end

  defp schedule_refresh,
    do: Process.send_after(self(), :refresh, Application.get_env(:lightpath, :refresh_ms, 15_000))

  defp load_events(socket) do
    if socket.assigns.can_probe do
      probe = socket.assigns.probe
      since = DateTime.add(DateTime.utc_now(), -7, :day)
      start_async(socket, :events, fn -> probe.events(since) end)
    else
      socket
    end
  end

  defp put_suggestion(socket, rule_id, state) do
    assign(socket, suggestions: Map.put(socket.assigns.suggestions, rule_id, state))
  end

  # Every rule that applies to the set, with its ranked causes and an index
  # of the evidence by id (for titles and fixture links).
  defp diagnose(set) do
    facts = Facts.extract(set)

    case Diagnosis.load_all(Application.app_dir(:lightpath, "priv/rules")) do
      {:ok, rules} ->
        for rule <- rules, Diagnosis.applies?(rule, facts) do
          %{
            rule: rule,
            causes: Diagnosis.score(rule, facts),
            evidence: Map.new(rule.evidence, &{&1["id"], &1})
          }
        end

      {:error, reason} ->
        [%{error: reason}]
    end
  end

  defp fixture_path(nil, id), do: ~p"/?#{[id: id]}"
  defp fixture_path(set, id), do: ~p"/?#{[set: set, id: id]}"

  # "Something else" has no runbook to write.
  defp runbook(_rule_id, "other"), do: :skip

  defp runbook(rule_id, cause_id) do
    case Runbooks.get(rule_id, cause_id) do
      {:ok, text} -> {:ok, text}
      :none -> {:none, "priv/runbooks/#{rule_id}/#{cause_id}.md"}
    end
  end

  defp percent(p) when p < 0.001, do: "<0.1%"
  defp percent(p), do: :erlang.float_to_binary(p * 100, decimals: 1) <> "%"

  defp ratio(r) when is_integer(r), do: "×#{r}"
  defp ratio(r), do: "×" <> :erlang.float_to_binary(r * 1.0, [:short])

  defp kind_class(kind), do: "lp-kind--" <> String.replace(Atom.to_string(kind), "_", "-")

  defp kind_label(:ok), do: "ok"
  defp kind_label(:failed), do: "failed"
  defp kind_label(:needs_privilege), do: "needs root"
  defp kind_label(:inactive), do: "inactive"
  defp kind_label(:not_run), do: "not run"

  attr :answer, :map, required: true

  defp ai_answer(assigns) do
    ~H"""
    <section class="lp-ai">
      <p class="lp-ai__label">
        AI-generated · unscored · <code>{@answer["model"]}</code>
        <span :if={@answer["reason"]}>· {@answer["reason"]}</span> · AI can make mistakes.
      </p>
      <p class="lp-ai__text">{@answer["text"]}</p>
    </section>
    """
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, kinds: @kinds)

    ~H"""
    <Layouts.app flash={@flash} page={:evidence} usage={@usage}>
      <%= cond do %>
        <% @sets == [] -> %>
          <section class="lp-empty">
            <h1>No fixture set yet</h1>
            <p>Nothing found under <code>{@root}</code>. Record and scrub one:</p>
            <pre class="lp-cmd"><code>probe/bin/inventory -target user@host
    probe/bin/scrub -config private/scrub.json -out fixtures/public/NAME fixtures/raw/RUN</code></pre>
          </section>
        <% @set == nil -> %>
          <p class="lp-notice">
            No evidence set called <code>{@set_param}</code>. <.link patch={~p"/"}>Show the newest</.link>.
          </p>
        <% true -> %>
          <section class="lp-set">
            <div>
              <p class="lp-eyebrow">Evidence recorded</p>
              <h1 class="lp-set__when">
                <time datetime={@set.created_at}>{Format.when_utc(@set.created_at)}</time>
              </h1>
              <p class="lp-set__meta">
                <code class="lp-set__name">{@set.name}</code> on <code>{@set.target}</code>
              </p>
              <div :if={@can_probe} class="lp-reprobe">
                <button type="button" class="lp-button" phx-click="reprobe" disabled={@probing}>
                  {if @probing, do: "Probing…", else: "Re-probe now"}
                </button>
              </div>
              <p :if={@probe_error} class="lp-notice">Could not re-probe: {@probe_error}</p>
              <p :if={@newer} class="lp-notice">
                Newer evidence: <.link patch={~p"/?#{[set: @newer]}"}>{@newer}</.link>
              </p>
              <form :if={length(@sets) > 1} class="lp-setpick" phx-change="pick_set">
                <label for="lp-setpick">Other evidence</label>
                <select id="lp-setpick" name="set">
                  <option :for={s <- @sets} value={s.name} selected={s.name == @set.name}>
                    {Format.when_utc(s.created_at)} · {s.name}
                  </option>
                </select>
              </form>
            </div>
            <ul class="lp-counts">
              <li :for={k <- @kinds} :if={Map.get(@counts, k, 0) > 0} class={kind_class(k)}>
                <span class="lp-counts__n">{Map.get(@counts, k, 0)}</span>
                <span class="lp-counts__label">{kind_label(k)}</span>
              </li>
            </ul>
          </section>

          <section
            :for={d <- @diagnoses}
            class="lp-diagnosis"
            data-rule={d[:rule] && d.rule.id}
            aria-label="Diagnosis"
          >
            <%= if d[:error] do %>
              <p class="lp-notice">The diagnosis rules could not be loaded: {d.error}</p>
            <% else %>
              <header class="lp-diagnosis__head">
                <div>
                  <p class="lp-eyebrow">Diagnosis</p>
                  <h2>{d.rule.title}</h2>
                </div>
                <p :if={d.rule.status} class="lp-review">{d.rule.status}</p>
              </header>
              <ol class="lp-causes">
                <li
                  :for={{c, i} <- Enum.with_index(d.causes)}
                  class={["lp-cause", i == 0 && "is-top"]}
                  data-cause={c.id}
                >
                  <div class="lp-cause__row">
                    <span class="lp-cause__title">{c.title}</span>
                    <span class="lp-cause__pct">{percent(c.probability)}</span>
                  </div>
                  <div class="lp-bar" aria-hidden="true">
                    <span style={"width: #{Float.round(c.probability * 100, 2)}%"}></span>
                  </div>
                  <ul :if={c.contributions != []} class="lp-contrib">
                    <li :for={{ev_id, r} <- c.contributions}>
                      <span class={["lp-ratio", r > 1 && "is-up"]}>{ratio(r)}</span>
                      <span>{d.evidence[ev_id]["title"]}</span>
                      <.link
                        :for={src <- Facts.sources(d.evidence[ev_id]["when"]["fact"])}
                        patch={fixture_path(@set_param, src)}
                        class="lp-src"
                      >
                        {src}
                      </.link>
                    </li>
                  </ul>
                  <%= case runbook(d.rule.id, c.id) do %>
                    <% {:ok, text} -> %>
                      <details class="lp-runbook" open={i == 0}>
                        <summary>Runbook</summary>
                        <pre><code>{text}</code></pre>
                      </details>
                    <% :skip -> %>
                    <% {:none, path} -> %>
                      <p class="lp-hint lp-runbook-missing">
                        No runbook yet: add <code>{path}</code>
                      </p>
                  <% end %>
                </li>
              </ol>
              <div :if={@can_ai} class="lp-suggest">
                <button
                  type="button"
                  class="lp-button"
                  phx-click="suggest"
                  phx-value-rule={d.rule.id}
                  disabled={
                    match?({:pending, _}, @suggestions[d.rule.id]) or
                      @suggestions[d.rule.id] == :starting
                  }
                >
                  <%= case @suggestions[d.rule.id] do %>
                    <% s when s == :starting or is_tuple(s) and elem(s, 0) == :pending -> %>
                      Thinking…
                    <% _ -> %>
                      Suggest a fix
                  <% end %>
                </button>
                <%= case @suggestions[d.rule.id] do %>
                  <% {:ok, output} -> %>
                    <.ai_answer answer={output} />
                  <% {:error, message} -> %>
                    <p class="lp-notice">Could not suggest a fix: {message}</p>
                  <% _ -> %>
                <% end %>
              </div>
            <% end %>
          </section>

          <section :if={@can_probe} class="lp-timeline" aria-label="Recent events">
            <p class="lp-eyebrow">Events, last 7 days</p>
            <p :if={@events == []} class="lp-hint">Nothing recorded yet.</p>
            <div :for={{day, events} <- by_day(@events)} class="lp-timeline__group">
              <h3 class="lp-timeline__day">{day}</h3>
              <ol>
                <li :for={e <- events} class={"lp-event lp-event--" <> (e["kind"] || "")}>
                  <time datetime={e["time"]}>{Format.clock(e["time"])}</time>
                  <span class="lp-event__kind">{e["kind"]}</span>
                  <code class="lp-event__subject">{e["subject"]}</code>
                  <span class={"lp-badge lp-badge--" <> Format.badge(e["change"])}>
                    {e["change"]}
                  </span>
                  <span
                    :if={(e["repeats"] || 0) > 0}
                    class="lp-event__repeats"
                    title="identical events folded into this one"
                  >
                    ×{e["repeats"]}
                  </span>
                  <p class="lp-event__message">{e["message"]}</p>
                </li>
              </ol>
            </div>
          </section>

          <div class="lp-evidence">
            <nav class="lp-list" aria-label="Fixtures">
              <.link
                :for={f <- @set.fixtures}
                patch={fixture_path(@set_param, f.id)}
                class={["lp-list__item", kind_class(Fixtures.kind(f)), @id == f.id && "is-selected"]}
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
                    <span class={["lp-chip", kind_class(Fixtures.kind(f))]}>
                      {kind_label(Fixtures.kind(f))} · exit {f.exit_code}
                    </span>
                  </header>
                  <pre class="lp-cmd"><code>$ {Enum.join(f.argv, " ")}</code></pre>
                  <div :if={@can_ai} class="lp-explain">
                    <button
                      type="button"
                      class="lp-button"
                      phx-click="explain"
                      phx-value-id={f.id}
                      disabled={@explaining == f.id}
                    >
                      {if @explaining == f.id, do: "Explaining…", else: "Explain"}
                    </button>
                    <%= case @explanations[f.id] do %>
                      <% {:ok, answer} -> %>
                        <section class="lp-ai">
                          <p class="lp-ai__label">
                            AI-generated · unscored · <code>{answer.model}</code>
                            · AI can make mistakes.
                          </p>
                          <p class="lp-ai__text">{answer.text}</p>
                        </section>
                      <% {:error, message} -> %>
                        <p class="lp-notice">Could not explain: {message}</p>
                      <% nil -> %>
                    <% end %>
                  </div>
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
      <% end %>
    </Layouts.app>
    """
  end
end
