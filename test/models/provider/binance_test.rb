require "test_helper"

class Provider::BinanceTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Binance.new(api_key: "test_key", api_secret: "test_secret")
  end

  test "sign produces HMAC-SHA256 hex digest" do
    params = { "timestamp" => "1000", "recvWindow" => "5000" }
    sig = @provider.send(:sign, params)
    expected = OpenSSL::HMAC.hexdigest("sha256", "test_secret", "recvWindow=5000&timestamp=1000")
    assert_equal expected, sig
  end

  test "auth_headers include X-MBX-APIKEY" do
    headers = @provider.send(:auth_headers)
    assert_equal "test_key", headers["X-MBX-APIKEY"]
  end

  test "timestamp_params returns hash with timestamp and recvWindow" do
    params = @provider.send(:timestamp_params)
    assert params["timestamp"].present?
    assert_in_delta Time.current.to_i * 1000, params["timestamp"].to_i, 5000
    assert_equal "5000", params["recvWindow"]
  end

  test "handle_response raises AuthenticationError on 401" do
    response = mock_httparty_response(401, { "msg" => "Invalid API-key" })
    assert_raises(Provider::Binance::AuthenticationError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response raises RateLimitError on 429" do
    response = mock_httparty_response(429, {})
    assert_raises(Provider::Binance::RateLimitError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response raises ApiError on other non-2xx" do
    response = mock_httparty_response(403, { "msg" => "WAF Limit" })
    assert_raises(Provider::Binance::ApiError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response returns parsed body on 200" do
    response = mock_httparty_response(200, { "balances" => [] })
    result = @provider.send(:handle_response, response)
    assert_equal({ "balances" => [] }, result)
  end

  test "COIN-M reads are signed requests to dapi with the key header" do
    stub = stub_request(:get, %r{\Ahttps://dapi\.binance\.com/dapi/v1/account\?})
      .with(headers: { "X-MBX-APIKEY" => "test_key" }, query: hash_including("recvWindow" => "5000"))
      .to_return(status: 200, body: { assets: [] }.to_json, headers: { "Content-Type" => "application/json", "X-MBX-USED-WEIGHT-1M" => "15" })

    assert_equal({ "assets" => [] }, @provider.get_coin_futures_account)
    assert_requested stub
    assert_requested(:get, %r{dapi\.binance\.com/dapi/v1/account}) do |request|
      query = URI.decode_www_form(request.uri.query).to_h
      signed = URI.encode_www_form(query.except("signature").sort)
      expected = OpenSSL::HMAC.hexdigest("sha256", "test_secret", signed)
      query["signature"] == expected
    end
    assert_equal 15, @provider.used_weight[[ "dapi.binance.com", "x-mbx-used-weight-1m" ]]
  end

  test "income reads pass the window and limit to the right host" do
    um = stub_request(:get, %r{\Ahttps://fapi\.binance\.com/fapi/v1/income\?})
      .with(query: hash_including("startTime" => "1000", "endTime" => "2000", "limit" => "1000"))
      .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })
    cm = stub_request(:get, %r{\Ahttps://dapi\.binance\.com/dapi/v1/income\?})
      .with(query: hash_including("startTime" => "1000", "endTime" => "2000"))
      .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

    @provider.get_futures_income(start_time: 1000, end_time: 2000)
    @provider.get_coin_futures_income(start_time: 1000, end_time: 2000)

    assert_requested um
    assert_requested cm
  end

  test "USDⓈ-M account falls back to v2 when v3 is not served" do
    stub_request(:get, %r{fapi\.binance\.com/fapi/v3/account}).to_return(status: 404, body: { code: -5000, msg: "Path not found" }.to_json, headers: { "Content-Type" => "application/json" })
    v2 = stub_request(:get, %r{fapi\.binance\.com/fapi/v2/account}).to_return(status: 200, body: { assets: [] }.to_json, headers: { "Content-Type" => "application/json" })

    assert_equal({ "assets" => [] }, @provider.get_futures_account)
    assert_requested v2
  end

  test "a futures permission refusal is not retried on v2" do
    stub_request(:get, %r{fapi\.binance\.com/fapi/v3/account}).to_return(status: 401, body: { code: -2015, msg: "Invalid API-key, IP, or permissions for action." }.to_json, headers: { "Content-Type" => "application/json" })

    assert_raises(Provider::Binance::PermissionError) { @provider.get_futures_account }
    assert_not_requested :get, %r{fapi/v2/account}
  end

  test "handle_response raises PermissionError for -2015 whatever the status" do
    response = mock_httparty_response(400, { "code" => -2015, "msg" => "Invalid API-key, IP, or permissions for action." })
    error = assert_raises(Provider::Binance::PermissionError) { @provider.send(:handle_response, response) }
    assert_kind_of Provider::Binance::AuthenticationError, error
  end

  test "handle_response keeps Retry-After on 429 and treats 418 as a rate limit" do
    [ 429, 418 ].each do |status|
      response = mock_httparty_response(status, { "code" => -1003, "msg" => "Too many requests" })
      response.stubs(:headers).returns({ "retry-after" => "42" })

      error = assert_raises(Provider::Binance::RateLimitError) { @provider.send(:handle_response, response) }
      assert_equal 42, error.retry_after
    end
  end

  private

    def mock_httparty_response(code, body)
      response = mock
      response.stubs(:code).returns(code)
      response.stubs(:parsed_response).returns(body)
      response
    end
end
