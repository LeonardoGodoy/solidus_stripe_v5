# frozen_string_literal: true

require 'stripe'

module SolidusStripe
  # @see https://stripe.com/docs/payments/accept-a-payment?platform=web&ui=checkout#auth-and-capture
  # @see https://stripe.com/docs/charges/placing-a-hold
  # @see https://guides.solidus.io/advanced-solidus/payments-and-refunds/#custom-payment-gateways
  #
  # ## About fractional amounts
  #
  # All methods in the Gateway class will have `amount_in_cents` arguments representing the
  # fractional amount as defined by Spree::Money and will be translated to the fractional expected
  # by Stripe, although for most currencies it's cents some will have a different multiplier and
  # that is already took into account.
  #
  # @see SolidusStripe::MoneyToStripeAmountConverter
  class Gateway
    include SolidusStripe::MoneyToStripeAmountConverter
    include SolidusStripe::LogEntries

    def initialize(options)
      # Cannot use kwargs because of how the Gateway is initialized by Solidus.
      @client = Stripe::StripeClient.new(
        api_key: options.fetch(:api_key, nil),
      )
      @options = options
    end

    attr_reader :client

    # Authorizes a certain amount on the provided payment source.
    #
    # @see #purchase
    def authorize(_amount_in_cents, source, options = {})
      stripe_payment_intent = create_stripe_payment_intent(
        source,
        options[:originator].order,
        stripe_payment_intent_options: {
          capture_method: "manual",
          confirm: true
        }
      )
      build_payment_log(
        success: true,
        message: "PaymentIntent was confirmed successfully",
        response_code: stripe_payment_intent.id,
        data: stripe_payment_intent,
      )
    end

    # Captures a certain amount from a previously authorized transaction.
    #
    # @see https://stripe.com/docs/api/payment_intents/capture#capture_payment_intent
    # @see https://stripe.com/docs/payments/capture-later
    #
    # @todo add support for capturing custom amounts
    def capture(amount_in_cents, payment_intent_id, options = {})
      payment = options[:originator] or
        raise ArgumentError, "please provide a payment with the :originator option"

      unless payment_intent_id
        raise ArgumentError, "missing payment_intent_id"
      end

      unless amount_in_cents == payment.display_amount.cents
        raise \
          "Capturing a custom amount is not supported yet, " \
          "tried #{amount_in_cents} but can only accept #{payment.display_amount.cents}."
      end

      unless payment_intent_id.start_with?('pi_')
        raise ArgumentError, "the payment-intent id has the wrong format"
      end

      payment_intent = capture_stripe_payment_intent(payment_intent_id)
      build_payment_log(
        success: true,
        message: "PaymentIntent was confirmed successfully",
        response_code: payment_intent.id,
        data: payment_intent,
      )
    rescue Stripe::InvalidRequestError => e
      build_payment_log(
        success: false,
        message: e.to_s,
        data: e.response,
      )
    end

    # Authorizes and captures a certain amount on the provided payment source.
    # @todo add support for purchasing custom amounts
    def purchase(_amount_in_cents, source, options = {})
      stripe_payment_intent = create_stripe_payment_intent(
        source,
        options[:originator].order,
        stripe_payment_intent_options: {
          capture_method: "automatic",
          confirm: true
        }
      )
      build_payment_log(
        success: true,
        message: "PaymentIntent was confirmed and captured successfully",
        response_code: stripe_payment_intent.id,
        data: stripe_payment_intent,
      )
    end

    # Voids a previously authorized transaction, releasing the funds that are on hold.
    def void(payment_intent_id, _source, _options = {})
      payment_intent = request do
        Stripe::PaymentIntent.cancel(payment_intent_id)
      end

      build_payment_log(
        success: true,
        message: "PaymentIntent was canceled successfully",
        response_code: payment_intent_id,
        data: payment_intent,
      )
    rescue Stripe::InvalidRequestError => e
      build_payment_log(
        success: false,
        message: e.to_s,
        data: e.response,
      )
    end

    # Refunds the provided amount on a previously captured transaction.
    # TODO: check this method params twice.
    def credit(amount_in_cents, _source, payment_intent_id, options = {})
      payment = options[:originator].payment
      currency = payment.currency

      stripe_refund = request do
        Stripe::Refund.create(
          amount: to_stripe_amount(amount_in_cents, currency),
          payment_intent: payment_intent_id,
        )
      end

      build_payment_log(
        success: true,
        message: "PaymentIntent was refunded successfully",
        response_code: payment_intent_id,
        data: stripe_refund,
      )
    end

    # Send a request to stripe using the current api keys but ignoring
    # the response object.
    #
    # @yield Allows to use the `Stripe` gem using the credentials attached
    #   to the current payment method
    #
    # @example Retrieve a payment intent
    #   request { Stripe::PaymentIntent.retrieve(intent_id) }
    #
    # @return forwards the result of the block
    def request(&block)
      result, _response = client.request(&block)
      result
    end

    private

    def create_stripe_payment_intent(source, order, stripe_payment_intent_options:)
      stripe_payment_method = source.stripe_payment_method

      SolidusStripe::PaymentIntent.create_stripe_intent(
        payment_method: source.payment_method,
        order: order,
        stripe_intent_options: stripe_payment_intent_options.merge(
          payment_method: stripe_payment_method.id,
          customer: stripe_payment_method.customer
        )
      )
    end

    def capture_stripe_payment_intent(stripe_payment_intent_id)
      request { Stripe::PaymentIntent.capture(stripe_payment_intent_id) }
    end
  end
end
