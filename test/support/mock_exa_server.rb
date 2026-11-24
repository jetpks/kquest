# frozen_string_literal: true

require "socket"
require "json"

# The web tools' hermetic mock rig (I14 — NO live web call anywhere; the
# mock rig IS the wire for tests). Same lineage as
# test/support/mock_embeddings_server.rb (the provenance note there
# applies): TCPServer on 127.0.0.1 ephemeral port, one request per
# connection, `Connection: close` on every responder, TCP_NODELAY on
# accepted sockets, EPIPE swallowed, request logs captured as
# {method:, path:, headers:, body:} via captured_request_logs (drain
# discipline).
#
# The Exa-shaped surface the WebWire seam speaks:
# - POST {base}/search   {query, numResults, …} →
#     200 {"results": [{"url":…, "title":…, "text":…}, …]}
# - POST {base}/contents {urls: [url]}          →
#     200 {"results": [{"url":…, "title":…, "text":…}]}
#
# Scripting: pass a list of response specs, each either
#   {type: :results, results: [{url:, title:, text:}, …]}  (HTTP 200)
#   {type: :error, status: 429, message: "..."}            (HTTP error)
# A script-less connection gets a default empty results reply.
class MockExaServer
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

  def url = "http://127.0.0.1:#{@port}"

  # Drains and returns all captured request bodies (parsed JSON).
  def captured_requests
    list = []
    list << @requests.pop(true) until @requests.empty?
    list
  end

  # Drains and returns all captured request entries: full wire facts
  # (method, path, headers, parsed body) per request.
  def captured_request_logs
    list = []
    list << @request_logs.pop(true) until @request_logs.empty?
    list
  end

  private

  NOTABLE_HEADERS = %w[authorization content-type accept].freeze

  def serve(io)
    begin
      io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    rescue Errno::EINVAL, Errno::EOPNOTSUPP, Errno::ENOPROTOOPT
      nil
    end

    request_line = io.gets
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

    spec = @script.shift || {type: :results, results: []}
    case spec[:type]
    when :error then respond_error(io, spec)
    when :results then respond_results(io, spec.fetch(:results))
    end
  rescue Errno::EPIPE
    nil
  ensure
    io.close rescue nil
  end

  def respond_results(io, results)
    payload = JSON.generate({"results" => results.map { |r|
      {"url" => r[:url] || r["url"], "title" => r[:title] || r["title"], "text" => r[:text] || r["text"]}
    }})
    io.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n" \
      "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}")
  end

  def respond_error(io, spec)
    payload = {error: {message: spec[:message], type: "invalid_request_error"}}.to_json
    status = spec[:status] || 400
    io.write("HTTP/1.1 #{status} Bad Request\r\nContent-Type: application/json\r\nConnection: close\r\n" \
      "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}")
  end
end
