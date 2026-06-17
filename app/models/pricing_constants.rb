module PricingConstants
  VALID_PERIODS = %w[Summer Autumn Winter Spring].freeze
  VALID_HOTELS  = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
  VALID_ROOMS   = %w[SingletonRoom BooleanTwin RestfulKing].freeze

  ALL_COMBINATIONS = VALID_PERIODS.flat_map do |period|
    VALID_HOTELS.flat_map do |hotel|
      VALID_ROOMS.map do |room|
        { period: period, hotel: hotel, room: room }
      end
    end
  end.freeze
end
