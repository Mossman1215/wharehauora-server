class Room < ActiveRecord::Base
  belongs_to :home, counter_cache: true
  belongs_to :room_type

  has_many :readings
  has_many :sensors

  has_one :home_type, through: :home
  has_one :owner, through: :home

  validates :home, presence: true

  scope(:with_no_readings, -> { includes(:readings).where(readings: { id: nil }) })
  scope(:with_no_sensors, -> { includes(:sensors).where(sensors: { id: nil }) })

  def rating
    number = 100
    return '?' unless enough_info_to_perform_rating?
    number -= 15 if too_cold?
    number -= 40 if below_dewpoint?
    rating_letter(number)
  end

  def temperature
    single_current_metric 'temperature'
  end

  def humidity
    single_current_metric 'humidity'
  end

  def dewpoint
    Rails.cache.fetch("#{cache_key}/dewpoint", expires_in: 5.minutes) do
      calculate_dewpoint
    end
  end

  def below_dewpoint?
    Rails.cache.fetch("#{cache_key}/below_dewpoint?", expires_in: 5.minutes) do
      temperature < dewpoint
    end
  end

  def near_dewpoint?
    (temperature - 2) < dewpoint
  end

  def mould
    single_current_metric 'mould'
  end

  def good?
    Rails.cache.fetch("#{cache_key}/good?", expires_in: 5.minutes) do
      return unless enough_info_to_perform_rating?
      (temperature > room_type.min_temperature) && (temperature < room_type.max_temperature)
    end
  end

  def too_cold?
    (temperature < room_type.min_temperature) if enough_info_to_perform_rating?
  end

  def too_hot?
    (temperature > room_type.max_temperature) if enough_info_to_perform_rating?
  end

  def sensor?
    sensors.size.positive?
  end

  def current?(reading_type)
    return false unless readings.where(key: reading_type).size.positive?
    age_of_last_reading(reading_type) < 1.hour
  end

  def age_of_last_reading(reading_type)
    return nil unless readings.where(key: reading_type).size.positive?
    Time.current - last_reading_timestamp(reading_type)
  end

  def last_reading_timestamp(reading_type)
    readings.where(key: reading_type)
            .order(created_at: :desc)
            .limit(1)
            .first&.created_at
  end

  private

  def single_current_metric(key)
    Rails.cache.fetch("#{cache_key}/#{key}", expires_in: 1.minute) do
      Reading.where(room_id: id, key: key)&.last&.value
    end
  end

  def rating_letter(number)
    return 'A' if number > 95
    return 'B' if number > 75
    return 'C' if number > 50
    return 'D' if number > 25
    'F'
  end

  def enough_info_to_perform_rating?
    room_type && current?('temperature') && room_type.min_temperature.present? && room_type.max_temperature.present?
  end

  def calculate_dewpoint
    temp_c = single_current_metric 'temperature'
    humidity = single_current_metric 'humidity'
    return unless temp_c && humidity
    l = Math.log(humidity / 100.0)
    m = 17.27 * temp_c
    n = 237.3 + temp_c
    b = (l + (m / n)) / 17.27
    (237.3 * b) / (1 - b)
  end
end
