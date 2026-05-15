module Api
  module V1
    class PricingController < ApplicationController
      VALID_PERIODS = PricingConstants::VALID_PERIODS
      VALID_HOTELS  = PricingConstants::VALID_HOTELS
      VALID_ROOMS   = PricingConstants::VALID_ROOMS

      before_action :validate_params

      def index
        @service = Api::V1::PricingService.new(period: params[:period], hotel: params[:hotel], room: params[:room])
        @service.run

        if @service.valid?
          render json: { rate: @service.result }
        else
          # Each error carries its own HTTP status so the client gets meaningful codes
          # (502, 504, 429) rather than a generic 400 for every upstream failure.
          err = @service.errors.first

          if err[:status] == :too_many_requests
            # Tell the client exactly when the quota resets (UTC midnight)
            # so they know when to retry instead of hammering the endpoint.
            # Matches QuotaGuard's expire time so client and server agree.
            midnight_utc = (Time.now.utc.to_date + 1).to_time(:utc)
            seconds_until_midnight = midnight_utc.to_i - Time.now.utc.to_i
            response.set_header("Retry-After", seconds_until_midnight.to_s)
          end

          render json: { error: err[:message] }, status: err[:status]
        end
      end

      private

      # Feed cache_status and upstream_latency_ms into the Lograge payload
      # so each request log line includes these fields automatically.
      # Why these two: cache_status tells you if quota is being protected,
      # upstream_latency_ms tells you if upstream is getting slower.
      def append_info_to_payload(payload)
        super
        payload[:cache_status] = @service&.cache_status
        payload[:upstream_latency_ms] = @service&.upstream_latency_ms
      end

      # Reject unknown values early so the upstream never sees invalid input.
      def validate_params
        unless params[:period].present? && params[:hotel].present? && params[:room].present?
          return render json: { error: "Missing required parameters: period, hotel, room" }, status: :bad_request
        end

        unless VALID_PERIODS.include?(params[:period])
          return render json: { error: "Invalid period. Must be one of: #{VALID_PERIODS.join(", ")}" },
                        status: :bad_request
        end

        unless VALID_HOTELS.include?(params[:hotel])
          return render json: { error: "Invalid hotel. Must be one of: #{VALID_HOTELS.join(", ")}" },
                        status: :bad_request
        end

        return if VALID_ROOMS.include?(params[:room])

        render json: { error: "Invalid room. Must be one of: #{VALID_ROOMS.join(", ")}" }, status: :bad_request
      end
    end
  end
end
