# AGENTS.md

## Project Overview

**Equinox** is a vocal synthesis editor built in Elixir. It provides an interactive editing experience for AI singing voice synthesis, targeting desktop-class DAW-like workflows delivered through the web.

This repository is the successor to two prior prototypes:

- **Quincunx**: Validated the Orchid-based DAG kernel and intervention model.
    - Remote: [SynapticStrings/Quincunx](https://github.com/SynapticStrings/Quincunx)
- **KinoBayanroll** (Livebook Smart Cell): Validated the Svelte 5 + SvelteFlow frontend stack.
    - Remote: [GES233/kino_bayanroll](https://github.com/GES233/kino_bayanroll)
- **PoC Script**: (DiffSinger pipeline demo)
    - Remote: [simple_run.livemd](https://github.com/GES233/DiffSinger/blob/main/examples/diff_singer_model/simple_run.livemd)
    - Local: `C:/Users/Q/Downloads/simple_run.livemd`

Equinox consolidates those lessons into a single **Phoenix + Svelte** application, abandoning Livebook/Kino hosting entirely.

### Architecture Vision

```
Equinox = Kernel + DomainApp + UI
```

- **Kernel**: Incremental generation orchestration (DAG + Intervention + Incremental Generation + Heavy Services).
- **DomainApp**: Domain-specific logic for vocal synthesis (Projects, Tracks, Notes, Curves, Topologies).
- **UI**: Phoenix LiveView shell hosting Svelte 5 components (Piano Roll, Node Editor, Arranger) as islands.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->

## Project Structure

```
equinox/
├── lib/
│   ├── equinox/              # Core domain + Kernel
│   │   ├── application.ex
│   │   ├── project.ex        # Top-level session container
│   │   ├── track.ex          # Track (Context) with topology_ref
│   │   ├── editor/           # Edit actions, history
│   │   ├── session/          # Runtime session state
│   │   ├── topology/         # Topology registry + hydration
│   │   ├── kernel/           # Graph, Compiler, Engine, RecipeBundle
│   │   └── domain/           # Domain entities (Note, Slicer)
│   │
│   ├── equinox_web/          # Phoenix + Svelte shell
│   │   ├── application.ex
│   │   ├── endpoint.ex
│   │   ├── router.ex
│   │   ├── live/             # LiveView entrypoints
│   │   └── components/       # .heex + Svelte mount points
│   ├── equinox.ex
│   └── equinox_web.ex
│
├── assets/
│   ├── src/                  # Svelte 5 + TS source
│   │   ├── lib/
│   │   │   ├── stores/       # viewport.svelte.ts, node_registry.ts
│   │   │   ├── components/   # PianoRoll, NodeEditor, Arranger, ...
│   │   │   └── bridge/       # LiveView <-> Svelte transport
│   │   ├── piano_roll.ts     # Entry: Piano Roll island
│   │   ├── node_editor.ts    # Entry: Synth node editor
│   │   ├── arranger.ts       # Entry: Arranger island
│   │   └── app.ts            # Shared bootstrap + hooks
│   ├── css/
│   ├── index.html            # Vite dev entry (mock bridge)
│   ├── vite.config.ts
│   └── tsconfig.json
├── priv/static/              # Vite build output lands here
├── config/
├── AGENTS.md
└── mix.exs
```

## Essential Commands

```bash
# Elixir
mix deps.get
mix compile
mix test
mix format
iex -S mix
iex -S mix phx.server

# Frontend
npm install
npm run dev       # Vite dev server, uses mock bridge
npm run build     # Builds into priv/static
npm run check     # svelte-check + tsc
```

The Phoenix dev server should watch Vite output rather than invoke `esbuild`/`tailwind` Mix tasks directly. Configure `:watchers` in `config/dev.exs` to spawn `npm run dev` inside `assets`.

## Tech Stack

### Backend (lib/equinox)

Orchid ecosystem — workflow orchestration kernel:

- **orchid** (~> 0.6) — DAG engine.
- **orchid_symbiont** (~> 0.2) — OTP/GenServer service integration (used for heavy NIF-backed synth services).
- **orchid_stratum** (~> 0.2) — Deterministic content-addressable cache.
- **orchid_intervention** (~> 0.1) — External data injection semantics.

### Web (lib/equinox_web)

- **phoenix** (~> 1.8), **phoenix_live_view** (~> 1.1), **phoenix_html** (~> 4.1)
- **bandit** (~> 1.5), **jason**

### Frontend (assets/)

- **Svelte 5** (Runes mode) — mandatory. No Svelte 4 syntax.
- **SvelteFlow** (`@xyflow/svelte`) — node editor canvas.
- **Vite** — build tool; outputs to `priv/static`.
- **TypeScript** — strict mode.
- **Tailwind CSS v4** — via Vite plugin, not the Mix `tailwind` task.

> **No Kino, no Livebook, no LiteGraph.** These prototype dependencies are permanently retired.

## Frontend ↔ Backend Bridge

The **only** coupling between Svelte and Phoenix is a small typed interface, modeled after (and replacing) the old `KinoCtx`:

```ts
// assets/src/lib/bridge/index.ts
interface EquinoxBridge {
  root: HTMLElement;
  pushEvent<T>(name: string, payload: T): void;
  handleEvent<T>(name: string, handler: (payload: T) => void): () => void;
  // getBlob / requestBinary etc. for waveform assets
}
```

Two implementations exist:
1. **`LiveBridge`** — backed by a Phoenix LiveView Hook (`this.pushEvent`, `this.handleEvent`). Used in production.
2. **`MockBridge`** — backed by in-memory fixtures and `fetch`. Used by `npm run dev` standalone. Enables UI-only contributors to work without an Elixir toolchain.

**Svelte components receive a `bridge` prop; they must never import from `phoenix_live_view` or inspect `window.liveSocket` directly.** This discipline keeps the components portable and testable.

### Data flow
```
Svelte component
  └─ bridge.pushEvent("synth_graph_update", {nodes, edges})
      └─ LiveView Hook → LiveView handle_event/3
          └─ Equinox.Editor action → Project/Track state update
              └─ (optional) Kernel.Engine.run/2
                  └─ bridge.handleEvent("render_complete", {audio_ref})
```

## Core Domain Architecture

Inherited and simplified from Quincunx; data-driven in the Bumblebee spirit.

### 1. Data Hierarchy
- **Project / Session** — top-level container; owns tempo map, tracks, global undo/redo.
- **Track (Context)** — timeline/singer instance. Stores pure data only:
  - `topology_ref` (e.g., `"diffsinger:v1"`).
  - `model_id` / asset references (resolved at runtime).
  - `interventions` keyed by semantic UI keys.
- **Notes** — discrete events in **Ticks/Beats** (musical time), never raw ms.
- **Curves** — sparse control points (bezier / spline); rasterized to dense frames during compilation.

### 2. Topology & Package Management (Bumblebee-style)
- **Pure data persistence.** Projects never store executable closures or Orchid steps directly.
- **Registry & Hydration.** `topology_ref` → hydrates into an `Orchid.Recipe` composed strictly of `Module` steps.
- **Pluggable engines.** Third-party Hex packages may register new topologies. Assets (models, dictionaries) are resolved per-track and injected as Orchid inputs.

### 3. Translation Layer
- **Frontend speaks semantic keys** (e.g., `track_1.pitch_curve`, `track_1.acoustic.mel`).
- **Compiler** maps semantic keys ↔ Orchid `PortRef`s (`"node_id|port_name"`).
- **Interventions** collapse to exactly two kinds, mirroring `OrchidIntervention`:
  - `:input` — pre-execution initialization (e.g., notes → sequencer input).
  - `:output` — post-execution override / mix (e.g., user-painted pitch curve masks predicted pitch).

### 4. Topology Tearing (Runtime Optimization)
- **Data declaration ≠ runtime declaration.** The DAG shape is portable data; hardware strategies (cluster partitioning, Symbiont NIF teardown between batches to reclaim VRAM, laptop vs. workstation profiles) are a **compilation phase** applied when producing the final Orchid Recipe.

### 5. History
- Global undo/redo lives at the Session/Editor level, not per-segment. Designed to accommodate future OT/CRDT collaborative editing.

## Timing Model (SVS-Specific)

Three timing perspectives must be respected throughout the pipeline:

1. **Musical Time (Ticks / Beats)** — canonical storage, tempo-independent. Use `480` or `1920` ticks per beat.
2. **Acoustic Frames** — discrete NN steps, typically ~10ms or 12.5ms. Produced by rasterizing curves against the tempo map + frame rate.
3. **Audio Samples** — final waveform (44.1 / 48 kHz).

Conversions happen inside the Kernel/Compiler, never in Svelte.

## UI Shell Layout

The app presents a DAW-style window (see effect mockup). Major regions:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                                     Equinox                                          │
│ File  Edit                                                       Status  Help  About │
│                                                                                      │
├─────┬────┬─────────────────────────────────────────────────┬─────────────────────────┤
│     │    │┌─────┐ ┌──────┐ ┌──────────┐      Track Overview│    Arranger             │
│      M S │└─────┘ └──────┘ └──────────┘     (Determine how │                         │
├─────┬────┼──────────────────────────────────   track slice)│   ┌───┐                 │
│     │    │           ┌──────┐                              │   │#Sy│                 │
│      M S │           └──────┘                              │   │   ├────────────┐    │
├─────┬────┼─────────────────────────────────────────────────┤   │   │            │    │
│     │    │                                                 │   └───┘            │    │
│      M S ├──(present waveform here...)─────────────────────┤                    │    │
├────────┬─┴─────────────────────────────────────────────────┤   ┌───┐            ▼    │
│        │                                          PianoRoll│   │#Sy│          ┌─────┐│
│▌▌▌▌▌───┤                                                   │   │   ├─────────►│     ││
│        │                                                   │   │   │    ┌────►│     ││
│▌▌▌▌▌───┤                                                   │   └───┘    │ ┌──►│     ││
│        │                                                   │            │ │   │     ││
├────────┤           ┌───────────┐                           │   ┌───┐    │ │   └─────┘│
│        │           │           │                           │   │#Au│    │ │          │
│▌▌▌▌▌───┤      ┌───┐└───────────┘┌───┐                      │   │   ├────┘ │          │
│        │      │   │ he-   re    │   │                      │   │   │      │          │
│▌▌▌▌▌───┤ ┌───┐└───┘             └───┘                      │   └───┘      │          │
│        │ │   │ me                the                       │   ┌───┐      │          │
│▌▌▌▌▌───┤ └───┘                                             │   │   │      │          │
│        │  Let                                              │   │   ├──────┘          │
├────────┤                             ┌────────────────────┐│   │   │                 │
│        │                             │                    ││   └───┘                 │
│▌▌▌▌▌───┤                             └────────────────────┘│                         │
│        │                              soun-        -d      │    ...           Swelte │
│▌▌▌▌▌───┤                                                   │   ┌────┐          Flow  │
│        │                                                   │   │    │                │
└────────┴───────────────────────────────────────────────────┴───┴────┴────────────────┘
```

- **TrackList** — mute/solo/volume per track; vertical stack.
- **TrackOverview** — horizontal strip above Piano Roll showing slice boundaries decided by the Slicer node.
- **PianoRoll** — primary editing surface. Hybrid rendering (see below).
- **Arranger** — a second SvelteFlow canvas for mixing / offsets / multiple Synth outputs → final master.

A separate route hosts the **Synthesizer Node Editor** (per-track deep-edit view). Its topology mirrors the DiffSinger-family pipeline:

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                                             │
│                                           Syntheziser Node Editor                                           │
│                                                                                                             │
├─────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│    ┌───────────┐                                                                                            │
│    │Extra pitch│                                                                                            │
│    │ (Optional)├─────────────────────────┐    ┌─────────────────────────────┐                               │
│    │           │       ┌─────────────┐   │    │  Acoustic Model             │                               │
│    └───────────┘       │  Duration   │   │    ├─────────────────────────────┤                               │
│                        │ Prediction  │   │    │ *present mel spectrum       │                               │
│                      ┌►│             │   │    │   within current calc       │                               │
│                      │ │             │   │    │   transaction               │                               │
│                      │ │             │   │    │                             │                               │
│                      │ └─────────┬───┘   │    │                             │                               │
│                      │           │       │    │                             │                               │
│  ┌─────────────────┐ │┌──────────┤       │    │                             │                               │
│  │Note(with lyrics)│ ││          │       │    │                             │                               │
│  │   (required)    │ ││          ▼       ▼    │            /=\ ----         ├────┐                          │
│  │                 ▌─┤│ ┌─────────────┐┌───┐  │    /====\  /=\ ----         │    │                          │
│  │                 │ ││ │   Pitch     ││ M │  │    /----\  /=\ ----         │    │                          │
│  └─────────────────┘ ││ │ Prediction  ││ A │  │                             │    │                          │
│                      ├┼►│             ││ S │  └─────────────────────────────┘    │                          │
│                      ││ │             ││ K │                ▲                    │                          │
│                      ││ │             ││   │                │                    │                          │
│                      ││ └─────────────┘└─┬─┘                │                    │                          │
│                      ││                  │                  │                    │                          │
│                      │└────────┐         │Masked pitch      │                    ▼                          │
│                      │         ▼         │(partial override)│      ┌────────────────┐  ┌──────────────────┐ │
│   ┌────────────────┐ │ ┌──────────────┐  │                  │      │    Vocoder     │  │    Waveform      │ │
│   │   breathness,  │ │ │  Variance    │  │                  │      │                ├─►▌ (required node)  │ │
│   │   gender,      │ │ │   Model      │  │                  │      └────────────────┘  │                  │ │
│   │   ...          │ └►│              │  │                  │              ▲           └──────────────────┘ │
│   │                ├──►│              │◄─┴──────────────────┴──────────────┘                                │
│   │Extra Parameters│   │              │                                                                     │
│   │ (based on conf)│   └──────────────┘                                                                     │
│   └────────────────┘                                                                                        │
│                                                                                                             │
│                                                                                                             │
│                                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Users connect/disconnect ports; the Compiler validates against topology contracts.

## Piano Roll Architecture

- **Grid**: CSS `repeating-linear-gradient` bound to the `Viewport` rune store.
- **Notes**: absolute-positioned `<div>`s with viewport culling.
- **Curves**: SVG `<path>` (cubic beziers) with sparse control points.
- **Slicer overlay**: translucent vertical bands over the entire roll, sourced from backend slice computation.
- **Waveform overlay**: background `<canvas>` rendering stems / rendered audio.
- **Viewport**: a single Svelte 5 class (`Viewport`) managing `zoomX` (ms→px), `zoomY` (semitone→px), unbounded pan, and 30° angle-lock for pan/zoom gestures (inherited from KinoBayanroll).

### Interactions
- Double-click empty → add note.
- Double-click note → delete.
- Drag body → move (X/Y).
- Drag right edge → resize.
- TODO: inline lyric input (replace legacy `prompt()`), marquee/lasso multi-select.

## Code Conventions

### Elixir

- Return `{:ok, value}` / `{:error, reason}` from public APIs.
    - For some function can be chained.
- `@spec` on public functions.
- Pattern-match in heads; use `with` for ROP chains.
- `mix format` is law.
- Comments in Chinese are acceptable; **doc strings (`@doc`, `@moduledoc`) in Chinese are encouraged** for domain modules.
- Public-API names start with verbs: `create_`, `update_`, `list_`, `render_`, `compile_`.

### Svelte / TS

- **Svelte 5 Runes only** (`$state`, `$derived`, `$effect`, `$props`). No stores from `svelte/store` unless wrapping an external lib.
- `strict: true` in `tsconfig.json`.
- Components receive `bridge: EquinoxBridge` as a prop; never reach into globals.
- File-level CSS is scoped; shared utilities go through Tailwind.

### SvelteFlow

- **Do not use reserved `nodeTypes` names** like `input` / `output` — SvelteFlow silently injects styles. Use `custom_input` / `output_with_panel` etc.
- Keep node components under `assets/src/lib/components/node/`. `DynamicNode.svelte` is the fallback for step types not yet given a bespoke renderer.
- External packages register custom nodes via `registerNodeType(stepName, Component)` from `lib/stores/node_registry.ts`.

### Tailwind CSS v4

- `!` modifier goes at the **end**: `bg-amber-500!`, not `!bg-amber-500`.
- Gradients: `bg-linear-to-b`, not `bg-gradient-to-b`.
- Prefer the spacing scale (`min-w-55`) over arbitrary values (`min-w-[220px]`).

## Kernel Modules

Naming convention inside `lib/equinox/kernel/`:

| Module | Responsibility | Ancestor |
|---|---|---|
| `Equinox.Kernel.Graph` | `%Node{}`, `%Edge{}`, `%PortRef{}`, topological sort, cycle detection | Quincunx.Topology.Graph |
| `Equinox.Kernel.Compiler` | Graph → `RecipeBundle`; applies topology-tearing passes | Quincunx.Compiler.GraphBuilder |
| `Equinox.Kernel.RecipeBundle` | `{recipe, requires, exports, node_ids, interventions}` | Quincunx.Compiler.RecipeBundle |
| `Equinox.Kernel.Engine` | `run(bundle, interventions)` → `Orchid.run/3`; emits progress via PubSub | Quincunx.Renderer.Worker |
| `Equinox.Kernel.StepRegistry` | Dynamic step registration (built-in + third-party packages) | KinoBayanroll.StepRegistry |

Port key format stays `"node_id|port_name"` for interop with existing Orchid recipes.

## Testing

- Backend: ExUnit, doctests on pure functions, context-level tests for `Equinox.Editor` actions.
- Frontend: `svelte-check` + `vitest` for stores (especially `Viewport`, `node_registry`).
- E2E: deferred until LiveView shell stabilizes.

## Working Notes for Agents

- **When adding a new step type**: (1) register in `Equinox.Kernel.StepRegistry`, (2) expose its ports through the topology package, (3) optionally provide a bespoke Svelte node component — otherwise `DynamicNode` renders it.
- **When touching the bridge interface**: update both `LiveBridge` and `MockBridge` in the same change. The `MockBridge` is the contract.
- **When in doubt about Windows friendliness**: prefer pure-Elixir / pure-JS solutions over native bindings. If a NIF is required, isolate it behind `orchid_symbiont` so it can be torn down and restarted.
- **Do not reintroduce** `KinoCtx`, `to_source/1`, `broadcast_event/3`-style Kino plumbing, `KinoBayanroll.Registry`, or any Livebook Smart Cell hook. They are archaeology.
- **Reference prototypes** (read-only):
  - `D:/CodeRepo/Qy/Quincunx` — kernel reference.
  - KinoBayanroll codebase — Svelte component reference.
  - `C:/Users/Q/Downloads/simple_run.livemd` — DiffSinger pipeline PoC.

## Current Milestones

1. **M0 — Skeleton**: Umbrella scaffolded, Vite ↔ Phoenix wiring verified on Windows, `MockBridge` + `LiveBridge` both render an empty PianoRoll.
2. **M1 — Piano Roll parity**: Port notes/viewport/grid/slicer overlay from KinoBayanroll.
3. **M2 — Node Editor parity**: SvelteFlow-based Synth editor, StepRegistry-driven palette, graph persistence via `Equinox.Project`.
4. **M3 — Kernel integration**: End-to-end render (Note → DiffSinger recipe → Vocoder → Waveform) using Orchid.
5. **M4 — Arranger**: Second SvelteFlow canvas, multi-track mix, slice alignment.
6. **M5 — Curves**: SVG bezier layer + rasterization in the Compiler.
7. **M6 — History & Collaboration hooks**: Session-level undo/redo; design space for future CRDT.

## Agent Work Log

### 2026-04-17 (M0/M1 Data Architecture)
- **Restructured Core Domain (Pure Data)**: Removed Ecto schemas from `Equinox.Project`, `Equinox.Editor.Track`, `Equinox.Editor.Segment`. Converted them to strictly JSON-serializable pure Elixir structs using `Jason.Encoder`.
- **Global History & Clean Segments**: Explicitly removed `history` from `Segment` (history will be managed at the Project/Editor level). `Segment` no longer serializes its runtime `graph` or `cluster`, retaining only `notes` and `curves` (Pure Data) for storage and hash calculation.
- **Project Serialization**: Added symmetric `Project.to_json/1` and `Project.from_json/1` for full recursive hydration of `project.json` in the bundle architecture.
- **App Structure Fix**: Removed the incorrect `apps/` umbrella folder convention and aligned `AGENTS.md` with the actual standard Phoenix structure (`lib/equinox`, `lib/equinox_web`).

### 2026-04-17 (M2 Bridge Protocol & Hydration)
- **TypeScript Bridge Types**: Added explicit `ProjectData`, `TrackData`, `SegmentData`, `NoteData` interfaces to `assets/src/lib/bridge/index.ts` to mirror Elixir Pure Data exactly.
- **Svelte State Hydration**: Refactored `PianoRoll.svelte` to listen for the `project_load` event via `LiveBridge`. Svelte now successfully parses the backend project payload, derives the active track/segment, and renders the backend notes on the canvas.
- **Bi-directional Editing Skeleton**: Implemented `handle_event` callbacks in `EquinoxWeb.EditorLive` (`add_note`, `update_note`, `delete_note`) ready to be wired up to `Equinox.Editor` state mutations.
- **Editor Actions Skeleton**: Built `Equinox.Editor` module. Implemented `add_note/4`, `update_note/5`, and `delete_note/4` as pure functional transformations over the nested `Equinox.Project` structure.
