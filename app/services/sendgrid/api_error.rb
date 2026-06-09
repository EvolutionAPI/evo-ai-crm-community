module Sendgrid
  # Base error for any non-2xx SendGrid admin response or network failure.
  class ApiError < StandardError
    attr_reader :code, :response

    def initialize(message = nil, code = nil, response = nil)
      @code = code
      @response = response
      super(message)
    end
  end
end
