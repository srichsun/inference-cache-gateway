# Background:
#   Rails default logging outputs multiple lines per request — hard for
#   machines to parse and difficult to query in ELK/Datadog/CloudWatch without additional parsing.
#
# Problem:
#   After deploying, you can't answer: "Is the cache protecting quota?"
#   or "Is upstream getting slower?" without structured, searchable logs.
#
# Solution:
#   Lograge compresses each request into a single JSON line with two
#   custom fields that enable production dashboards and alerts:
#   - cache_status: "hit" or "miss" — monitor cache hit rate, detect quota risk
#   - upstream_latency_ms: track upstream speed, alert before timeouts occur
#
# Example output:
#   {"method":"GET","path":"/api/v1/pricing","status":200,"duration":12.3,
#    "cache_status":"hit","upstream_latency_ms":null}

Rails.application.configure do
  config.lograge.enabled = true
  config.lograge.formatter = Lograge::Formatters::Json.new

  # Keep original Rails log alongside lograge (useful in development).
  # In production, set this to false to avoid duplicate output.
  config.lograge.keep_original_rails_log = true

  # Pull custom fields from the controller's append_info_to_payload.
  config.lograge.custom_options = lambda do |event|
    {
      cache_status: event.payload[:cache_status],
      upstream_latency_ms: event.payload[:upstream_latency_ms],
      params: event.payload[:params]&.except("controller", "action")
    }
  end
end
