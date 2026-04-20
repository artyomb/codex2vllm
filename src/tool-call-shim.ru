# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"
require "shellwords"
require "uri"
require "cgi/util"
gem "rack", ">= 3.0", "< 4"
require "sinatra/base"
require "faraday"
require "faraday/retry"
require "faraday/net_http_persistent"

class Qwen3CoderToolCallShim < Sinatra::Base
  EMBEDDED_TOOL_CALL_REGEX = /<tool_call>\s*<function=([^\s>]+)>\s*(.*?)\s*<\/function>\s*<\/tool_call>/m.freeze
  EMBEDDED_TOOL_PARAM_REGEX = /<parameter=([^\s>]+)>\s*(.*?)\s*<\/parameter>/m.freeze
  HOP_BY_HOP_HEADERS = %w[
    connection keep-alive proxy-authenticate proxy-authorization te trailer
    transfer-encoding upgrade host content-length
  ].freeze

  SYSTEM_ROLES = %w[developer system].freeze
  SUPPORTED_INPUT_ITEM_TYPES = %w[message reasoning function_call function_call_output].freeze
  SUPPORTED_MESSAGE_ROLES = %w[user assistant developer system].freeze
  MCP_RESOURCE_TOOL_NAMES = %w[list_mcp_resources list_mcp_resource_templates read_mcp_resource].freeze
  ALWAYS_DEDUPED_TOOL_NAMES = %w[update_plan].freeze
  TEXT_PART_TYPES = %w[input_text output_text text].freeze
  TRACE_PREVIEW_LIMIT = 2_000
  COMPATIBILITY_INSTRUCTIONS = <<~TEXT.freeze
    Codex compatibility rules:
    - For ordinary repository tasks, work directly in the current session.
    - Do not invoke `workflow_orchestrator`, `stage_gate_reviewer`, specialized agents, or `$agent-setup` unless the user explicitly asks for that workflow.
    - Prefer workspace shell/file tools for local files; do not use MCP resource readers for local paths unless the server is clearly available.
    - MCP resource tools are disabled in this shim unless explicitly enabled; use workspace tools for repository files.
    - Use `read_mcp_resource` only after a successful `list_mcp_resources` returns that exact `server` and `uri`.
    - If `list_mcp_resources` or `list_mcp_resource_templates` returns no matching entries, treat MCP resources as unavailable and use workspace tools instead.
    - Do not invent MCP server names such as `skills`, `gem`, or `filesystem`.
    - Use only tools and arguments that match the declared tool schema.
    - Do not emit whitespace-only assistant messages.
    - If you need more information to continue, emit the next tool call in the same response instead of stopping after reasoning.
    - For large files, avoid reading the whole file with `cat`; inspect selectively with `wc -l`, `rg`, `sed -n`, or similar targeted commands.
  TEXT

  UPSTREAM = ENV.fetch("VLLM_UPSTREAM", "http://vllm.h100.local")
  SESSION_LOG_ROOT = ENV.fetch("VLLM_SHIM_SESSION_LOG_DIR", "/tmp/vllm-shim-tool-call-sessions")

  set :bind, ENV.fetch("BIND", "127.0.0.1")
  set :port, ENV.fetch("PORT", "9293")
  set :logging, false
  set :show_exceptions, false
  set :raise_errors, false

  def self.connection
    @connection ||= Faraday.new(url: UPSTREAM) do |faraday|
      faraday.request :retry, max: 2, interval: 0.2, backoff_factor: 2
      faraday.options.timeout = 15
      faraday.options.open_timeout = 10
      faraday.adapter :net_http_persistent
    end
  end

  def self.response_session_index
    @response_session_index ||= {}
  end

  def self.response_session_index_mutex
    @response_session_index_mutex ||= Mutex.new
  end

  def self.lookup_session_dir(response_id)
    response_session_index_mutex.synchronize { response_session_index[response_id] }
  end

  def self.register_session_dir(response_id, session_dir)
    return if response_id.to_s.empty?

    response_session_index_mutex.synchronize do
      response_session_index[response_id] = session_dir
    end
  end

  get "/health" do
    { ok: true, service: "Qwen3CoderToolCallShim" }.to_json
  end

  %i[get post put patch delete options head].each do |verb|
    public_send(verb, "/*") { proxy_request }
    public_send(verb, "/") { proxy_request }
  end

  private

  def proxy_request
    raw_body = request.body&.read.to_s
    request_payload = parse_json_body(raw_body)
    session_log = session_log_context(request_payload)
    outbound_body = raw_body
    outbound_headers = request_headers

    log_debug "request path=#{request.fullpath} method=#{request.request_method}"
    log_debug "request body=#{raw_body[0..1500]}" unless raw_body.empty?

    if responses_request? && !raw_body.empty?
      normalized_body = normalize_responses_request(raw_body)
      if normalized_body
        outbound_body = normalized_body
        outbound_headers["Content-Type"] = "application/json"
        log_debug "normalized request body=#{normalized_body[0..1500]}"
        write_debug_file("/tmp/vllm-shim-tool-call-last-request.json", normalized_body)
      end
    end

    upstream_response = self.class.connection.run_request(
      request.request_method.downcase.to_sym,
      request.fullpath,
      outbound_body,
      outbound_headers
    )

    log_debug "upstream status=#{upstream_response.status}"
    log_debug "upstream body=#{upstream_response.body.to_s[0..2000]}"
    write_debug_file("/tmp/vllm-shim-tool-call-last-upstream-response.txt", upstream_response.body.to_s)

    response_body = normalize_responses_response(upstream_response.body, upstream_response.headers, request_payload)
    write_session_log(
      session_log,
      raw_body: raw_body,
      outbound_body: outbound_body,
      outbound_headers: outbound_headers,
      upstream_response: upstream_response,
      response_body: response_body
    )
    write_debug_file("/tmp/vllm-shim-tool-call-last-response.txt", response_body.to_s)
    filtered_response_headers(upstream_response.headers).each { |key, value| headers[key] = value }
    content_type upstream_response.headers["content-type"] || "application/json"
    status upstream_response.status
    body response_body
  end

  def request_headers
    env.each_with_object({}) do |(key, value), headers|
      next unless key.start_with?("HTTP_")

      header_name = key.delete_prefix("HTTP_").split("_").map(&:capitalize).join("-")
      next if HOP_BY_HOP_HEADERS.include?(header_name.downcase)

      headers[header_name] = value
    end.tap do |headers|
      headers["Content-Type"] = request.content_type if request.content_type
      headers["Accept-Encoding"] = "identity" if headers["Accept-Encoding"]
    end
  end

  def filtered_response_headers(response_headers)
    response_headers.each_with_object({}) do |(key, value), headers|
      next if HOP_BY_HOP_HEADERS.include?(key.downcase)

      headers[key] = value
    end
  end

  def responses_request?
    request.path_info == "/v1/responses" || request.path_info == "/responses"
  end

  def normalize_responses_request(raw_body)
    payload = JSON.parse(raw_body)
    return raw_body unless payload.is_a?(Hash) && payload["input"].is_a?(Array)

    fold_system_messages_into_instructions!(payload)
    filter_disabled_tools!(payload)
    append_compatibility_instructions!(payload)

    dropped_items = []
    invalid_function_call_ids = {}

    normalized_items = payload["input"].filter_map do |item|
      result = normalize_input_item(item, invalid_function_call_ids)
      dropped_items << item unless result
      result
    end

    dropped_function_call_ids = invalid_function_call_ids.dup

    normalized_items.each do |item|
      next unless item.is_a?(Hash) && item["type"] == "function_call_output"
      next unless invalid_tool_call_output?(item["output"])

      call_id = item["call_id"].to_s
      next if call_id.empty?

      dropped_function_call_ids[call_id] = true
    end

    if dropped_function_call_ids.any?
      normalized_items = normalized_items.filter_map do |item|
        next item unless item.is_a?(Hash)
        next item unless %w[function_call function_call_output].include?(item["type"])
        next item unless dropped_function_call_ids[item["call_id"].to_s]

        dropped_items << item
        nil
      end
    end

    normalized_items = prune_transient_history_items(normalized_items, dropped_items)
    normalized_items = collapse_duplicate_tool_history_items(normalized_items, dropped_items, payload["model"])

    payload["input"] = normalized_items
    payload = strip_nil_values(payload)
    log_dropped_items(dropped_items) if dropped_items.any?
    log_debug "normalized input roles/types=#{payload["input"].map { |item| item["role"] || item["type"] }.inspect}"
    log_debug "normalized input tail=#{JSON.generate(payload["input"].last(4))[0..4000]}" if payload["input"].length > 2
    JSON.generate(payload)
  rescue JSON::ParserError
    warn "vllm-shim-tool-call: JSON parse error for: #{raw_body[0..100]}"
    nil
  end

  def fold_system_messages_into_instructions!(payload)
    fragments = []
    instructions = payload["instructions"].to_s
    fragments << instructions if instructions.length.positive?

    payload["input"] = payload["input"].filter_map do |item|
      unless item.is_a?(Hash) && SYSTEM_ROLES.include?(item["role"])
        next item
      end

      text = extract_text_content(item["content"])
      if text && !text.empty?
        fragments << text
        next nil
      end

      normalized_item = strip_nil_values(item.dup)
      normalized_item["role"] = "system"
      normalized_item
    end

    if fragments.any?
      payload["instructions"] = fragments.join("\n\n")
    else
      payload.delete("instructions")
    end
  end

  def append_compatibility_instructions!(payload)
    instructions = payload["instructions"].to_s
    return if instructions.include?(COMPATIBILITY_INSTRUCTIONS.strip)

    payload["instructions"] = if instructions.empty?
                                COMPATIBILITY_INSTRUCTIONS.strip
                              else
                                "#{instructions}\n\n#{COMPATIBILITY_INSTRUCTIONS.strip}"
                              end
  end

  def filter_disabled_tools!(payload)
    return unless payload.is_a?(Hash) && payload["tools"].is_a?(Array)
    return unless mcp_resource_tools_disabled?

    payload["tools"] = payload["tools"].reject do |tool|
      tool.is_a?(Hash) && tool["type"] == "function" && MCP_RESOURCE_TOOL_NAMES.include?(tool["name"].to_s)
    end
  end

  def mcp_resource_tools_disabled?
    !truthy_env?("VLLM_SHIM_ENABLE_MCP_RESOURCE_TOOLS")
  end

  def truthy_env?(name)
    %w[1 true yes on].include?(ENV[name].to_s.downcase)
  end

  def prune_transient_history_items(items, dropped_items)
    Array(items).each_with_index.filter_map do |item, index|
      if item.is_a?(Hash) && item["type"] == "reasoning"
        dropped_items << item
        next nil
      end

      if transient_assistant_message?(items, index)
        dropped_items << item
        next nil
      end

      item
    end
  end

  def collapse_duplicate_tool_history_items(items, dropped_items, model_name = nil)
    duplicate_call_ids = {}
    deduped_items = []
    index = 0

    while index < items.length
      item = items[index]

      if collapsible_duplicate_tool_call?(item, model_name)
        deduped_items << item
        index += 1

        while index < items.length && duplicate_tool_call?(item, items[index], model_name)
          duplicate_item = items[index]
          duplicate_call_ids[duplicate_item["call_id"].to_s] = true
          dropped_items << duplicate_item
          index += 1
        end

        next
      end

      if item.is_a?(Hash) && item["type"] == "function_call_output" && duplicate_call_ids[item["call_id"].to_s]
        dropped_items << item
        index += 1
        next
      end

      deduped_items << item
      index += 1
    end

    deduped_items
  end

  def collapsible_duplicate_tool_call?(item, model_name = nil)
    item.is_a?(Hash) &&
      item["type"] == "function_call" &&
      duplicate_tool_dedupe_enabled?(item["name"], model_name) &&
      !item["name"].to_s.empty? &&
      !item["call_id"].to_s.empty?
  end

  def duplicate_tool_call?(reference, candidate, model_name = nil)
    collapsible_duplicate_tool_call?(reference, model_name) &&
      collapsible_duplicate_tool_call?(candidate, model_name) &&
      reference["name"].to_s == candidate["name"].to_s &&
      reference["arguments"].to_s == candidate["arguments"].to_s
  end

  def duplicate_tool_dedupe_enabled?(tool_name, model_name)
    ALWAYS_DEDUPED_TOOL_NAMES.include?(tool_name.to_s) || gemma_model?(model_name)
  end

  def gemma_model?(model_name)
    model_name.to_s.downcase.include?("gemma")
  end

  def transient_assistant_message?(items, index)
    item = items[index]
    return false unless item.is_a?(Hash) && assistant_message_item?(item)

    items[(index + 1)..]&.each do |candidate|
      next unless candidate.is_a?(Hash)

      return false if user_message_item?(candidate)
      return true if candidate["type"] == "function_call"
    end

    false
  end

  def assistant_message_item?(item)
    role = item["role"].to_s
    return false unless role == "assistant"

    item["type"] == "message" || item["content"].is_a?(Array)
  end

  def user_message_item?(item)
    role = item["role"].to_s
    role == "user" || item["type"] == "message" && role == "user"
  end

  def normalize_input_item(item, invalid_function_call_ids = nil)
    return nil unless item.is_a?(Hash)

    type = item["type"].to_s
    if !type.empty? && !SUPPORTED_INPUT_ITEM_TYPES.include?(type)
      return nil
    end

    case type
    when "reasoning"
      normalize_reasoning_input_item(item)
    when "message"
      normalize_message_input_item(item)
    when "function_call"
      normalize_function_call_input_item(item, invalid_function_call_ids)
    when "function_call_output"
      normalize_function_call_output_input_item(item)
    else
      normalize_role_input_item(item)
    end
  end

  def normalize_reasoning_input_item(item)
    item = strip_nil_values(item)
    item["id"] = "reasoning_#{SecureRandom.hex(8)}" if item["id"].to_s.empty?
    item["summary"] ||= []
    item
  end

  def normalize_message_input_item(item)
    item = strip_nil_values(item)

    return item unless item["role"] == "assistant"
    return nil if blank_assistant_message?(item)

    item["id"] ||= "msg_#{SecureRandom.hex(8)}"
    item["status"] = "completed"

    Array(item["content"]).each do |content|
      next unless content.is_a?(Hash) && content["type"] == "output_text"

      content["annotations"] ||= []
    end

    item
  end

  def normalize_function_call_input_item(item, invalid_function_call_ids = nil)
    item = strip_nil_values(item)
    call_id = item["call_id"].to_s
    name = item["name"].to_s
    return nil if call_id.empty? || name.empty?
    if mcp_resource_tools_disabled? && MCP_RESOURCE_TOOL_NAMES.include?(name)
      invalid_function_call_ids[call_id] = true if invalid_function_call_ids
      return nil
    end

    item["arguments"] = case item["arguments"]
                        when String
                          item["arguments"]
                        when nil
                          "{}"
                        else
                          JSON.generate(item["arguments"])
                        end

    JSON.parse(item["arguments"])
    item
  rescue JSON::ParserError, TypeError
    invalid_function_call_ids[call_id] = true if invalid_function_call_ids && !call_id.empty?
    nil
  end

  def normalize_function_call_output_input_item(item)
    item = strip_nil_values(item)
    return nil if item["call_id"].to_s.empty?

    item["output"] = case item["output"]
                     when String
                       item["output"]
                     when nil
                       ""
                     else
                       JSON.generate(item["output"])
                     end

    item
  rescue TypeError
    nil
  end

  def normalize_role_input_item(item)
    item = strip_nil_values(item.dup)
    return nil unless SUPPORTED_MESSAGE_ROLES.include?(item["role"].to_s)

    item["role"] = "system" if item["role"] == "developer"

    return item unless item["role"] == "assistant" && item["content"].is_a?(Array)
    return nil if blank_assistant_message?(item)

    item["type"] ||= "message"
    item["id"] ||= "msg_#{SecureRandom.hex(8)}"
    item["status"] = "completed"

    Array(item["content"]).each do |content|
      next unless content.is_a?(Hash) && content["type"] == "output_text"

      content["annotations"] ||= []
    end

    item
  end

  def blank_assistant_message?(item)
    return false unless item.is_a?(Hash) && item["role"] == "assistant"

    extract_text_content(item["content"]).to_s.strip.empty?
  end

  def tool_argument_parse_failure?(output)
    output.to_s.lstrip.start_with?("failed to parse function arguments:")
  end

  def unknown_mcp_server_failure?(output)
    output.to_s.lstrip.match?(/\Aresources\/(?:read|list) failed: unknown MCP server\b/)
  end

  def unsupported_call_failure?(output)
    output.to_s.lstrip.start_with?("unsupported call:")
  end

  def invalid_tool_call_output?(output)
    tool_argument_parse_failure?(output) || unknown_mcp_server_failure?(output) || unsupported_call_failure?(output)
  end

  def extract_text_content(content)
    case content
    when String
      content
    when Hash
      return content["text"] if content["text"].is_a?(String)
    when Array
      parts = content.map do |part|
        case part
        when String
          part
        when Hash
          next unless part["text"].is_a?(String)
          next unless part["type"].nil? || TEXT_PART_TYPES.include?(part["type"])

          part["text"]
        end
      end

      return nil if parts.any?(&:nil?)

      parts.join
    end
  end

  def log_dropped_items(items)
    items.each_with_index do |item, index|
      reason = if item.is_a?(Hash)
        case item["type"]
        when "reasoning"
          "reasoning item (missing/empty id)"
        when "message"
          "assistant message with empty content"
        when "function_call"
          "function call item (missing metadata or invalid arguments JSON)"
        when "function_call_output"
          "function call output item (missing call_id or non-serializable output)"
        else
          "unsupported item"
        end
      else
        "not a hash"
      end

      warn "vllm-shim-tool-call: dropped item ##{index}: #{reason} [#{item.inspect[0..200]}]"
    end
  end

  def normalize_responses_response(raw_body, response_headers, request_payload = nil)
    return normalize_responses_stream(raw_body, request_payload) if sse_response?(raw_body, response_headers)

    payload = JSON.parse(raw_body)
    return raw_body unless payload.is_a?(Hash)

    normalize_response_tool_calls!(payload, request_payload)
    promote_reasoning_only_completion!(payload)
    log_response_summary(payload) if ENV["VLLM_SHIM_TOOL_CALL_DEBUG"]
    JSON.generate(strip_nil_values(payload))
  rescue JSON::ParserError, TypeError
    raw_body
  end

  def sse_response?(raw_body, response_headers)
    response_headers["content-type"].to_s.include?("text/event-stream") ||
      raw_body.to_s.start_with?("event: response.")
  end

  def normalize_responses_stream(raw_body, request_payload = nil)
    events = parse_sse(raw_body)
    completed_response = events.find { |event| event[:name] == "response.completed" }&.dig(:json, "response")
    tool_schemas = tool_schema_map(request_payload)
    response_model = response_model_name(request_payload, completed_response)
    collapse_duplicate_response_function_calls!(completed_response, response_model, tool_schemas)
    message_item = Array(completed_response&.fetch("output", nil)).find { |item| item["type"] == "message" }
    completed_function_calls = Array(completed_response&.fetch("output", nil)).select { |item| item["type"] == "function_call" }
    message_id = message_item&.fetch("id", nil) || "msg_#{SecureRandom.hex(8)}"
    message_output_index = Array(completed_response&.fetch("output", nil)).index(message_item)

    sequence_number = 0
    text = +""
    text_started = false
    content_part_added = false
    text_done = false
    content_part_done = false
    message_done = false
    upstream_message_added = events.any? { |event| event.dig(:json, "item", "type") == "message" }
    message_added = false
    function_call_states = {}
    function_call_order = []
    suppressed_function_call_ids = {}

    emit = lambda do |name, payload|
      clean_payload = strip_nil_values(payload)
      clean_payload["type"] ||= name
      clean_payload["sequence_number"] = sequence_number
      sequence_number += 1
      "event: #{name}\ndata: #{JSON.generate(clean_payload)}\n\n"
    end

    normalized = events.filter_map do |event|
      next event[:raw] unless event[:json].is_a?(Hash)

      payload = event[:json]
      name = event[:name] || payload["type"]

      case name
      when "response.output_item.added"
        case payload.dig("item", "type")
        when "message"
          message_output_index ||= payload["output_index"]
          next unless payload["output_index"] == message_output_index

          message_added = true
          emit.call(name, message_added_event(message_id, message_output_index))
        when "function_call"
          item = payload["item"]
          completed_item = completed_function_calls[function_call_order.length]
          if suppress_response_function_call_item?(item, completed_item, completed_function_calls, function_call_order, response_model)
            suppressed_function_call_ids[item["id"]] = true
            next
          end
          source_arguments = item["arguments"]
          source_arguments = completed_item&.dig("arguments") if source_arguments.to_s.empty?
          rewritten_name, rewritten_arguments = rewrite_tool_call(item["name"], source_arguments)
          function_call_state = {
            "id" => item["id"],
            "call_id" => item["call_id"],
            "name" => rewritten_name,
            "namespace" => item["namespace"],
            "output_index" => payload["output_index"],
            "arguments" => (rewritten_name != item["name"] || rewritten_arguments.to_s != source_arguments.to_s) ? rewritten_arguments.dup : +"",
            "arguments_done" => false,
            "item_done" => false,
            "completed_item" => completed_item,
            "rewritten" => rewritten_name != item["name"] || rewritten_arguments.to_s != source_arguments.to_s
          }
          function_call_states[function_call_state["id"]] = function_call_state
          function_call_order << function_call_state
          payload = payload.dup
          payload["item"] = item.merge(
            "name" => function_call_state["name"]
          )
          payload["item"]["arguments"] = function_call_state["arguments"] if function_call_state["rewritten"]
          emit.call(name, payload)
        else
          emit.call(name, payload)
        end
      when "response.content_part.added"
        message_output_index ||= payload["output_index"] if payload.dig("part", "type") == "output_text"
        if payload["output_index"] == message_output_index
          prefix = +""
          unless message_added
            prefix << emit.call("response.output_item.added", message_added_event(message_id, message_output_index))
            message_added = true
          end
          content_part_added = true
          prefix << emit.call(name, content_part_added_event(message_id, message_output_index))
        else
          emit.call(name, payload)
        end
      when "response.output_text.delta"
        message_output_index ||= payload["output_index"]
        next emit.call(name, payload) unless payload["output_index"] == message_output_index

        prefix = +""
        unless text_started
          unless message_added
            prefix << emit.call("response.output_item.added", message_added_event(message_id, message_output_index))
          end
          unless content_part_added
            prefix << emit.call("response.content_part.added", content_part_added_event(message_id, message_output_index))
            content_part_added = true
          end
          text_started = true
        end

        delta = normalize_leading_message_delta(payload["delta"].to_s, text)
        next prefix if delta.empty?

        text << delta
        payload["delta"] = delta
        payload["item_id"] = message_id
        payload["output_index"] = message_output_index
        payload["content_index"] = 0
        prefix << emit.call(name, payload)
      when "response.output_text.done"
        message_output_index ||= payload["output_index"]
        if payload["output_index"] == message_output_index
          text = payload["text"].to_s if text.empty? && payload["text"].is_a?(String)
          text_done = true
          emit.call(name, output_text_done_event(message_id, message_output_index, text))
        elsif function_call_states.key?(payload["item_id"])
          next
        else
          emit.call(name, payload)
        end
      when "response.content_part.done"
        message_output_index ||= payload["output_index"] if payload.dig("part", "type") == "output_text"
        if payload["output_index"] == message_output_index
          text = payload.dig("part", "text").to_s if text.empty? && payload.dig("part", "text").is_a?(String)
          content_part_done = true
          emit.call(name, content_part_done_event(message_id, message_output_index, text))
        elsif function_call_states.key?(payload["item_id"])
          next
        else
          emit.call(name, payload)
        end
      when "response.function_call_arguments.delta"
        next if suppressed_function_call_ids[payload["item_id"]]

        function_call_state = function_call_states[payload["item_id"]]
        next if function_call_state&.fetch("rewritten", false)

        function_call_state&.fetch("arguments")&.<< payload["delta"].to_s
        emit.call(name, payload)
      when "response.function_call_arguments.done"
        next if suppressed_function_call_ids[payload["item_id"]]

        function_call_state = function_call_states[payload["item_id"]]
        if function_call_state
          function_call_state["arguments"] = function_call_arguments(function_call_state, tool_schemas)
          function_call_state["arguments_done"] = true
          payload["name"] = function_call_state["name"]
          payload["arguments"] = function_call_state["arguments"]
        end
        emit.call(name, payload)
      when "response.output_item.done"
        case payload.dig("item", "type")
        when "message"
          message_output_index ||= payload["output_index"]
          next if payload["output_index"] != message_output_index

          text = extract_message_text(payload["item"]) if text.empty?
          message_done = true
          emit.call(name, message_done_event(message_id, message_output_index, text))
        when "function_call"
          next if suppressed_function_call_ids[payload.dig("item", "id")]

          function_call_state = function_call_states.dig(payload.dig("item", "id"))
          if function_call_state
            function_call_state["arguments"] = function_call_arguments(function_call_state, tool_schemas)
            function_call_state["item_done"] = true
            payload["item"]["name"] = function_call_state["name"]
            payload["item"]["arguments"] = function_call_state["arguments"]
          end
          emit.call(name, payload)
        else
          emit.call(name, payload)
        end
      when "response.completed"
        final_text = completed_message_text(text, completed_response, message_output_index)
        if function_call_order.empty? && (embedded_tool_call = extract_embedded_tool_call(final_text))
          message_present = text_started || message_added || !final_text.to_s.empty?
          function_call_order << embedded_tool_call_state(
            embedded_tool_call,
            message_present: message_present,
            message_output_index: message_output_index
          )
          final_text = embedded_tool_call["remaining_text"].to_s
        end
        function_call_order = collapse_duplicate_function_call_states(function_call_order, response_model, tool_schemas)
        suffix = +""
        if !text_started && !final_text.empty? && function_call_order.empty?
          suffix << emit.call("response.output_item.added", message_added_event(message_id, message_output_index))
          suffix << emit.call("response.content_part.added", content_part_added_event(message_id, message_output_index))
          suffix << emit.call("response.output_text.done", output_text_done_event(message_id, message_output_index, final_text))
          suffix << emit.call("response.content_part.done", content_part_done_event(message_id, message_output_index, final_text))
          suffix << emit.call("response.output_item.done", message_done_event(message_id, message_output_index, final_text))
        end
        suffix << emit.call("response.output_text.done", output_text_done_event(message_id, message_output_index, final_text)) if text_started && !text_done
        suffix << emit.call("response.content_part.done", content_part_done_event(message_id, message_output_index, final_text)) if text_started && !content_part_done
        suffix << emit.call("response.output_item.done", message_done_event(message_id, message_output_index || 0, final_text)) if message_added && !message_done
        function_call_order.each do |function_call_state|
          function_call_state["arguments"] = function_call_arguments(function_call_state, tool_schemas)
          unless function_call_state["arguments_done"]
            suffix << emit.call("response.function_call_arguments.done", function_call_arguments_done_event(function_call_state))
            function_call_state["arguments_done"] = true
          end
          unless function_call_state["item_done"]
            suffix << emit.call("response.output_item.done", function_call_done_event(function_call_state))
            function_call_state["item_done"] = true
          end
        end
        suffix << emit.call(name, normalize_completed_response_payload(payload, message_id, message_output_index, final_text, function_call_order, tool_schemas))
      else
        emit.call(name, payload)
      end
    end.join

    log_stream_summary(text_started, upstream_message_added, text) if ENV["VLLM_SHIM_TOOL_CALL_DEBUG"]
    finalize_normalized_stream(normalized, response_model, tool_schemas)
  rescue JSON::ParserError, TypeError
    raw_body
  end

  def parse_sse(raw_body)
    raw_body.to_s.split(/\n\n/).filter_map do |block|
      next if block.strip.empty?

      name = nil
      data = []
      block.each_line(chomp: true) do |line|
        name = line.delete_prefix("event:").strip if line.start_with?("event:")
        data << line.delete_prefix("data:").strip if line.start_with?("data:")
      end

      raw = "#{block}\n\n"
      json = data.empty? ? nil : JSON.parse(data.join("\n"))
      { name: name, json: json, raw: raw }
    rescue JSON::ParserError
      { name: name, json: nil, raw: raw }
    end
  end

  def message_added_event(message_id, output_index)
    {
      "item" => {
        "id" => message_id,
        "content" => [],
        "role" => "assistant",
        "status" => "in_progress",
        "type" => "message"
      },
      "output_index" => output_index
    }
  end

  def content_part_added_event(message_id, output_index)
    message_text_event({}, message_id, output_index, "")
  end

  def output_text_done_event(message_id, output_index, text)
    message_text_event({}, message_id, output_index, text).merge("text" => text)
  end

  def content_part_done_event(message_id, output_index, text)
    message_text_event({}, message_id, output_index, text)
  end

  def message_text_event(payload, message_id, output_index, text)
    payload.merge(
      "item_id" => message_id,
      "output_index" => output_index,
      "content_index" => 0,
      "part" => {
        "annotations" => [],
        "text" => text,
        "type" => "output_text"
      }
    )
  end

  def message_done_event(message_id, output_index, text)
    {
      "item" => {
        "id" => message_id,
        "content" => [
          {
            "annotations" => [],
            "text" => text,
            "type" => "output_text"
          }
        ],
        "role" => "assistant",
        "status" => "completed",
        "type" => "message"
      },
      "output_index" => output_index
    }
  end

  def normalize_completed_response_payload(payload, message_id, output_index, text, function_call_states = nil, tool_schemas = nil)
    response = payload["response"]
    return payload unless response.is_a?(Hash)

    function_call_states = collapse_duplicate_function_call_states(function_call_states, response["model"], tool_schemas)
    collapse_duplicate_response_function_calls!(response, response["model"], tool_schemas)
    output = Array(response["output"])
    append_embedded_tool_call_items!(output, function_call_states, tool_schemas)
    promote_reasoning_only_completion!(payload, message_id, output_index, text) if output.none? { |item| item.is_a?(Hash) && item["type"] == "function_call" }

    output = Array(response["output"])
    message_item = output.find { |item| item["type"] == "message" }
    if message_item
      final_text = text.to_s
      final_text = extract_message_text(message_item).to_s if final_text.empty?
      message_payload = message_done_event(message_id, output_index, final_text).fetch("item")
      message_item.replace(message_payload)
    end

    output.select { |item| item["type"] == "function_call" }.zip(Array(function_call_states)).each do |item, function_call_state|
      next unless item && function_call_state

      item["call_id"] = function_call_state["call_id"] if function_call_state["call_id"]
      item["name"] = function_call_state["name"] if function_call_state["name"]
      item["arguments"] = function_call_arguments(function_call_state, tool_schemas)
    end

    payload
  end

  def normalize_leading_message_delta(delta, current_text)
    return delta unless current_text.empty?

    delta.sub(/\A(?:\r?\n)+/, "")
  end

  def completed_message_text(current_text, completed_response, output_index)
    return current_text unless current_text.empty?

    completed_output = Array(completed_response&.fetch("output", nil))
    message_item = completed_output[output_index]
    if message_item.is_a?(Hash) && message_item["type"] == "message"
      return extract_message_text(message_item).to_s
    end

    completed_output.filter_map do |item|
      next unless item.is_a?(Hash) && item["type"] == "reasoning"

      embedded_tool_call = extract_embedded_tool_call(extract_reasoning_text(item))
      next embedded_tool_call["remaining_text"] if embedded_tool_call

      extract_reasoning_text(item)
    end.join
  end

  def promote_reasoning_only_completion!(payload, message_id = nil, output_index = nil, text = nil)
    response = payload["response"]
    return payload unless response.is_a?(Hash)

    output = Array(response["output"])
    return payload if output.any? { |item| item.is_a?(Hash) && %w[message function_call].include?(item["type"]) }

    final_text = text.to_s
    if final_text.empty?
      final_text = output.filter_map do |item|
        next unless item.is_a?(Hash) && item["type"] == "reasoning"

        extract_reasoning_text(item)
      end.join
    end
    return payload if final_text.strip.empty?

    synthetic_message = message_done_event(message_id || "msg_#{SecureRandom.hex(8)}", output_index || 0, final_text).fetch("item")
    response["output"] = output.reject { |item| item.is_a?(Hash) && item["type"] == "reasoning" }
    response["output"] << synthetic_message
    payload
  end

  def log_response_summary(payload)
    outputs = Array(payload["output"]).map do |item|
      content_types = Array(item["content"]).map { |content| content["type"] }.join("+")
      [item["type"], item["status"], content_types].compact.join(":")
    end

    warn "vllm-shim-tool-call: response status=#{payload["status"]} outputs=#{outputs.join(",")}"
  end

  def log_stream_summary(text_started, message_added, text)
    preview = text.inspect[0..200]
    warn "vllm-shim-tool-call: stream text_started=#{text_started} upstream_message_added=#{message_added} text=#{preview}"
  end

  def parse_json_body(raw_body)
    return nil if raw_body.to_s.strip.empty?

    JSON.parse(raw_body)
  rescue JSON::ParserError, TypeError
    nil
  end

  def session_log_context(request_payload)
    return nil unless ENV["VLLM_SHIM_TOOL_CALL_DEBUG"]

    request_payload = request_payload.is_a?(Hash) ? request_payload : {}
    session_key = extract_session_key(request_payload)
    previous_response_id = request_payload["previous_response_id"].to_s
    existing_dir = previous_response_id.empty? ? nil : self.class.lookup_session_dir(previous_response_id)

    session_dir_name = if session_key && !session_key.empty?
      "session-#{sanitize_path_component(session_key)}"
    elsif existing_dir
      File.basename(existing_dir)
    else
      timestamp_label
    end

    {
      "session_dir" => File.join(SESSION_LOG_ROOT, session_dir_name),
      "session_key" => session_key,
      "previous_response_id" => previous_response_id.empty? ? nil : previous_response_id,
      "turn_id" => "#{timestamp_label}-#{SecureRandom.hex(3)}"
    }
  end

  def extract_session_key(request_payload)
    return nil unless request_payload.is_a?(Hash)

    [
      request_payload["session_id"],
      request_payload["conversation_id"],
      request_payload.dig("session", "id"),
      request_payload.dig("client_metadata", "session_id"),
      env["HTTP_X_SESSION_ID"]
    ].find { |value| value.is_a?(String) && !value.empty? }
  end

  def sanitize_path_component(value)
    sanitized = value.to_s.gsub(/[^0-9A-Za-z.\-_]+/, "_").gsub(/\A[._-]+|[._-]+\z/, "")
    sanitized = "anonymous" if sanitized.empty?
    sanitized[0, 120]
  end

  def timestamp_label
    Time.now.utc.strftime("%Y%m%dT%H%M%S.%6NZ")
  end

  def write_session_log(session_log, raw_body:, outbound_body:, outbound_headers:, upstream_response:, response_body:)
    return unless session_log

    session_dir = session_log.fetch("session_dir")
    turn_prefix = File.join(session_dir, session_log.fetch("turn_id"))
    response_headers = filtered_response_headers(upstream_response.headers)
    response_id = extract_response_id(response_body, response_headers)

    write_debug_file("#{turn_prefix}.request.raw#{content_extension(raw_body, request.content_type)}", raw_body.to_s)
    write_debug_file("#{turn_prefix}.request.outbound#{content_extension(outbound_body, outbound_headers["Content-Type"])}", outbound_body.to_s)
    write_debug_file("#{turn_prefix}.request.headers.json", JSON.pretty_generate(outbound_headers))
    write_debug_file("#{turn_prefix}.response.upstream#{content_extension(upstream_response.body, upstream_response.headers["content-type"])}", upstream_response.body.to_s)
    write_debug_file("#{turn_prefix}.response.normalized#{content_extension(response_body, response_headers["content-type"])}", response_body.to_s)
    write_debug_file("#{turn_prefix}.response.headers.json", JSON.pretty_generate(response_headers))
    write_debug_file("#{turn_prefix}.trace.jsonl", build_turn_trace(outbound_body, response_body, response_headers))

    metadata = strip_nil_values(
      "logged_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ"),
      "request_method" => request.request_method,
      "request_path" => request.fullpath,
      "request_content_type" => request.content_type,
      "response_status" => upstream_response.status,
      "response_content_type" => response_headers["content-type"],
      "session_key" => session_log["session_key"],
      "previous_response_id" => session_log["previous_response_id"],
      "response_id" => response_id
    )
    write_debug_file("#{turn_prefix}.meta.json", JSON.pretty_generate(metadata))
    append_debug_file(File.join(session_dir, "index.jsonl"), JSON.generate(metadata) + "\n")

    self.class.register_session_dir(response_id, session_dir)
  end

  def build_turn_trace(outbound_body, response_body, response_headers)
    entries = []
    entries.concat(request_trace_entries(parse_json_body(outbound_body)))
    entries.concat(response_trace_entries(response_body, response_headers))
    return "" if entries.empty?

    entries.map { |entry| JSON.generate(strip_nil_values(entry)) }.join("\n") + "\n"
  end

  def request_trace_entries(payload)
    return [] unless payload.is_a?(Hash) && payload["input"].is_a?(Array)

    payload["input"].each_with_index.filter_map do |item, index|
      trace_request_item(item, index)
    end
  end

  def trace_request_item(item, index)
    return unless item.is_a?(Hash)

    case item["type"]
    when "reasoning"
      {
        "phase" => "request",
        "event" => "reasoning",
        "index" => index,
        "id" => item["id"],
        "text" => preview_trace_text(extract_reasoning_text(item))
      }
    when "function_call"
      {
        "phase" => "request",
        "event" => "function_call",
        "index" => index,
        "call_id" => item["call_id"],
        "name" => item["name"],
        "arguments" => preview_trace_text(item["arguments"])
      }
    when "function_call_output"
      {
        "phase" => "request",
        "event" => "function_call_output",
        "index" => index,
        "call_id" => item["call_id"],
        "output" => preview_trace_text(item["output"])
      }
    end
  end

  def response_trace_entries(response_body, response_headers)
    return parse_sse(response_body).filter_map { |event| trace_sse_event(event) } if sse_response?(response_body, response_headers)

    trace_response_payload(parse_json_body(response_body))
  end

  def trace_sse_event(event)
    payload = event[:json]
    return unless payload.is_a?(Hash)

    name = event[:name] || payload["type"]
    case name
    when "response.reasoning_text.done"
      {
        "phase" => "response",
        "event" => name,
        "sequence_number" => payload["sequence_number"],
        "item_id" => payload["item_id"],
        "text" => preview_trace_text(payload["text"])
      }
    when "response.function_call_arguments.done"
      {
        "phase" => "response",
        "event" => name,
        "sequence_number" => payload["sequence_number"],
        "item_id" => payload["item_id"],
        "name" => payload["name"],
        "arguments" => preview_trace_text(payload["arguments"])
      }
    when "response.output_item.added", "response.output_item.done"
      trace_output_item_event(name, payload)
    when "response.completed"
      trace_completed_event(payload)
    end
  end

  def trace_output_item_event(name, payload)
    item = payload["item"]
    return unless item.is_a?(Hash) && item["type"] == "function_call"

    {
      "phase" => "response",
      "event" => name,
      "sequence_number" => payload["sequence_number"],
      "call_id" => item["call_id"],
      "name" => item["name"],
      "status" => item["status"],
      "arguments" => preview_trace_text(item["arguments"])
    }
  end

  def trace_completed_event(payload)
    response = payload["response"]
    return unless response.is_a?(Hash)

    {
      "phase" => "response",
      "event" => "response.completed",
      "sequence_number" => payload["sequence_number"],
      "response_id" => response["id"],
      "status" => response["status"],
      "output" => summarize_response_output(response["output"])
    }
  end

  def trace_response_payload(payload)
    return [] unless payload.is_a?(Hash)

    response = payload["response"].is_a?(Hash) ? payload["response"] : payload
    return [] unless response.is_a?(Hash)

    [{
      "phase" => "response",
      "event" => "response.completed",
      "response_id" => response["id"],
      "status" => response["status"],
      "output" => summarize_response_output(response["output"])
    }]
  end

  def summarize_response_output(output)
    Array(output).filter_map do |item|
      next unless item.is_a?(Hash)

      summary = {
        "type" => item["type"],
        "status" => item["status"]
      }

      case item["type"]
      when "message"
        summary["text"] = preview_trace_text(extract_message_text(item))
      when "function_call"
        summary["call_id"] = item["call_id"]
        summary["name"] = item["name"]
        summary["arguments"] = preview_trace_text(item["arguments"])
      when "reasoning"
        summary["text"] = preview_trace_text(extract_reasoning_text(item))
      end

      strip_nil_values(summary)
    end
  end

  def extract_reasoning_text(item)
    return unless item.is_a?(Hash)

    texts = Array(item["content"]).filter_map do |part|
      next unless part.is_a?(Hash) && part["text"].is_a?(String)

      part["text"]
    end
    return texts.join unless texts.empty?

    summaries = Array(item["summary"]).filter_map do |part|
      next unless part.is_a?(Hash) && part["text"].is_a?(String)

      part["text"]
    end
    return summaries.join unless summaries.empty?

    nil
  end

  def extract_message_text(item)
    return unless item.is_a?(Hash)

    Array(item["content"]).filter_map do |part|
      next unless part.is_a?(Hash) && part["type"] == "output_text"

      part["text"]
    end.join
  end

  def preview_trace_text(text, limit = TRACE_PREVIEW_LIMIT)
    value = text.to_s
    return nil if value.empty?
    return value if value.length <= limit

    "#{value[0, limit]}...(truncated)"
  end

  def function_call_arguments(function_call_state, tool_schemas = nil)
    return "" unless function_call_state.is_a?(Hash)

    arguments = function_call_state["arguments"].to_s
    arguments = function_call_state.dig("completed_item", "arguments").to_s if arguments.empty?
    function_name = function_call_state["name"]
    function_name, arguments = rewrite_tool_call(function_name, arguments)
    function_call_state["name"] = function_name

    normalize_tool_call_arguments(arguments, function_name, tool_schemas)
  end

  def normalize_response_tool_calls!(payload, request_payload)
    response = payload["response"]
    return payload unless response.is_a?(Hash)

    tool_schemas = tool_schema_map(request_payload)
    collapse_duplicate_response_function_calls!(response, response_model_name(request_payload, response), tool_schemas)

    payload
  end

  def response_model_name(request_payload, response = nil)
    model_name = response.is_a?(Hash) ? response["model"] : nil
    model_name = request_payload["model"] if model_name.to_s.empty? && request_payload.is_a?(Hash)
    model_name
  end

  def collapse_duplicate_response_function_calls!(response, model_name, tool_schemas, preferred_call_ids = nil)
    return unless response.is_a?(Hash) && response["output"].is_a?(Array)

    seen_signatures = {}
    response["output"] = response["output"].each_with_object([]) do |item, collapsed|
      signature = normalize_response_function_call_item!(item, model_name, tool_schemas)
      if signature && seen_signatures[signature]
        preferred_call_id = preferred_call_ids.is_a?(Hash) ? preferred_call_ids[signature] : nil
        if preferred_call_id && item["call_id"].to_s == preferred_call_id
          collapsed[seen_signatures[signature]] = item
        end
        log_debug "dropped duplicate response function_call name=#{signature[0]} arguments=#{signature[1][0..200]}"
        next
      end

      seen_signatures[signature] = collapsed.length if signature
      collapsed << item
    end
  end

  def normalize_response_function_call_item!(item, model_name, tool_schemas)
    return unless item.is_a?(Hash) && item["type"] == "function_call"

    item["name"], item["arguments"] = rewrite_tool_call(item["name"], item["arguments"])
    item["arguments"] = normalize_tool_call_arguments(item["arguments"], item["name"], tool_schemas)
    return unless duplicate_tool_dedupe_enabled?(item["name"], model_name)

    [item["name"].to_s, item["arguments"].to_s]
  end

  def suppress_response_function_call_item?(item, completed_item, completed_function_calls, function_call_order, model_name)
    return false unless item.is_a?(Hash)
    return false if completed_item
    return false if completed_function_calls.empty?
    return false unless function_call_order.length >= completed_function_calls.length

    duplicate_tool_dedupe_enabled?(item["name"], model_name)
  end

  def collapse_duplicate_function_call_states(function_call_states, model_name, tool_schemas)
    Array(function_call_states).each_with_object([]) do |function_call_state, deduped_states|
      signature = function_call_state_signature(function_call_state, model_name, tool_schemas)
      unless signature
        deduped_states << function_call_state
        next
      end

      duplicate_index = deduped_states.index do |existing_state|
        function_call_state_signature(existing_state, model_name, tool_schemas) == signature
      end

      if duplicate_index
        deduped_states[duplicate_index] = preferred_function_call_state(
          deduped_states[duplicate_index],
          function_call_state,
          tool_schemas
        )
      else
        deduped_states << function_call_state
      end
    end
  end

  def function_call_state_signature(function_call_state, model_name, tool_schemas)
    return unless function_call_state.is_a?(Hash)
    return unless duplicate_tool_dedupe_enabled?(function_call_state["name"], model_name)

    [function_call_state["name"].to_s, function_call_arguments(function_call_state, tool_schemas)]
  end

  def preferred_function_call_state(existing_state, candidate_state, tool_schemas)
    existing_score = function_call_state_score(existing_state, tool_schemas)
    candidate_score = function_call_state_score(candidate_state, tool_schemas)
    return candidate_state if candidate_score >= existing_score

    existing_state
  end

  def function_call_state_score(function_call_state, tool_schemas)
    score = 0
    score += 4 if function_call_state["item_done"]
    score += 2 if function_call_state["arguments_done"]
    score += 1 unless function_call_arguments(function_call_state, tool_schemas).empty?
    score
  end

  def finalize_normalized_stream(normalized_stream, model_name, tool_schemas)
    return normalized_stream unless gemma_model?(model_name)

    events = parse_sse(normalized_stream)
    completed_event = events.find { |event| event[:name] == "response.completed" && event[:json].is_a?(Hash) }
    response = completed_event&.dig(:json, "response")
    return normalized_stream unless response.is_a?(Hash)

    preferred_call_ids = preferred_response_call_ids(events, model_name, tool_schemas)
    collapse_duplicate_response_function_calls!(response, model_name, tool_schemas, preferred_call_ids)
    kept_call_ids = Array(response["output"]).filter_map do |item|
      item["call_id"].to_s if item.is_a?(Hash) && item["type"] == "function_call"
    end
    return normalized_stream if kept_call_ids.empty?

    allowed_item_ids = {}
    sequence_number = 0

    events.filter_map do |event|
      next event[:raw] unless event[:json].is_a?(Hash)

      payload = event[:json].dup
      name = event[:name] || payload["type"]

      case name
      when "response.output_item.added"
        if payload.dig("item", "type") == "function_call"
          call_id = payload.dig("item", "call_id").to_s
          next unless kept_call_ids.include?(call_id)

          item_id = payload.dig("item", "id").to_s
          allowed_item_ids[item_id] = true unless item_id.empty?
        end
      when "response.function_call_arguments.delta", "response.function_call_arguments.done"
        next unless allowed_item_ids[payload["item_id"].to_s]
      when "response.output_item.done"
        if payload.dig("item", "type") == "function_call"
          next unless kept_call_ids.include?(payload.dig("item", "call_id").to_s)
        end
      when "response.completed"
        payload["response"] = response
      end

      payload["sequence_number"] = sequence_number
      sequence_number += 1
      serialize_sse_event(name, payload)
    end.join
  rescue JSON::ParserError, TypeError
    normalized_stream
  end

  def preferred_response_call_ids(events, model_name, tool_schemas)
    events.each_with_object({}) do |event, preferred_call_ids|
      next unless event[:name] == "response.output_item.done"
      item = event.dig(:json, "item")
      next unless item.is_a?(Hash) && item["type"] == "function_call"
      next unless duplicate_tool_dedupe_enabled?(item["name"], model_name)

      signature = [item["name"].to_s, normalize_tool_call_arguments(item["arguments"], item["name"], tool_schemas)]
      preferred_call_ids[signature] = item["call_id"].to_s
    end
  end

  def serialize_sse_event(name, payload)
    clean_payload = strip_nil_values(payload)
    clean_payload["type"] ||= name
    "event: #{name}\ndata: #{JSON.generate(clean_payload)}\n\n"
  end

  def rewrite_tool_call(function_name, arguments)
    case function_name.to_s
    when "execute"
      rewrite_execute_tool_call(arguments)
    when "read_mcp_resource"
      rewrite_local_file_mcp_tool_call(arguments)
    else
      [function_name, arguments.to_s]
    end
  end

  def rewrite_execute_tool_call(arguments)
    parsed_arguments = JSON.parse(arguments.to_s)
    return ["execute", arguments.to_s] unless parsed_arguments.is_a?(Hash)

    command = parsed_arguments["command"].to_s
    return ["execute", arguments.to_s] if command.empty?

    rewritten_arguments = { "cmd" => command }
    justification = parsed_arguments["justification"].to_s
    rewritten_arguments["justification"] = justification unless justification.empty?
    ["exec_command", JSON.generate(rewritten_arguments)]
  rescue JSON::ParserError, TypeError
    ["execute", arguments.to_s]
  end

  def rewrite_local_file_mcp_tool_call(arguments)
    parsed_arguments = JSON.parse(arguments.to_s)
    return ["read_mcp_resource", arguments.to_s] unless parsed_arguments.is_a?(Hash)

    uri = parsed_arguments["uri"].to_s
    uri = parsed_arguments["resource_uri"].to_s if uri.empty?
    path = if uri.start_with?("file://")
      decode_file_uri_path(uri)
    elsif uri.start_with?("/")
      uri
    end
    return ["read_mcp_resource", arguments.to_s] if path.to_s.empty?

    ["exec_command", JSON.generate("cmd" => "cat #{Shellwords.escape(path)}")]
  rescue JSON::ParserError, TypeError, URI::InvalidURIError
    ["read_mcp_resource", arguments.to_s]
  end

  def extract_embedded_tool_call(text)
    value = text.to_s
    return if value.empty?

    match = value.match(EMBEDDED_TOOL_CALL_REGEX)
    return unless match

    parameters = match[2].scan(EMBEDDED_TOOL_PARAM_REGEX).each_with_object({}) do |(key, parameter_value), memo|
      memo[key] = parameter_value.strip
    end
    return if parameters.empty?

    rewritten_name, rewritten_arguments = rewrite_tool_call(match[1], JSON.generate(parameters))
    {
      "name" => rewritten_name,
      "arguments" => rewritten_arguments,
      "remaining_text" => value.sub(match[0], "").strip
    }
  rescue JSON::GeneratorError, TypeError
    nil
  end

  def embedded_tool_call_state(tool_call, message_present:, message_output_index:)
    call_id = "call_#{SecureRandom.hex(8)}"
    {
      "id" => "fc_#{SecureRandom.hex(8)}",
      "call_id" => call_id,
      "name" => tool_call["name"],
      "namespace" => nil,
      "output_index" => message_present ? (message_output_index || 0) + 1 : 0,
      "arguments" => tool_call["arguments"].to_s,
      "arguments_done" => false,
      "item_done" => false,
      "completed_item" => {
        "type" => "function_call",
        "status" => "completed",
        "call_id" => call_id,
        "name" => tool_call["name"],
        "arguments" => tool_call["arguments"].to_s
      },
      "rewritten" => true
    }
  end

  def append_embedded_tool_call_items!(output, function_call_states, tool_schemas)
    output.reject! do |item|
      next false unless item.is_a?(Hash) && item["type"] == "reasoning"

      embedded_tool_call = extract_embedded_tool_call(extract_reasoning_text(item))
      embedded_tool_call && embedded_tool_call["remaining_text"].to_s.empty?
    end

    existing_function_calls = output.select { |item| item.is_a?(Hash) && item["type"] == "function_call" }
    missing_states = Array(function_call_states).drop(existing_function_calls.length)
    missing_states.each do |function_call_state|
      output << function_call_done_event(function_call_state).fetch("item").merge(
        "arguments" => function_call_arguments(function_call_state, tool_schemas)
      )
    end
  end

  def decode_file_uri_path(uri)
    CGI.unescape(URI(uri).path.to_s)
  end

  def tool_schema_map(request_payload)
    tools = request_payload.is_a?(Hash) ? Array(request_payload["tools"]) : []

    tools.each_with_object({}) do |tool, schemas|
      next unless tool.is_a?(Hash) && tool["type"] == "function"

      name = tool["name"].to_s
      parameters = tool["parameters"]
      next if name.empty? || !parameters.is_a?(Hash)

      schemas[name] = parameters
    end
  end

  def normalize_tool_call_arguments(arguments, function_name, tool_schemas = nil)
    return arguments.to_s unless tool_schemas.is_a?(Hash)

    schema = tool_schemas[function_name.to_s]
    return arguments.to_s unless schema.is_a?(Hash)

    parsed_arguments = JSON.parse(arguments.to_s)
    JSON.generate(coerce_schema_value(parsed_arguments, schema))
  rescue JSON::ParserError, TypeError
    arguments.to_s
  end

  def coerce_schema_value(value, schema)
    return value unless schema.is_a?(Hash)

    schema_type = schema_type(schema)

    case schema_type
    when "object"
      coerce_object_value(value, schema)
    when "array"
      return value unless value.is_a?(Array)

      item_schema = schema["items"]
      value.map { |item| coerce_schema_value(item, item_schema) }
    when "integer"
      integer_like?(value) ? value.to_i : value
    when "number"
      if integer_like?(value)
        value.to_i
      elsif number_like?(value)
        value.to_f
      else
        value
      end
    when "boolean"
      case value
      when true, false
        value
      when "true"
        true
      when "false"
        false
      else
        value
      end
    else
      value
    end
  end

  def coerce_object_value(value, schema)
    return value unless value.is_a?(Hash)

    properties = schema["properties"]
    additional_properties = schema["additionalProperties"]

    value.each_with_object({}) do |(key, nested_value), coerced|
      property_schema =
        if properties.is_a?(Hash)
          properties[key]
        elsif additional_properties.is_a?(Hash)
          additional_properties
        end

      coerced[key] = coerce_schema_value(nested_value, property_schema)
    end
  end

  def schema_type(schema)
    type = schema["type"]
    return type if type.is_a?(String)
    return type.find { |value| value != "null" } if type.is_a?(Array)
    return "object" if schema["properties"].is_a?(Hash)

    nil
  end

  def integer_like?(value)
    value.is_a?(Integer) || value.to_s.match?(/\A-?\d+\z/)
  end

  def number_like?(value)
    return true if value.is_a?(Numeric)

    value.to_s.match?(/\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/)
  end

  def function_call_arguments_done_event(function_call_state)
    {
      "arguments" => function_call_arguments(function_call_state),
      "item_id" => function_call_state["id"],
      "name" => function_call_state["name"],
      "output_index" => function_call_state["output_index"]
    }
  end

  def function_call_done_event(function_call_state)
    {
      "item" => {
        "arguments" => function_call_arguments(function_call_state),
        "call_id" => function_call_state["call_id"],
        "name" => function_call_state["name"],
        "type" => "function_call",
        "id" => function_call_state["id"],
        "namespace" => function_call_state["namespace"],
        "status" => "completed"
      },
      "output_index" => function_call_state["output_index"]
    }
  end

  def extract_response_id(response_body, response_headers)
    payload = parse_json_body(response_body)
    return payload["id"] if payload.is_a?(Hash) && payload["id"].is_a?(String)
    return payload.dig("response", "id") if payload.is_a?(Hash)
    return nil unless sse_response?(response_body, response_headers)

    parse_sse(response_body).each do |event|
      response_id = event.dig(:json, "response", "id")
      return response_id if response_id.is_a?(String) && !response_id.empty?
    end

    nil
  end

  def content_extension(content, content_type)
    return ".sse" if content_type.to_s.include?("text/event-stream") || content.to_s.start_with?("event:")
    return ".json" if content_type.to_s.include?("json") || json_like?(content)

    ".txt"
  end

  def json_like?(content)
    stripped = content.to_s.lstrip
    stripped.start_with?("{", "[")
  end

  def log_debug(message)
    warn "vllm-shim-tool-call: #{message}" if ENV["VLLM_SHIM_TOOL_CALL_DEBUG"]
  end

  def write_debug_file(path, content)
    return unless ENV["VLLM_SHIM_TOOL_CALL_DEBUG"]

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  rescue StandardError => e
    warn "vllm-shim-tool-call: failed to write debug file #{path}: #{e.message}"
  end

  def append_debug_file(path, content)
    return unless ENV["VLLM_SHIM_TOOL_CALL_DEBUG"]

    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, "a") { |file| file.write(content) }
  rescue StandardError => e
    warn "vllm-shim-tool-call: failed to append debug file #{path}: #{e.message}"
  end

  def strip_nil_values(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), clean|
        next if item.nil?

        clean[key] = strip_nil_values(item)
      end
    when Array
      value.map { |item| strip_nil_values(item) }
    else
      value
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Qwen3CoderToolCallShim.run!
else
  run Qwen3CoderToolCallShim
end
