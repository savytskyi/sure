class Provider::Binance
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  # Binance answers -2015 both for a wrong key and for a key that may not read
  # a product (a key created before the futures account was opened, or an IP
  # not on the key's allow list), so the message says which product refused.
  class PermissionError < AuthenticationError; end
  class RateLimitError < Error
    attr_reader :retry_after

    def initialize(message = "Rate limit exceeded", retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end
  class ApiError < Error; end
  class InvalidSymbolError < ApiError; end

  # Pipelock false positive: This constant and the base_uri below trigger a "Credential in URL"
  # warning because of the presence of @api_key and @api_secret variables in this file.
  # Pipelock incorrectly interprets the '@' in Ruby instance variables as a password delimiter
  # in an URL (e.g. https://user:password@host).
  SPOT_BASE_URL = "https://api.binance.com".freeze
  FUTURES_BASE_URL = "https://fapi.binance.com".freeze
  COIN_FUTURES_BASE_URL = "https://dapi.binance.com".freeze

  # -2014/-2015: key format or key/IP/permission rejected; -1022: bad signature.
  PERMISSION_ERROR_CODES = [ -2014, -2015, -1022 ].freeze
  # -1003: too many requests (sent with 429, or 418 once the IP is banned).
  RATE_LIMIT_ERROR_CODES = [ -1003 ].freeze

  base_uri SPOT_BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret, :used_weight

  def initialize(api_key:, api_secret:)
    @api_key = api_key
    @api_secret = api_secret
    @used_weight = {}
  end

  # What the key may do (reading, futures, withdrawals, ...). Read-only.
  def get_api_restrictions
    signed_get("/sapi/v1/account/apiRestrictions")
  end

  # Binance's own valuation of every wallet (Spot, Funding, USDⓈ-M Futures,
  # COIN-M Futures, Earn, ...) in quote_asset. Used to reconcile what was
  # imported, never as a balance itself.
  def get_wallet_balances(quote_asset: "USDT")
    signed_get("/sapi/v1/asset/wallet/balance", extra_params: { "quoteAsset" => quote_asset })
  end

  # Spot wallet — requires signed request
  def get_spot_account
    signed_get("/api/v3/account")
  end

  # Margin account — requires signed request
  def get_margin_account
    signed_get("/sapi/v1/margin/account")
  end

  # Simple Earn flexible positions — requires signed request
  def get_simple_earn_flexible
    signed_get("/sapi/v1/simple-earn/flexible/position")
  end

  # Simple Earn locked positions — requires signed request
  def get_simple_earn_locked
    signed_get("/sapi/v1/simple-earn/locked/position")
  end

  # Public endpoint — no auth needed
  # symbol e.g. "BTCUSDT"
  # Returns price string or nil on failure
  def get_spot_price(symbol)
    response = self.class.get("/api/v3/ticker/price", query: { symbol: symbol })
    data = handle_response(response)
    data["price"]
  rescue StandardError => e
    Rails.logger.warn("Provider::Binance: failed to fetch price for #{symbol}: #{e.message}")
    nil
  end

  # Public endpoint — fetch historical kline close price for a date
  # symbol e.g. "BTCUSDT", date e.g. Date or Time
  def get_historical_price(symbol, date)
    timestamp = date.to_time.utc.beginning_of_day.to_i * 1000

    response = self.class.get("/api/v3/klines", query: {
      symbol: symbol,
      interval: "1d",
      startTime: timestamp,
      limit: 1
    })

    data = handle_response(response)

    return nil if data.blank? || data.first.blank?

    # Binance klines format: [ Open time, Open, High, Low, Close (index 4), ... ]
    data.first[4]
  rescue StandardError => e
    Rails.logger.warn("Provider::Binance: failed to fetch historical price for #{symbol} on #{date}: #{e.message}")
    nil
  end

  # Signed trade history for a single symbol, e.g. "BTCUSDT".
  # Pass from_id to fetch only trades with id >= from_id (for incremental sync).
  # Pass start_time/end_time (epoch ms) to fetch a bounded window instead; Binance
  # rejects from_id combined with start_time/end_time, so callers use one or the other.
  def get_spot_trades(symbol, limit: 1000, from_id: nil, start_time: nil, end_time: nil)
    params = { "symbol" => symbol, "limit" => limit.to_s }
    params["fromId"] = from_id.to_s if from_id
    params["startTime"] = start_time.to_s if start_time
    params["endTime"] = end_time.to_s if end_time
    signed_get("/api/v3/myTrades", extra_params: params)
  end

  # USDⓈ-M Futures account — requires signed request. V3 lists only the
  # quote assets and the symbols with a position or open order; V2 is the
  # fallback for an account V3 does not serve.
  def get_futures_account
    signed_get("/fapi/v3/account", base_url: FUTURES_BASE_URL)
  rescue ApiError => e
    raise if e.is_a?(InvalidSymbolError)

    Rails.logger.warn("Provider::Binance: /fapi/v3/account failed (#{e.message}); retrying /fapi/v2/account")
    signed_get("/fapi/v2/account", base_url: FUTURES_BASE_URL)
  end

  # USDⓈ-M open positions with entry, break-even, mark and liquidation prices.
  def get_futures_position_risk
    signed_get("/fapi/v3/positionRisk", base_url: FUTURES_BASE_URL)
  end

  # USDⓈ-M wallet movements (REALIZED_PNL, FUNDING_FEE, COMMISSION, TRANSFER,
  # ...). Binance keeps three months; start_time/end_time are inclusive ms.
  def get_futures_income(start_time:, end_time:, limit: 1000)
    signed_get("/fapi/v1/income", base_url: FUTURES_BASE_URL, extra_params: {
      "startTime" => start_time.to_s, "endTime" => end_time.to_s, "limit" => limit.to_s
    })
  end

  # COIN-M Futures account: coin-margined wallet balances (BTC, ETH, ...) and
  # unrealized P&L, all denominated in the margin coin.
  def get_coin_futures_account
    signed_get("/dapi/v1/account", base_url: COIN_FUTURES_BASE_URL)
  end

  # COIN-M positions; positionAmt is in contracts, notionalValue in the coin.
  def get_coin_futures_position_risk
    signed_get("/dapi/v1/positionRisk", base_url: COIN_FUTURES_BASE_URL)
  end

  # COIN-M wallet movements, including DELIVERED_SETTELMENT (sic) for dated
  # contracts. A request may span at most a year.
  def get_coin_futures_income(start_time:, end_time:, limit: 1000)
    signed_get("/dapi/v1/income", base_url: COIN_FUTURES_BASE_URL, extra_params: {
      "startTime" => start_time.to_s, "endTime" => end_time.to_s, "limit" => limit.to_s
    })
  end

  # Public: contract size, margin asset and delivery date per COIN-M symbol.
  def get_coin_futures_exchange_info
    response = self.class.get("/dapi/v1/exchangeInfo", base_uri: COIN_FUTURES_BASE_URL)
    handle_response(response)
  end

  # Futures trade history for a single symbol
  def get_futures_trades(symbol, limit: 1000, from_id: nil, start_time: nil, end_time: nil)
    params = { "symbol" => symbol, "limit" => limit.to_s }
    params["fromId"] = from_id.to_s if from_id
    params["startTime"] = start_time.to_s if start_time
    params["endTime"] = end_time.to_s if end_time
    signed_get("/fapi/v1/userTrades", extra_params: params, base_url: FUTURES_BASE_URL)
  end

  # P2P trade history — requires signed request
  # Pass start_timestamp to fetch only recent trades (max 30 days window)
  def get_p2p_trades(start_timestamp: nil, end_timestamp: nil)
    params = { "tradeType" => "BUY" } # default to BUY, will loop in processor for SELL
    params["startTimestamp"] = start_timestamp.to_s if start_timestamp
    params["endTimestamp"] = end_timestamp.to_s if end_timestamp
    signed_get("/sapi/v1/c2c/orderMatch/listUserOrderHistory", extra_params: params)
  end

  # Internal helper to handle both buy and sell types since API requires specific tradeType or gets default BUY
  def get_all_p2p_trades(start_timestamp: nil, end_timestamp: nil)
    %w[BUY SELL].flat_map do |trade_type|
      page = 1
      rows = 100
      data = []
      loop do
        result = signed_get(
          "/sapi/v1/c2c/orderMatch/listUserOrderHistory",
          extra_params: {
            "tradeType" => trade_type,
            "startTimestamp" => start_timestamp&.to_s,
            "endTimestamp" => end_timestamp&.to_s,
            "page" => page.to_s,
            "rows" => rows.to_s
          }.compact
        )
        batch = result.is_a?(Hash) ? Array(result["data"]) : []
        data.concat(batch)
        break if batch.size < rows
        page += 1
      end
      data
    end
  end

  private

    def signed_get(path, extra_params: {}, base_url: SPOT_BASE_URL)
      params = timestamp_params.merge(extra_params)
      query_string = URI.encode_www_form(params.sort)

      response = self.class.get(
        path,
        base_uri: base_url,
        query: "#{query_string}&signature=#{sign(query_string)}",
        headers: auth_headers
      )

      handle_response(response)
    end

    def timestamp_params
      { "timestamp" => (Time.current.to_f * 1000).to_i.to_s, "recvWindow" => "5000" }
    end

    # HMAC-SHA256 of the query string.
    # Accepts either a Hash of params or a pre-built query string.
    def sign(params)
      query_string = params.is_a?(Hash) ? URI.encode_www_form(params.sort) : params
      OpenSSL::HMAC.hexdigest("sha256", api_secret, query_string)
    end

    def auth_headers
      { "X-MBX-APIKEY" => api_key }
    end

    def handle_response(response)
      parsed = response.parsed_response
      record_used_weight(response)
      code = parsed["code"] if parsed.is_a?(Hash)

      case response.code
      when 200..299
        parsed
      when 429, 418
        raise RateLimitError.new(
          "Rate limit exceeded#{' (IP banned)' if response.code == 418}: #{extract_error_message(parsed)}",
          retry_after: retry_after(response)
        )
      else
        msg = extract_error_message(parsed) || "API error: #{response.code}"
        raise PermissionError, msg if PERMISSION_ERROR_CODES.include?(code)
        raise AuthenticationError, msg if response.code == 401
        raise RateLimitError.new(msg, retry_after: retry_after(response)) if RATE_LIMIT_ERROR_CODES.include?(code)
        raise InvalidSymbolError, msg if code == -1121
        raise ApiError, msg
      end
    end

    # X-MBX-USED-WEIGHT-1M (and friends), per host, so a caller can slow
    # down before Binance answers 429.
    def record_used_weight(response)
      return unless response.respond_to?(:headers) && response.headers

      response.headers.each do |name, value|
        next unless name.to_s.downcase.start_with?("x-mbx-used-weight")

        host = response.respond_to?(:request) ? response.request&.uri&.host : nil
        @used_weight[[ host, name.to_s.downcase ]] = Array(value).first.to_i
      end
    rescue StandardError
      nil
    end

    def retry_after(response)
      return nil unless response.respond_to?(:headers) && response.headers

      value = response.headers["retry-after"] || response.headers["Retry-After"]
      Array(value).first&.to_i
    end

    def extract_error_message(parsed)
      return parsed if parsed.is_a?(String)
      return nil unless parsed.is_a?(Hash)
      parsed["msg"] || parsed["message"] || parsed["error"]
    end
end
