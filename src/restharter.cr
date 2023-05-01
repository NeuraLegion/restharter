require "har"
require "json"
require "http"
require "colorize"

module Restharter
  VERSION = "0.1.1"

  class Run
    @host : String
    @scan_id : String

    def initialize(scan_url : String, @api_key : String)
      uri = URI.parse(scan_url)

      uri_host = uri.host
      unless uri.host
        puts "Error: Missing host"
        exit 1
      end

      @host = uri.host.to_s
      unless uri.path
        puts "Error: Missing scan ID"
        exit 1
      end

      uri_path = Path.new(uri.path.to_s)
      @scan_id = uri_path.parts[2].to_s.strip("/")
      puts "Cluster: #{@host}"
      puts "Scan ID: #{@scan_id}"

      resp = get_scan
      if resp.status_code == 404
        puts "Error: Scan #{@scan_id} not found"
        exit 1
      elsif resp.status_code == 401
        puts "Error: Invalid API key"
        exit 1
      end

      # Get all entry points, taking pagination into account
      total = 0
      index = 0
      begin
        response = get_eps.body.to_s
        eps_info = JSON.parse(response)
      rescue e
        puts "Error in response: #{response}"
        raise e
      end
      total = eps_info["total"].as_i
      if total == 0
        puts "Error: the scan has no Entry Points to process"
        exit 1
      end

      puts "Found #{total} entry points, building HAR file..."
      har = HAR::Log.new

      while index < total
        eps_info["items"].as_a.map(&.as_h.["id"]).each do |id|
          index += 1
          # Adding new EP to the log
          ep_resp = get_ep(id.as_s)
          unless ep_resp.status_code == 200
            puts "Error: Error getting entry point #{id}: #{ep_resp.status_code} #{ep_resp.body.to_s}"
            exit 1
          end
          ep = JSON.parse(ep_resp.body.to_s)
          request = ep["request"].as_h
          response = ep["response"].as_h

          percentage = 100.0 * (index / total)
          puts "[%6.2f %%] %s (%s) %s" % {percentage, ep["id"], request["method"], request["url"]}

          # Build Request
          har_request = HAR::Request.new(
            url: request["url"].as_s,
            method: request["method"].as_s,
            http_version: "HTTP/1.1"
          )

          request["headers"].as_h.each do |k, v|
            case v
            when String
              har_request.headers << HAR::Header.new(name: k, value: v.as_s)
            when Array
              v.each do |v2|
                har_request.headers << HAR::Header.new(name: k, value: v.first.as_s)
              end
            end
          end
          if request["body"]?
            har_request.post_data = HAR::PostData.new(
              text: request["body"].as_s,
              mime_type: request["headers"].as_h["Content-Type"]?.try &.as_s? || ""
            )
          end

          # Build Response
          har_response = HAR::Response.new(
            status: response["status"].as_i,
            status_text: "",
            http_version: "HTTP/1.1",
            content: HAR::Content.new(
              text: response["body"]?.try &.as_s || "",
              size: 0
            ),
            redirect_url: "",
          )

          response["headers"].as_h.each do |k, v|
            case v
            when String
              har_response.headers << HAR::Header.new(name: k, value: v.as_s)
            when Array
              v.each do |v2|
                har_response.headers << HAR::Header.new(name: k, value: v.first.as_s)
              end
            end
          end

          # Build Entry
          har.entries << HAR::Entry.new(
            request: har_request,
            response: har_response,
            time: 0.0,
            timings: HAR::Timings.new(
              send: 0.0,
              wait: 0.0,
              receive: 0.0
            ),
          )
        end

        # Updating the list of EPs with a fresh pack
        ep_id = eps_info["items"][-1]["id"].as_s
        ep_created_at = eps_info["items"][-1]["createdAt"].as_s
        eps_info = JSON.parse(get_eps(ep_id, ep_created_at).body.to_s)
      end

      puts "\nDone building HAR file, writing to disk..."
      full_har = HAR::Data.new(log: har)
      File.write("restharter.har", full_har.to_json)
      puts "Done writing HAR file to disk"

      puts "Do you wish to restart the scan with this HAR file? [Y/N]"
      answer = STDIN.gets.to_s.strip
      if answer.downcase != "y"
        puts "Exiting..."
        exit 0
      end
      # restart scan with har file
      puts "Restarting scan with HAR file..."
      id = upload_har(full_har)
      resp = restart_scan(id)
      if resp.status_code == 201
        puts "Scan restarted successfully: #{resp.body.to_s}"
      else
        puts "Error restarting scan: #{resp.status_code} #{resp.body.to_s}"
      end
    end

    private def headers : HTTP::Headers
      HTTP::Headers{
        "Authorization" => "Api-Key #{@api_key}",
        "Content-Type"  => "application/json",
        "Accept"        => "application/json",
      }
    end

    private def restart_scan(file_id : String) : HTTP::Client::Response
      scan_configs = get_config.as_h
      unless scan_configs["discoveryTypes"].as_a.includes?("crawler")
        puts "Scan is not a crawler scan, aborting"
        exit 1
      end
      scan_configs["discoveryTypes"].as_a.clear
      scan_configs["discoveryTypes"].as_a << JSON::Any.new("archive")
      scan_configs["fileId"] = JSON::Any.new(file_id)
      # create hosts filter
      filter = Array(JSON::Any).new
      scan_configs["crawlerUrls"].as_a.each do |url|
        filter << JSON::Any.new(URI.parse(url.as_s).host.to_s)
      end
      scan_configs.reject!("crawlerUrls")
      scan_configs["hostsFilter"] = JSON::Any.new(filter)

      body = <<-JSON
        {"config":#{scan_configs.to_json}}
        JSON

      puts "Restarting scan with body: #{body}"
      resp = HTTP::Client.post("https://#{@host}/api/v1/scans/#{@scan_id}/retest", headers: headers, body: body)
    end

    private def upload_har(har : HAR::Data) : String
      post_headers = headers
      body_io = IO::Memory.new
      file_io = IO::Memory.new(har.to_json)
      multipart_headers = HTTP::Headers.new
      multipart_headers["Content-Type"] = "application/har+json"
      HTTP::FormData.build(body_io, MIME::Multipart.generate_boundary) do |builder|
        builder.file(
          "file",
          file_io,
          HTTP::FormData::FileMetadata.new(filename: "#{Random::Secure.hex}.har"),
          multipart_headers
        )
        post_headers["Content-Type"] = builder.content_type
      end
      resp = HTTP::Client.post("https://#{@host}/api/v1/files", headers: post_headers, body: body_io.to_s)
      unless resp.success?
        puts "Error uploading HAR: #{resp.status_code} (#{resp.status})"
        puts resp.body
      else
        puts "Done uploading HAR file #{resp.status_code}"
      end
      JSON.parse(resp.body.to_s)["id"].to_s
    end

    private def get_config : JSON::Any
      resp = fetch("https://#{@host}/api/v1/scans/#{@scan_id}/config")
      unless resp.status_code == 200
        puts "Error: Error getting scan config: #{resp.status_code} #{resp.body.to_s}"
        exit 1
      end
      JSON.parse(resp.body.to_s)
    end

    private def get_ep(ep_id : String) : HTTP::Client::Response
      fetch("https://#{@host}/api/v1/scans/#{@scan_id}/entry-points/#{ep_id}")
    end

    private def get_eps(next_id : String? = nil, next_created_at : String? = nil) : HTTP::Client::Response
      url = String.build do |s|
        s << "https://#{@host}/api/v2/scans/#{@scan_id}/entry-points"
        if next_id && next_created_at
          s << "?nextId=#{next_id}&nextCreatedAt=#{next_created_at}"
        end
      end
      fetch(url)
    end

    private def get_scan : HTTP::Client::Response
      fetch("https://#{@host}/api/v1/scans/#{@scan_id}")
    end

    private def fetch(url)
      h = headers

      # Uncomment to see more debug details
      # puts "Sending request [GET] #{url}"
      # puts "Request headers:"
      # h.each do |name, values|
      #   values.each do |value|
      #     puts "  - #{name}: #{value}"
      #   end
      # end

      response = HTTP::Client.get(url, headers: h)

      # Uncomment to see more debug details
      # puts "Received (#{response.status_code})"
      # unless response.success?
      #   puts response.body
      # end
      # puts "Response headers:"
      # response.headers.each do |name, values|
      #   values.each do |value|
      #     puts "  - #{name}: #{value}"
      #   end
      # end
      response
    end
  end
end

# Usage
# restharter https://cluster.example.com/api/v1/scans/12345678-1234-1234-1234-123456789012 api_key
usage = "Usage: restharter <scan_url> <api_key>"
unless ARGV.size == 2
  puts usage
  exit 1
end

Restharter::Run.new(ARGV[0], ARGV[1])
