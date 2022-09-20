defmodule PhxLiveStorybook.Story.Playground do
  @moduledoc false
  use PhxLiveStorybook.Web, :live_component

  alias Phoenix.{LiveView.JS, PubSub}
  alias PhxLiveStorybook.Attr
  alias PhxLiveStorybook.ComponentStory
  alias PhxLiveStorybook.Rendering.CodeRenderer
  alias PhxLiveStorybook.Story.PlaygroundPreviewLive
  alias PhxLiveStorybook.TemplateHelpers
  alias PhxLiveStorybook.{Variation, VariationGroup}

  import PhxLiveStorybook.NavigationHelpers

  def mount(socket) do
    {:ok, assign(socket, event_logs: [])}
  end

  def update(%{new_event: event}, socket) do
    {:ok, update(socket, :event_logs, &[event | &1])}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_variations()
     |> assign_new_variations_attributes(assigns)
     |> assign_new_template_attributes(assigns)
     |> assign_playground_fields()
     |> assign_playground_block()
     |> assign_playground_slots()
     |> assign_new(:upper_tab, fn -> :preview end)
     |> assign_new(:lower_tab, fn -> :attributes end)}
  end

  defp assign_variations(socket = %{assigns: assigns}) do
    case assigns.variation do
      variation = %Variation{} ->
        assign_variations(socket, variation.id, [variation])

      %VariationGroup{id: group_id, variations: variations} ->
        assign_variations(socket, group_id, variations)

      _ ->
        assign_variations(socket, nil, [])
    end
  end

  defp assign_variations(socket = %{assigns: %{variation_id: id}}, id, _variations) do
    socket
  end

  defp assign_variations(socket, id, variations) do
    socket
    |> assign(variation_id: id)
    |> assign(
      :variations,
      for(s <- variations, do: Map.take(s, [:id, :attributes, :let, :block, :slots, :template]))
    )
  end

  # new_attributes may be passed by parent (LiveView) send_update.
  # It happens whenever parent is notified some component assign has been
  # updated by the component itself.
  defp assign_new_variations_attributes(socket, assigns) do
    new_attributes = Map.get(assigns, :new_variations_attributes, %{})

    variations =
      for variation <- socket.assigns.variations do
        case Map.get(new_attributes, variation.id) do
          nil -> variation
          new_attrs -> update_variation_attributes(variation, new_attrs)
        end
      end

    assign(socket, variations: variations)
  end

  defp assign_new_template_attributes(socket, assigns) do
    current_attributes = Map.get(socket.assigns, :template_attributes, %{})
    new_attributes = Map.get(assigns, :new_template_attributes, %{})

    template_attributes =
      for {variation_id, new_variation_attrs} <- new_attributes, reduce: current_attributes do
        acc ->
          current_attrs = Map.get(acc, variation_id, %{})
          new_variation_attrs = Map.merge(current_attrs, new_variation_attrs)
          Map.put(acc, variation_id, new_variation_attrs)
      end

    assign(socket, template_attributes: template_attributes)
  end

  defp assign_playground_fields(socket = %{assigns: %{story: story, variations: variations}}) do
    fields =
      for attr = %Attr{type: t} <- story.attributes, t not in ~w(block slot)a, reduce: %{} do
        acc ->
          attr_examples = for %{attributes: attrs} <- variations, do: Map.get(attrs, attr.id)

          field =
            case Enum.uniq(attr_examples) do
              [] -> nil
              [val] -> val
              _ -> :locked
            end

          Map.put(acc, attr.id, field)
      end

    assign(socket, :fields, fields)
  end

  defp assign_playground_block(socket = %{assigns: %{variations: variations}}) do
    blocks = for variation <- variations, do: variation.block

    block =
      if blocks |> Enum.uniq() |> length() == 1 do
        hd(blocks)
      else
        :locked
      end

    assign(socket, :block, block)
  end

  defp assign_playground_slots(socket = %{assigns: %{story: story, variations: variations}}) do
    slots =
      for %Attr{type: :slot, id: attr_id} <- story.attributes, reduce: %{} do
        acc ->
          slots =
            for variation <- variations do
              for(slot <- variation.slots, String.match?(slot, ~r/^<:#{attr_id}[>\s]/), do: slot)
              |> Enum.map_join("\n", &String.trim/1)
              |> String.trim()
            end

          slot =
            if slots |> Enum.uniq() |> length() == 1 do
              hd(slots)
            else
              :locked
            end

          Map.put(acc, attr_id, slot)
      end

    assign(socket, :slots, slots)
  end

  def render(assigns) do
    ~H"""
    <div id="playground" class="lsb lsb-flex lsb-flex-col lsb-flex-1">
      <%= render_upper_navigation_tabs(assigns) %>
      <%= render_upper_tab_content(assigns) %>
      <%= render_lower_navigation_tabs(assigns) %>
      <%= render_lower_tab_content(assigns) %>
    </div>
    """
  end

  defp render_upper_navigation_tabs(assigns) do
    tabs = [{:preview, "Preview", "fad fa-eye"}, {:code, "Code", "fad fa-code"}]

    ~H"""
    <div class="lsb lsb-border-b lsb-border-gray-200 lsb-mb-6">
      <nav class="lsb -lsb-mb-px lsb-flex lsb-space-x-8">
        <%= for {tab, label, icon} <- tabs do %>
          <a href="#" phx-click="upper-tab-navigation" phx-value-tab={tab} phx-target={@myself}
            class={"lsb #{active_link(@upper_tab, tab)} lsb-whitespace-nowrap lsb-py-4 lsb-px-1 lsb-border-b-2 lsb-font-medium lsb-text-sm"}>
            <i class={"lsb #{active_link(@upper_tab, tab)} #{icon} lsb-pr-1"}></i>
            <%= label %>
          </a>
        <% end %>
      </nav>
    </div>
    """
  end

  defp render_lower_navigation_tabs(assigns) do
    ~H"""
    <div class="lsb lsb-border-b lsb-border-gray-200 lsb-mt-6 md:lsb-mt-12 lsb-mb-6">
      <nav class="lsb -lsb-mb-px lsb-flex lsb-space-x-8">
        <%= for {tab, label, icon} <- [{:attributes, "Attributes", "fad fa-list"}, {:events, "Event Logs", "fad fa-book"}] do %>
          <a href="#" phx-click="lower-tab-navigation" phx-value-tab={tab} phx-target={@myself} class={"lsb #{active_link(@lower_tab, tab)} lsb-whitespace-nowrap lsb-py-4 lsb-px-1 lsb-border-b-2 lsb-font-medium lsb-text-sm"}>
            <i class={"lsb  #{active_link(@lower_tab, tab)} #{icon} lsb-pr-1"}></i>
            <%= label %>
            <%= event_counter(tab, Enum.count(@event_logs)) %>
          </a>
        <% end %>
      </nav>
    </div>
    """
  end

  defp active_link(same_tab, same_tab), do: "lsb lsb-border-indigo-500 lsb-text-indigo-600"

  defp active_link(_current_tab, _tab) do
    "lsb lsb-border-transparent lsb-text-gray-500 hover:lsb-text-gray-700 hover:lsb-border-gray-300"
  end

  defp event_counter(:events, count) when count > 0, do: "(#{count})"
  defp event_counter(_, _), do: nil

  defp render_upper_tab_content(assigns = %{upper_tab: _tab}) do
    ~H"""
    <div class={"lsb lsb-relative"}>
      <div class={"lsb lsb-min-h-32 lsb-border lsb-border-slate-100 lsb-rounded-md lsb-col-span-5 lg:lsb-col-span-2 lg:lsb-mb-0 lsb-flex lsb-items-center lsb-justify-center lsb-px-2 lsb-bg-white lsb-shadow-sm #{if @upper_tab != :preview, do: "lsb-hidden"}"}>
        <%= if @story.container() == :iframe do %>
          <iframe
            id={playground_preview_id(@story)}
            src={live_storybook_path(@socket, :story_iframe, @story_path,
                variation_id: inspect(@variation_id), theme: @theme, playground: true,
                topic: @topic)}
            height="128"
            class="lsb-w-full lsb-border-0"
            onload="javascript:(function(o){ var height = o.contentWindow.document.body.scrollHeight; if (height > o.style.height) o.style.height=height+'px'; }(this));"
          />
        <% else %>
          <%= live_render @socket, PlaygroundPreviewLive,
                id: playground_preview_id(@story),
                session: %{
                  "story_path" => @story_path,
                  "variation_id" => @variation_id,
                  "theme" => @theme,
                  "backend_module" => to_string(@backend_module),
                  "topic" => "playground-#{inspect(self())}",
                },
                container: {:div, style: "height: 100%; width: 100%;"}
          %>
        <% end %>
      </div>
      <%= if @upper_tab == :code do %>
        <div class="lsb lsb-relative lsb-group lsb-border lsb-border-slate-100 lsb-rounded-md lsb-col-span-5 lg:lsb-col-span-2 lg:lsb-mb-0 lsb-flex lsb-items-center lsb-px-2 lsb-min-h-32 lsb-bg-slate-800 lsb-shadow-sm">
          <div phx-click={JS.dispatch("lsb:copy-code")} class="lsb lsb-hidden group-hover:lsb-block lsb-bg-slate-700 lsb-text-slate-500 hover:lsb-text-slate-100 lsb-z-10 lsb-absolute lsb-top-2 lsb-right-2 lsb-px-2 lsb-py-1 lsb-rounded-md lsb-cursor-pointer">
            <i class="lsb fa fa-copy lsb-text-inherit"></i>
          </div>
          <.playground_code story={@story} variation={@variation} variations={@variations}/>
        </div>
      <% end %>
      <%= if @playground_error do %>
        <% error_bg = if @upper_tab == :code, do: "lsb-bg-slate/20", else: "lsb-bg-white/20" %>
        <div class={"lsb lsb-absolute lsb-inset-2 lsb-z-10 lsb-backdrop-blur-lg lsb-text-red-600 #{error_bg} lsb-rounded lsb-flex lsb-flex-col lsb-justify-center lsb-items-center lsb-space-y-2"}>
          <i class="lsb fad fa-xl fa-bomb lsb-text-red-600"></i>
          <span class="lsb lsb-drop-shadow lsb-font-medium">Ohoh, I just crashed!</span>
          <button phx-click="clear-playground-error" class="lsb lsb-inline-flex lsb-items-center lsb-px-2 lsb-py-1 lsb-border lsb-border-transparent lsb-text-xs lsb-font-medium lsb-rounded lsb-shadow-sm lsb-text-white lsb-bg-red-600 hover:lsb-bg-red-700 focus:lsb-outline-none focus:lsb-ring-2 focus:lsb-ring-offset-2 focus:lsb-ring-red-500">
            Dismiss
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  defp playground_code(assigns) do
    ~H"""
    <pre class={CodeRenderer.pre_class()}>
    <%= CodeRenderer.render_multiple_variations_code(fun_or_component(@story), @variations, TemplateHelpers.get_template(@story.template, @variation)) %>
    </pre>
    """
  end

  defp render_lower_tab_content(assigns = %{lower_tab: :events}) do
    ~H"""
    <div id={playground_event_logs_id(@story)} class="lsb lsb-flex lsb-flex-col lsb-mb-8">
      <div class="lsb lsb-overflow-x-auto md:-lsb-mx-8">
        <div class="lsb lsb-inline-block lsb-min-w-full lsb-py-2 lsb-align-middle md:lsb-px-8">
          <%= for {event_log, index} <- Enum.with_index(@event_logs) do %>
            <.event_log id={playground_event_log_id(@story, index)} event_log={event_log} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp render_lower_tab_content(assigns = %{lower_tab: :attributes}) do
    ~H"""
    <.form for={:playground} let={f} id={form_id(@story)} phx-change={"playground-change"} phx-target={@myself} class="lsb-text-gray-600 ">
      <div class="lsb lsb-flex lsb-flex-col lsb-mb-2">
        <div class="lsb lsb-overflow-x-auto md:-lsb-mx-8">
          <div class="lsb lsb-inline-block lsb-min-w-full lsb-py-2 lsb-align-middle md:lsb-px-8">
            <div class="lsb lsb-overflow-hidden lsb-shadow lsb-ring-1 lsb-ring-black lsb-ring-opacity-5 md:lsb-rounded-lg">
              <table class="lsb lsb-min-w-full lsb-divide-y lsb-divide-gray-300">
                <thead class="lsb lsb-bg-gray-50">
                  <tr>
                    <%= for {header, th_style, span_style} <- [{"Attribute", "lsb-pl-3 md:lsb-pl-9", "lsb-w-8 md:lsb-w-auto"}, {"Type", "", ""}, {"Documentation", "", ""}, {"Default", "lsb-hidden md:lsb-table-cell", ""}, {"Value", "", ""}] do %>
                      <th scope="col" class={"lsb #{th_style} lsb-py-3.5 lsb-text-left lsb-text-xs md:lsb-text-sm lsb-font-semibold lsb-text-gray-900"}>
                        <span class={"lsb #{span_style} lsb-truncate lsb-inline-block"}><%= header %></span>
                      </th>
                    <% end %>
                  </tr>
                </thead>
                <tbody class="lsb lsb-divide-y lsb-divide-gray-200 lsb-bg-white">
                  <%= if Enum.empty?(@story.attributes) do %>
                  <tr>
                    <td colspan="5" class="lsb md:lsb-px-3 md:lsb-px-6 lsb-py-4 lsb-text-md md:lsb-text-lg lsb-font-medium lsb-text-gray-500 sm:lsb-pl-6 lsb-pt-2 md:lsb-pb-6 md:lsb-pt-4 md:lsb-pb-12 lsb-text-center">
                      <i class="lsb lsb-text-indigo-400 fad fa-xl fa-circle-question lsb-py-4 md:lsb-py-6"></i>
                      <p>In order to use playground, you must define attributes in your <code class="lsb-font-bold"><%= @story.name %></code> story.</p>
                    </td>
                  </tr>
                  <% else %>
                    <%= for attr <- @story.attributes, attr.type not in [:block, :slot] do %>
                      <tr>
                        <td class="lsb lsb-whitespace-nowrap md:lsb-pr-3 md:lsb-pr-6 lsb-pl-3 md:lsb-pl-9 lsb-py-4 lsb-text-xs md:lsb-text-sm lsb-font-medium lsb-text-gray-900 sm:lsb-pl-6">
                          <%= if attr.required do %>
                            <.required_badge/>
                          <% end %>
                          <%= attr.id %>
                          <%= if attr.required do %>
                            <span class="lsb lsb-inline md:lsb-hidden lsb-text-indigo-600 lsb-text-sm lsb-font-bold -lsb-ml-0.5">*</span>
                          <% end %>
                        </td>
                        <td class="lsb lsb-whitespace-nowrap lsb-py-4 md:lsb-pr-3 lsb-text-xs md:lsb-text-sm lsb-text-gray-500">
                          <.type_badge type={attr.type}/>
                        </td>
                        <td class="lsb lsb-whitespace-pre-line lsb-py-4 md:lsb-pr-3 lsb-text-xs md:lsb-text-sm lsb-text-gray-500 lsb-max-w-[16rem]"><%= if attr.doc, do: String.trim(attr.doc) %></td>
                        <td class="lsb lsb-whitespace-nowrap lsb-py-4 md:lsb-pr-3 lsb-text-sm lsb-text-gray-500 lsb-hidden md:lsb-table-cell">
                          <span class="lsb lsb-rounded lsb-px-2 lsb-py-1 lsb-font-mono lsb-text-xs md:lsb-text-sm"><%= unless is_nil(attr.default), do: inspect(attr.default) %></span>
                        </td>
                        <td class="lsb lsb-whitespace-nowrap lsb-pr-3 lsb-lsb-py-4 lsb-text-sm lsb-font-medium">
                          <.maybe_locked_attr_input form={f} attr_id={attr.id} type={attr.type}
                            fields={@fields} examples={attr.examples} values={attr.values} myself={@myself}
                            template_attributes={Map.get(@template_attributes, @variation.id, %{})}
                          />
                        </td>
                      </tr>
                    <% end %>
                    <%= for attr <- @story.attributes, attr.type in [:block, :slot] do %>
                      <tr>
                        <td class="lsb lsb-whitespace-nowrap md:lsb-pr-3 md:lsb-pr-6 lsb-pl-3 md:lsb-pl-9 lsb-py-4 lsb-text-sm lsb-font-medium lsb-text-gray-900 sm:lsb-pl-6">
                          <%= if attr.required do %>
                            <.required_badge/>
                          <% end %>
                          <%= attr.id %>
                          <%= if attr.required do %>
                            <span class="lsb lsb-inline md:lsb-hidden lsb-text-indigo-600 lsb-text-sm lsb-font-bold -lsb-ml-0.5">*</span>
                          <% end %>
                        </td>
                        <td class="lsb lsb-whitespace-nowrap lsb-py-4 md:lsb-pr-3 lsb-text-xs md:lsb-text-sm  lsb-text-gray-500">
                          <.type_badge type={attr.type}/>
                        </td>
                        <td colspan="3" class="lsb lsb-whitespace-pre-line lsb-py-4 md:lsb-pr-3 lsb-text-xs md:lsb-text-sm  lsb-text-gray-500"><%= if attr.doc, do: String.trim(attr.doc) %></td>
                      </tr>
                      <%= if block_or_slot?(assigns, attr) do %>
                        <tr class="lsb !lsb-border-t-0">
                          <td colspan="5" class="lsb lsb-whitespace-nowrap lsb-pl-3 md:lsb-pl-9 lsb-pr-3 lsb-pb-3 lsb-text-xs md:lsb-text-sm lsb-font-medium lsb-text-gray-900">
                            <pre class="lsb lsb-text-gray-600 lsb-p-2 lsb-border lsb-border-slate-100 lsb-rounded-md lsb-bg-slate-100 lsb-overflow-x-scroll lsb-whitespace-pre-wrap lsb-break-normal lsb-flex-1"><%= block_or_slot(assigns, attr) %></pre>
                          </td>
                        </tr>
                      <% end %>
                    <% end %>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </.form>
    <%= unless Enum.empty?(@story.attributes) do %>
      <.form let={f} for={:variation} id="variation-selection-form" class="lsb lsb-flex lsb-flex-col md:lsb-flex-row lsb-space-y-1 md:lsb-space-x-2 lsb-justify-end lsb-w-full lsb-mb-6">
        <%= label f, :variation_id, "Open a variation", class: "lsb lsb-text-gray-400 lsb-text-xs md:lsb-text-sm lsb-self-end md:lsb-self-center" %>
        <%= select f, :variation_id, variation_options(@story), "phx-change": "set-variation", "phx-target": @myself,
            class: "lsb lsb-form-select lsb-text-gray-600 lsb-pr-10 lsb-py-1 lsb-border-gray-300 focus:lsb-outline-none focus:lsb-ring-indigo-600 focus:lsb-border-indigo-600 lsb-text-xs md:lsb-text-sm lsb-rounded-md",
            value: @variation_id %>
      </.form>
    <% end %>
    """
  end

  defp render_lower_tab_content(_), do: ""

  defp event_log(assigns) do
    ~H"""
    <code class="lsb" id={@id}>
      <div class="lsb-flex lsb-items-center">
        <span class="lsb-uncollapse lsb-mr-1" phx-click={show_event_details(@id)}>
          <i class="fad fa-caret-right" />
        </span>

        <span class="lsb-collapse lsb-mr-1 lsb-hidden" phx-click={hide_event_details(@id)}>
          <i class="fad fa-caret-down" />
        </span>

        <div>
          <span class="lsb-text-gray-500"><%= @event_log.time |> Time.truncate(:second) |> Time.to_iso8601() %> </span>
          <span class="lsb-text-indigo-600"><%= @event_log.type %> </span>
          <span class="lsb-text-orange-400 lsb-italic">event: <span class="lsb-text-gray-400"><%= @event_log.event %> </span></span>
        </div>
      </div>

      <div class="lsb-details lsb-hidden lsb-pl-3">
        <%= for {key, value} <- Map.from_struct(@event_log) do %>
          <div>
            <span class="lsb-text-indigo-600"><%= key %>:</span>
            <span class="lsb-text-gray-500"><%= inspect(value) %></span>
          </div>
        <% end %>
      </div>
    </code>
    """
  end

  defp show_event_details(id) do
    %JS{}
    |> JS.hide()
    |> JS.show(to: "##{id} .lsb-collapse")
    |> JS.show(to: "##{id} .lsb-details")
  end

  defp hide_event_details(id) do
    %JS{}
    |> JS.hide()
    |> JS.show(to: "##{id} .lsb-uncollapse")
    |> JS.hide(to: "##{id} .lsb-details")
  end

  defp required_badge(assigns) do
    ~H"""
    <span class="lsb lsb-hidden md:lsb-inline lsb-group lsb-relative -lsb-ml-[1.85em] lsb-pr-2">
      <i class="lsb lsb-text-indigo-400 hover:lsb-text-indigo-600 lsb-cursor-pointer fad fa-circle-dot"></i>
      <span class="lsb lsb-hidden lsb-absolute lsb-top-6 group-hover:lsb-block lsb-z-50 lsb-mx-auto lsb-text-xs lsb-text-indigo-800 lsb-bg-indigo-100 lsb-rounded lsb-px-2 lsb-py-1">
        Required
      </span>
    </span>
    """
  end

  def block_or_slot?(assigns, _attr = %{type: :block}) do
    case assigns.block do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  def block_or_slot?(assigns, _attr = %{type: :slot, id: slot_id}) do
    case Map.get(assigns.slots, slot_id) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  def block_or_slot(assigns, _attr = %{type: :block}) do
    case assigns.block do
      :locked -> "[Multiple examples]"
      block -> block
    end
  end

  def block_or_slot(assigns, _attr = %{type: :slot, id: slot_id}) do
    case Map.get(assigns.slots, slot_id) do
      :locked -> "[Multiple examples]"
      slot -> slot
    end
  end

  defp form_id(story) do
    module = story.module |> Macro.underscore() |> String.replace("/", "_")
    "#{module}-playground-form"
  end

  defp playground_preview_id(story) do
    module = story.module |> Macro.underscore() |> String.replace("/", "_")
    "#{module}-playground-preview"
  end

  defp playground_event_logs_id(story) do
    module = story.module |> Macro.underscore() |> String.replace("/", "_")
    "#{module}-playground-event-logs"
  end

  defp playground_event_log_id(story, index) do
    module = story.module |> Macro.underscore() |> String.replace("/", "_")
    "#{module}-playground-event-log-#{index}"
  end

  defp variation_options(story) do
    for variation <- story.variations do
      label =
        if variation.description,
          do: variation.description,
          else: variation.id |> to_string() |> String.capitalize() |> String.replace("_", " ")

      {label, variation.id}
    end
  end

  defp type_badge(assigns = %{type: :string}) do
    ~H"""
    <span class={"lsb-bg-slate-100 lsb-text-slate-800 #{type_badge_class()}"}><%= type_label(@type) %></span>
    """
  end

  defp type_badge(assigns = %{type: :atom}) do
    ~H"""
    <span class={"lsb-bg-blue-100 lsb-text-blue-800 #{type_badge_class()}"}><%= type_label(@type) %></span>
    """
  end

  defp type_badge(assigns = %{type: :boolean}) do
    ~H"""
    <span class={"lsb-bg-slate-500 lsb-text-white #{type_badge_class()}"}><%= type_label(@type) %></span>
    """
  end

  defp type_badge(assigns = %{type: :integer}) do
    ~H"""
    <span class={"lsb-bg-green-100 lsb-text-green-800 #{type_badge_class()}"}><%= type_label(@type) %></span>
    """
  end

  defp type_badge(assigns = %{type: :float}) do
    ~H"""
    <span class={"lsb-bg-teal-100 lsb-text-teal-800 #{type_badge_class()}"}><%= type_label(@type) %></span>
    """
  end

  defp type_badge(assigns = %{type: :map}) do
    ~H"""
    <span class={"lsb-bg-fuchsia-100 lsb-text-fuchsia-800 #{type_badge_class()}"}><%= type_label(@type) %></span>
    """
  end

  defp type_badge(assigns = %{type: :list}) do
    ~H"""
    <span class={"lsb-bg-purple-100 lsb-text-purple-800 #{type_badge_class()}"}><%= type_label(@type) %></span>
    """
  end

  defp type_badge(assigns = %{type: :block}) do
    ~H"""
    <span class={"lsb-bg-pink-100 lsb-text-pink-800 #{type_badge_class()}"}><%= type_label(@type) %></span>
    """
  end

  defp type_badge(assigns = %{type: :slot}) do
    ~H"""
    <span class={"lsb-bg-rose-100 lsb-text-rose-800 #{type_badge_class()}"}><%= type_label(@type) %></span>
    """
  end

  defp type_badge(assigns = %{type: _type}) do
    ~H"""
    <span class={"lsb-bg-amber-100 lsb-text-amber-800 #{type_badge_class()}"}><%= type_label(@type) %></span>
    """
  end

  defp type_badge_class do
    "lsb lsb-rounded lsb-px-1 md:lsb-px-2 lsb-py-1 lsb-font-mono lsb-text-[0.5em] md:lsb-text-xs"
  end

  defp type_label(type) do
    type |> inspect() |> String.split(".") |> Enum.at(-1)
  end

  defp maybe_locked_attr_input(assigns) do
    case Map.get(assigns.template_attributes, assigns.attr_id) do
      nil ->
        case Map.get(assigns.fields, assigns.attr_id) do
          :locked ->
            ~H|<%= text_input(@form, @attr_id, value: "[Multiple examples]", disabled: true, class: "lsb lsb-form-input lsb-block lsb-w-full lsb-shadow-sm focus:lsb-ring-indigo-500 focus:lsb-border-indigo-500 lsb-text-xs md:lsb-text-sm lsb-border-gray-300 lsb-rounded-md")%>|

          value ->
            assigns |> assign(:value, value) |> attr_input()
        end

      value ->
        ~H|<%= text_input(@form, @attr_id, value: inspect(value), disabled: true, class: "lsb lsb-form-input lsb-block lsb-w-full lsb-shadow-sm focus:lsb-ring-indigo-500 focus:lsb-border-indigo-500 lsb-text-xs md:lsb-text-sm lsb-border-gray-300 lsb-rounded-md")%>|
    end
  end

  defp attr_input(assigns = %{type: :boolean, value: value}) do
    assigns =
      assign(assigns,
        bg_class: if(value, do: "lsb-bg-indigo-600", else: "lsb-bg-gray-200"),
        translate_class: if(value, do: "lsb-translate-x-5", else: "lsb-translate-x-0")
      )

    ~H"""
    <button type="button" phx-click={on_toggle_click(@attr_id, @value)} class={"lsb #{@bg_class} lsb-relative lsb-inline-flex lsb-flex-shrink-0 lsb-p-0 lsb-h-6 lsb-w-11 lsb-border-2 lsb-border-transparent lsb-rounded-full lsb-cursor-pointer lsb-transition-colors lsb-ease-in-out lsb-duration-200 focus:lsb-outline-none focus:lsb-ring-2 focus:lsb-ring-offset-2 focus:lsb-ring-indigo-500"} phx-target={@myself} role="switch">
      <%= hidden_input(@form, @attr_id, value: "#{@value}") %>
      <span class={"lsb #{@translate_class} lsb-form-input lsb-p-0 lsb-border-0 lsb-pointer-events-none lsb-inline-block lsb-h-5 lsb-w-5 lsb-rounded-full lsb-bg-white lsb-shadow lsb-transform lsb-ring-0 lsb-transition lsb-ease-in-out lsb-duration-200"}></span>
    </button>
    """
  end

  defp attr_input(assigns = %{type: type, examples: nil, values: nil})
       when type in [:integer, :float] do
    assigns = assign(assigns, step: if(type == :integer, do: 1, else: 0.01))

    ~H"""
    <%= number_input(@form, @attr_id, value: @value, step: @step, class: "lsb lsb-form-input lsb-text-xs md:lsb-text-sm lsb-block lsb-w-full lsb-shadow-sm focus:lsb-ring-indigo-500 focus:lsb-border-indigo-500 lsb-border-gray-300 lsb-rounded-md") %>
    """
  end

  defp attr_input(assigns = %{type: :integer, examples: min..max}) do
    ~H"""
    <%= number_input(@form, @attr_id, value: @value, min: min, max: max, class: "lsb lsb-form-input lsb-text-xs md:lsb-text-sm lsb-block lsb-w-full lsb-shadow-sm focus:lsb-ring-indigo-500 focus:lsb-border-indigo-500 lsb-border-gray-300 lsb-rounded-md") %>
    """
  end

  defp attr_input(assigns = %{type: :integer, values: min..max}) do
    attr_input(%{assigns | examples: min..max})
  end

  defp attr_input(assigns = %{type: :string, examples: nil, values: nil}) do
    ~H"""
    <%= text_input(@form, @attr_id, value: @value, class: "lsb lsb-form-input lsb-block lsb-w-full lsb-shadow-sm focus:lsb-ring-indigo-500 focus:lsb-border-indigo-500 lsb-text-xs md:lsb-text-sm lsb-border-gray-300 lsb-rounded-md") %>
    """
  end

  defp attr_input(assigns = %{type: _type, examples: nil, values: nil, value: value}) do
    assigns = assign(assigns, value: if(is_nil(value), do: "", else: inspect(value)))

    ~H"""
    <%= text_input(@form, @attr_id, value: @value, disabled: true, class: "lsb lsb-form-input lsb-block lsb-w-full lsb-shadow-sm focus:lsb-ring-indigo-500 focus:lsb-border-indigo-500 lsb-text-xs md:lsb-text-sm lsb-border-gray-300 lsb-rounded-md") %>
    """
  end

  defp attr_input(assigns = %{examples: examples}) when not is_nil(examples) do
    assigns = assign(assigns, examples: [nil | Enum.map(examples, &to_string/1)])

    ~H"""
    <%= select(@form, @attr_id, @examples, value: @value,
      class: "lsb lsb-form-select lsb-mt-1 lsb-block lsb-w-full lsb-pl-3 lsb-pr-10 lsb-py-2 lsb-text-xs md:lsb-text-sm  lsb-border-gray-300 focus:lsb-outline-none focus:lsb-ring-indigo-500 focus:lsb-border-indigo-500 lsb-rounded-md") %>
    """
  end

  defp attr_input(assigns = %{values: examples}) when not is_nil(examples) do
    attr_input(%{assigns | examples: examples})
  end

  defp on_toggle_click(attr_id, value) do
    JS.push("playground-toggle", value: %{toggled: [attr_id, !value]})
  end

  defp fun_or_component(%ComponentStory{type: :live_component, component: component}),
    do: component

  defp fun_or_component(%ComponentStory{type: :component, function: function}),
    do: function

  def handle_event("upper-tab-navigation", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :upper_tab, String.to_atom(tab))}
  end

  def handle_event("lower-tab-navigation", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :lower_tab, String.to_atom(tab))}
  end

  def handle_event("playground-change", %{"playground" => params}, socket = %{assigns: assigns}) do
    story = assigns.story

    fields =
      for {key, value} <- params,
          key = String.to_atom(key),
          reduce: assigns.fields do
        acc ->
          attr_definition = Enum.find(story.attributes, &(&1.id == key))

          if (is_nil(value) || value == "") and !attr_definition.required do
            Map.put(acc, key, nil)
          else
            Map.put(acc, key, cast_value(story, key, value))
          end
      end

    variations = update_variations_attributes(assigns.variations, fields)
    send_attributes(assigns.topic, fields)

    {:noreply, assign(socket, variations: variations, fields: fields)}
  end

  def handle_event(
        "playground-toggle",
        %{"toggled" => [key, value]},
        socket = %{assigns: assigns}
      ) do
    fields = Map.put(assigns.fields, String.to_atom(key), value)

    variations = update_variations_attributes(assigns.variations, fields)
    send_attributes(assigns.topic, fields)
    {:noreply, assign(socket, variations: variations, fields: fields)}
  end

  def handle_event(
        "set-variation",
        %{"variation" => %{"variation_id" => variation_id}},
        s = %{assigns: assigns}
      ) do
    case Enum.find(assigns.story.variations, &(to_string(&1.id) == variation_id)) do
      nil -> nil
      variation -> send_new_variation(assigns.topic, variation)
    end

    {:noreply, patch_to(s, assigns.story, %{tab: :playground, variation_id: variation_id})}
  end

  defp update_variations_attributes(variations, new_attrs) do
    Enum.map(variations, &update_variation_attributes(&1, new_attrs))
  end

  defp update_variation_attributes(variation, new_attrs) do
    new_attrs = Enum.reject(new_attrs, fn {_attr_id, value} -> value == :locked end) |> Map.new()
    attrs = variation.attributes |> Map.merge(new_attrs) |> Map.reject(fn {_, v} -> is_nil(v) end)
    %{variation | attributes: attrs}
  end

  defp send_attributes(topic, attributes) do
    attributes =
      Enum.reject(attributes, fn {_attr_id, value} -> value == :locked end) |> Map.new()

    PubSub.broadcast!(
      PhxLiveStorybook.PubSub,
      topic,
      {:new_attributes_input, attributes}
    )
  end

  defp send_new_variation(topic, variation) do
    PubSub.broadcast!(PhxLiveStorybook.PubSub, topic, {:set_variation, variation})
  end

  defp cast_value(%ComponentStory{attributes: attributes}, attr_id, value) do
    attr = Enum.find(attributes, &(&1.id == attr_id))

    case attr.type do
      :atom -> String.to_atom(value)
      :boolean -> String.to_atom(value)
      :integer -> String.to_integer(value)
      :float -> String.to_float(value)
      _ -> value
    end
  rescue
    _ -> value
  end
end