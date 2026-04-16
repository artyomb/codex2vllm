# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"
gem "rack", ">= 3.0", "< 4"
require "sinatra/base"
require "faraday"
require "faraday/retry"
require "faraday/net_http_persistent"

class Qwen3CoderToolCallShim < Sinatra::Base
  HOP_BY_HOP_HEADERS = %w[
    connection keep-alive proxy-authenticate proxy-authorization te trailer
    transfer-encoding upgrade host content-length
  ].freeze

  SYSTEM_ROLES = %w[developer system].freeze
  TEXT_PART_TYPES = %w[input_text output_text text].freeze
  TRACE_PREVIEW_LIMIT = 2_000

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
    raw_body = request.body.read
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

    response_body = normalize_responses_response(upstream_response.body, upstream_response.headers)
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

    dropped_items = []
    payload["input"] = payload["input"].filter_map do |item|
      result = normalize_input_item(item)
      dropped_items << item unless result
      result
    end

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

  def normalize_input_item(item)
    return item unless item.is_a?(Hash)

    case item["type"]
    when "reasoning"
      normalize_reasoning_input_item(item)
    when "message"
      normalize_message_input_item(item)
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

    item["id"] ||= "msg_#{SecureRandom.hex(8)}"
    item["status"] ||= "in_progress"

    Array(item["content"]).each do |content|
      next unless content.is_a?(Hash) && content["type"] == "output_text"

      content["annotations"] ||= []
    end

    item
  end

  def normalize_role_input_item(item)
    item = strip_nil_values(item.dup)
    item["role"] = "system" if item["role"] == "developer"

    return item unless item["role"] == "assistant" && item["content"].is_a?(Array)

    Array(item["content"]).each do |content|
      next unless content.is_a?(Hash) && content["type"] == "output_text"

      content["annotations"] ||= []
    end

    item
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
        else
          "unsupported item"
        end
      else
        "not a hash"
      end

      warn "vllm-shim-tool-call: dropped item ##{index}: #{reason} [#{item.inspect[0..200]}]"
    end
  end

  def normalize_responses_response(raw_body, response_headers)
    return normalize_responses_stream(raw_body) if sse_response?(raw_body, response_headers)

    payload = JSON.parse(raw_body)
    return raw_body unless payload.is_a?(Hash)

    log_response_summary(payload) if ENV["VLLM_SHIM_TOOL_CALL_DEBUG"]
    JSON.generate(strip_nil_values(payload))
  rescue JSON::ParserError, TypeError
    raw_body
  end

  def sse_response?(raw_body, response_headers)
    response_headers["content-type"].to_s.include?("text/event-stream") ||
      raw_body.to_s.start_with?("event: response.")
  end

  def normalize_responses_stream(raw_body)
    events = parse_sse(raw_body)
    completed_response = events.find { |event| event[:name] == "response.completed" }&.dig(:json, "response")
    message_item = Array(completed_response&.fetch("output", nil)).find { |item| item["type"] == "message" }
    message_id = message_item&.fetch("id", nil) || "msg_#{SecureRandom.hex(8)}"
    message_output_index = Array(completed_response&.fetch("output", nil)).index(message_item) || 1

    sequence_number = 0
    text = +""
    text_started = false
    text_done = false
    message_done = false
    upstream_message_added = events.any? { |event| event.dig(:json, "item", "type") == "message" }
    message_added = false
    message_injected = false

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
        if payload.dig("item", "type") == "message"
          message_added = true
          emit.call(name, message_added_event(message_id, message_output_index))
        else
          emit.call(name, payload)
        end
      when "response.content_part.added"
        if payload["output_index"] == message_output_index || payload["item_id"]
          emit.call(name, content_part_added_event(message_id, message_output_index))
        else
          emit.call(name, payload)
        end
      when "response.output_text.delta"
        prefix = +""
        unless text_started
          unless message_added
            prefix << emit.call("response.output_item.added", message_added_event(message_id, message_output_index))
            message_injected = true
          end
          prefix << emit.call("response.content_part.added", content_part_added_event(message_id, message_output_index))
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
        text_done = true
        emit.call(name, output_text_done_event(message_id, message_output_index, text))
      when "response.content_part.done"
        if payload["item_id"] == message_id || payload["output_index"] == message_output_index
          emit.call(name, content_part_done_event(message_id, message_output_index, text))
        else
          emit.call(name, payload)
        end
      when "response.output_item.done"
        if payload.dig("item", "type") == "message"
          message_done = true
          emit.call(name, message_done_event(message_id, message_output_index, text))
        else
          emit.call(name, payload)
        end
      when "response.completed"
        suffix = +""
        suffix << emit.call("response.output_text.done", output_text_done_event(message_id, message_output_index, text)) if text_started && !text_done
        suffix << emit.call("response.content_part.done", content_part_done_event(message_id, message_output_index, text)) if text_started
        suffix << emit.call("response.output_item.done", message_done_event(message_id, message_output_index, text)) if text_started && !message_done
        suffix << emit.call(name, normalize_completed_response_payload(payload, message_id, message_output_index, text))
      else
        emit.call(name, payload)
      end
    end.join

    log_stream_summary(text_started, upstream_message_added, text) if ENV["VLLM_SHIM_TOOL_CALL_DEBUG"]
    normalized
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

  def normalize_completed_response_payload(payload, message_id, output_index, text)
    response = payload["response"]
    return payload unless response.is_a?(Hash)

    output = Array(response["output"])
    message_item = output.find { |item| item["type"] == "message" }
    return payload unless message_item

    message_payload = message_done_event(message_id, output_index, text).fetch("item")
    message_item.replace(message_payload)
    payload
  end

  def normalize_leading_message_delta(delta, current_text)
    return delta unless current_text.empty?

    delta.sub(/\A(?:\r?\n)+/, "")
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
