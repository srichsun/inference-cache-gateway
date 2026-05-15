#!/usr/bin/env ruby
# Usage: ruby upstream_test.rb [single|bulk]
# Default: bulk
#
# Sends real HTTP requests directly to the upstream rate-api to observe its
# actual behaviour. Run this any time the upstream changes to refresh findings.
#
# --- What it does ---
#
# 1. Hits upstream repeatedly (up to 1100 times) until HTTP 429 (quota exhausted).
#    single mode: 1 combo per request (Summer/FloatingPointResort/SingletonRoom)
#    bulk mode:   all 36 combos per request
#
# 2. Classifies each response into a pattern, e.g.:
#      TIMEOUT
#      HTTP 200 | ok — 36 int rates
#      HTTP 200 | error_body | {"message":"Failed to process rates...",...}
#      HTTP 200 | 36/36 entries rate field absent from response
#      HTTP 429 | {"error":"Rate limit exceeded (1000/day)"}
#    First occurrence of each new pattern prints the full body to stdout and log.
#    Subsequent occurrences only increment the count — no repeated body output.
#
# 3. Replaces the matching ## Test 1 or ## Test 2 section in UPSTREAM_BEHAVIOR.md
#    with the updated pattern counts and date. All other sections are preserved.

require "net/http"
require "json"
require "time"

MODE = ARGV[0] || "bulk"
raise "Usage: ruby upstream_test.rb [single|bulk]" unless %w[single bulk].include?(MODE)

RATE_API_URL = "http://rate-api:8080"
TOKEN        = ENV.fetch("RATE_API_TOKEN", "04aa6f42aa03f220c2ae9a276cd68c62")
DATE_TAG     = Time.now.strftime("%Y-%m-%d")
LOG_FILE     = "/rails/#{MODE}_upstream_test.log"
BEHAVIOR_MD  = "/rails/UPSTREAM_BEHAVIOR.md"
TIMEOUT      = 5

PERIODS = %w[Summer Autumn Winter Spring].freeze
HOTELS  = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
ROOMS   = %w[SingletonRoom BooleanTwin RestfulKing].freeze

ALL_COMBINATIONS = PERIODS.product(HOTELS, ROOMS).map do |p, h, r|
  { period: p, hotel: h, room: r }
end.freeze

SINGLE_COMBO = [{ period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }].freeze

# --- HTTP ---

def send_request(attributes)
  uri  = URI("#{RATE_API_URL}/pricing")
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = TIMEOUT
  http.read_timeout = TIMEOUT
  req  = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json", "token" => TOKEN)
  req.body = { attributes: attributes }.to_json
  http.request(req)
rescue Net::OpenTimeout, Net::ReadTimeout
  :timeout
end

# --- Response classification ---

def classify(status, body, mode)
  return "TIMEOUT" if body == :timeout
  return "HTTP #{status} | #{body.to_json[0..100]}" if status != 200

  rates = body["rates"]
  return "HTTP 200 | error_body | #{body.to_json[0..100]}" if rates.nil?
  return "HTTP 200 | empty rates array" if rates.empty?

  missing = rates.count { |r| r["rate"].nil? }
  str     = rates.count { |r| r["rate"].is_a?(String) }
  int     = rates.count { |r| r["rate"].is_a?(Integer) }
  total   = rates.size

  if missing > 0
    "HTTP 200 | #{missing}/#{total} entries rate field absent from response"
  elsif str > 0
    "HTTP 200 | ok — #{int} int, #{str} str rates"
  else
    "HTTP 200 | ok — #{int} int rates"
  end
end

# --- Run test ---

attributes  = MODE == "single" ? SINGLE_COMBO : ALL_COMBINATIONS
combo_label = MODE == "single" ? "1 combination (Summer/FloatingPointResort/SingletonRoom)" : "all 36 combinations"

seen   = {}
counts = Hash.new(0)
log    = File.open(LOG_FILE, "w")
log.sync = true
$stdout.sync = true

log.puts "# #{MODE} upstream test — #{Time.now.strftime("%Y-%m-%d %H:%M")} UTC"
log.puts "# #{combo_label}"
log.puts ""

puts "Mode: #{MODE} | Each request sends #{combo_label}"
puts "Logging to #{LOG_FILE}"
puts "---"

last_call = 0
(1..1100).each do |i|
  last_call = i
  response  = send_request(attributes)

  if response == :timeout
    line = "##{i.to_s.rjust(4, '0')} EXCEPTION: timed out"
    log.puts line
    $stdout.puts line
    counts["TIMEOUT"] += 1
    next
  end

  status = response.code.to_i
  body   = JSON.parse(response.body) rescue { "raw" => response.body[0..100] }
  label  = classify(status, body, MODE)
  is_new = !seen.key?(label)
  seen[label] = true
  counts[label] += 1

  prefix  = is_new ? "[NEW]" : "     "
  summary = "#{prefix} ##{i.to_s.rjust(4, '0')} | #{label}"
  log.puts summary
  log.puts "       body: #{body.to_json}" if is_new || status != 200
  $stdout.puts summary if is_new || status != 200

  break if status == 429
end

log.puts "\n--- pattern summary (#{last_call} total calls) ---"
counts.sort_by { |_, v| -v }.each { |k, v| log.puts "  #{v.to_s.rjust(5)}x  #{k}" }
log.close

# --- Update UPSTREAM_BEHAVIOR.md ---

def build_section(mode, date_tag, total_calls, counts)
  combo_label = mode == "single" ? "1 combination per request" : "all 36 combinations per request"
  log_file    = "#{mode}_upstream_test.log"

  rows = counts.sort_by { |_, v| -v }.map do |label, count|
    "| #{count.to_s.rjust(5)} | #{label} |"
  end.join("\n")

  <<~SECTION
    ## #{mode == "single" ? "Test 1" : "Test 2"} — #{mode == "single" ? "Single rate" : "Bulk rates"} (#{total_calls} calls)

    Date: #{date_tag} | #{combo_label}
    Log: `#{log_file}`

    | Count | Pattern |
    |---|---|
    #{rows}
  SECTION
end

new_section   = build_section(MODE, DATE_TAG, last_call, counts)
section_title = MODE == "single" ? "## Test 1" : "## Test 2"

existing = File.exist?(BEHAVIOR_MD) ? File.read(BEHAVIOR_MD) : ""

# Replace only the matching ## Test N section, preserving everything else.
# The section ends at the next ## header or end of file.
pattern = /^## Test #{MODE == "single" ? 1 : 2}.*?(?=^## |\z)/m

new_content = if existing.match?(pattern)
  existing.gsub(pattern, new_section)
else
  existing.rstrip + "\n\n" + new_section
end

File.write(BEHAVIOR_MD, new_content)

puts "\nDone. Updated: #{BEHAVIOR_MD}"
