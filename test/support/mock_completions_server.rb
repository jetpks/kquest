# frozen_string_literal: true

require "socket"
require "json"

# Provenance: the gem's own spec harness —
# repos/fast-llm/gems/completions/spec/support/mock_llm_server.rb (via the
# landed kquest test/support/mock_embeddings_server.rb discipline) — the
# hermetic TCP mock rig lineage: TCPServer on 127.0.0.1 ephemeral port, one
# request per connection, `Connection: close` declared on every responder,
# TCP_NODELAY on accepted sockets, EPIPE swallowed, requests captured as
# {method:, path:, headers:, body:} via captured_requests /
# captured_request_logs (the drain discipline: consume on read — a second
# drain sees only what arrived after the first). The bge/emb specifics are
# removed; the SCRIPT vocabulary is the I13 chat-completions one.
#
# A hermetic mock OpenAI-compatible chat-completions endpoint over TCP
# (127.0.0.1, ephemeral port): the engine under test (Async::HTTP over the
# chat wire) talks to it. The gem POSTs {base}/chat/completions with
# stream: true + stream_options: {include_usage: true}.
#
# Wire reply: HTTP 200 text/event-stream, chunked; SSE `data: <json>\n\n`
# lines — OpenAI deltas ({choices: [{delta: {...}, finish_reason?}]}) plus a
# trailing usage chunk, terminated by `data: [DONE]`.
#
# Scripting (a list of typed response specs, shifted per request):
#   {type: :text, content: "…"}            (assistant text, finish stop)
#   {type: :tool_use, tool_calls: [{id:, name:, arguments: hash_or_string}]}
#                                          (tool_call blocks, finish tool_calls)
#   {type: :empty}                         (2xx, empty content, no tool calls,
#                                           finish stop — FM-01's exact signature)
#   {type: :status, status:, message:, headers: {}}
#                                          (a creation failure: 429/5xx/401/403/404/
#                                           400-context-pattern; optional Retry-After /
#                                           x-should-retry headers)
#   {type: :abort_mid_stream, after: 2}    (200 + SSE blocks, then a TCP abort —
#                                           the FM-15 salvage; the usage chunk rides
#                                           BEFORE the abort so the partial carries usage)
#   {type: :missing_finish}                (stream ends WITHOUT finish_reason — FM-13;
#                                           the usage chunk rides so the salvage has usage)
#   {type: :bad_chunk}                     (a malformed SSE payload — FM-14's
#                                           dropped-chunk counter; the stream completes normally)
#   {type: :slow_ttfb, delay:}             (a delayed first byte — FM-05's watchdog)
#   {type: :never_respond}                 (accept + read, never reply — teardown-safe)
# A script-less connection gets a default empty :text reply.
class MockCompletionsServer
  attr_reader :port, :requests, :request_logs

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = Queue.new
    @request_logs = Queue.new
    @script = []
    @template = []
  end

  def script(response_specs)
    @template = response_specs.dup
    @script = response_specs.dup
    self
  end

  # Reset the shifting script queue to the template (fresh app, same bytes).
  def rearm!
    @script = @template.dup
    self
  end

  def start
    @accept_thread = Thread.new do
      loop do
        client = @server.accept
        Thread.new(client) { |io| serve(io) }
      end
    rescue StandardError
      nil # socket closed at teardown
    end
    self
  end

  def stop
    @server.close
    @accept_thread&.join(1)
  rescue IOError
    nil
  end

  def url
    "http://127.0.0.1:#{@port}/v1"
  end

  # Drains and returns all captured request bodies (parsed JSON).
  def captured_requests
    list = []
    list << @requests.pop(true) until @requests.empty?
    list
  end

  # Drains and returns all captured request entries: full wire facts
  # (method, path, notable headers, parsed body) per request.
  def captured_request_logs
    list = []
    list << @request_logs.pop(true) until @request_logs.empty?
    list
  end

  private

  NOTABLE_HEADERS = %w[authorization content-type accept user-agent].freeze

  def serve(io)
    begin
      io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    rescue Errno::EINVAL, Errno::EOPNOTSUPP, Errno::ENOPROTOOPT
      nil
    end

    request_line = io.gets
    # A connection that sends no request line (empty TCP connect, prober,
    # port scan) consumes nothing: no script shift, no log entry, no response.
    return if request_line.nil? || request_line.strip.empty?

    headers = {}
    while (line = io.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.to_s.strip.downcase] = value.to_s.strip
    end
    body = io.read(headers["content-length"].to_i)
    parsed_body = body.to_s.empty? ? nil : JSON.parse(body)
    entry = {
      method: request_line.to_s.split(" ")[0],
      path: request_line.to_s.split(" ")[1],
      headers: headers.slice(*NOTABLE_HEADERS),
      body: parsed_body,
    }
    @request_logs << entry
    @requests << parsed_body unless parsed_body.nil?

    spec = @script.shift || {type: :text, content: ""}
    case spec[:type]
    when :status then respond_status(io, spec)
    when :slow_ttfb
      sleep(spec[:delay] || 2)
      respond_stream(io, {type: :text, content: ""})
    when :never_respond then sleep 30 # never reply; the test tears it down
    when :abort_mid_stream then respond_stream(io, spec)
    when :missing_finish then respond_stream(io, spec)
    when :bad_chunk then respond_stream(io, spec)
    else respond_stream(io, spec)
    end
  rescue Errno::EPIPE
    # The client was torn down mid-response; a dead socket must not
    # pollute suite stderr.
    nil
  ensure
    io.close rescue nil
  end

  # A creation failure (non-2xx): the gem maps it through the frozen error
  # taxonomy; the optional headers map lands verbatim (the Retry-After /
  # x-should-retry triggers).
  def respond_status(io, spec)
    payload = {error: {message: spec[:message] || "provider failure", type: "provider_error"}}.to_json
    status = spec[:status] || 500
    extra = (spec[:headers] || {}).map { |name, value| "#{name}: #{value}\r\n" }.join
    io.write("HTTP/1.1 #{status} Error\r\nContent-Type: application/json\r\nConnection: close\r\n" \
      "Content-Length: #{payload.bytesize}\r\n#{extra}\r\n#{payload}")
  end

  USAGE = {prompt_tokens: 11, completion_tokens: 7, total_tokens: 18}.freeze

  def respond_stream(io, spec)
    io.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n" \
      "Transfer-Encoding: chunked\r\n\r\n")
    deltas = deltas_for(spec)
    deltas.each do |delta|
      write_sse(io, delta)
    end
    write_sse(io, {usage: USAGE})
    return if spec[:type] == :abort_mid_stream

    # The abort arm closes WITHOUT the terminating `0\r\n\r\n` chunk and
    # WITHOUT [DONE] — the client's body read dies mid-stream with a
    # NETWORK_ERRORS-class exception (the FM-15 salvage path).
    write_chunk(io, "data: [DONE]\n\n")
    io.write("0\r\n\r\n")
  end

  def deltas_for(spec)
    deltas = [{choices: [{delta: {role: "assistant"}}]}]

    case spec[:type]
    when :text
      deltas << {choices: [{delta: {content: spec[:content]}}]} unless spec[:content].to_s.empty?
      deltas << {choices: [{delta: {}, finish_reason: "stop"}]}
    when :empty
      deltas << {choices: [{delta: {content: ""}}]}
      deltas << {choices: [{delta: {}, finish_reason: "stop"}]}
    when :tool_use
      Array(spec[:tool_calls]).each_with_index do |call, i|
        deltas << {choices: [{delta: {tool_calls: [{index: i, id: call[:id], type: "function",
                                                    function: {name: call[:name], arguments: ""}}]}}]}
        arguments = call[:arguments].is_a?(String) ? call[:arguments] : JSON.generate(call[:arguments])
        deltas << {choices: [{delta: {tool_calls: [{index: i, function: {arguments: arguments}}]}}]}
      end
      deltas << {choices: [{delta: {}, finish_reason: "tool_calls"}]}
    when :missing_finish
      deltas << {choices: [{delta: {content: spec[:content] || "partial"}}]}
      # NO finish_reason chunk: the stream ends without the finish the
      # dialect expects (FM-13) — the [DONE] tail still rides.
    when :bad_chunk
      deltas << {choices: [{delta: {content: "tolerated "}}]}
      deltas << :malformed # a payload no repair pass can fix — dropped + counted (FM-14)
      deltas << {choices: [{delta: {content: "stream"}}]}
      deltas << {choices: [{delta: {}, finish_reason: "stop"}]}
    when :abort_mid_stream
      deltas << {choices: [{delta: {content: spec[:content] || "partial before the abort"}}]}
      # the caller aborts right after these deltas (no finish, no [DONE])
    end
    deltas
  end

  def write_sse(io, delta)
    if delta == :malformed
      write_chunk(io, "data: not-json{{{ no repair for this\n\n")
      return
    end

    write_chunk(io, "data: #{JSON.generate(delta)}\n\n")
  rescue Errno::EPIPE
    nil
  end

  def write_chunk(io, payload)
    io.write(format("%x\r\n%s\r\n", payload.bytesize, payload))
    io.flush
  rescue Errno::EPIPE
    nil
  end
end
