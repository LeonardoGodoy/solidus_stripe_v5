# frozen_string_literal: true

module SolidusStripeV5
  class Customer < ApplicationRecord
    self.table_name = "solidus_stripe_customers"

    belongs_to :payment_method

    # Source is supposed to be a user or an order and needs to respond to #email
    belongs_to :source, polymorphic: true

    def self.retrieve_or_create_stripe_customer_id(payment_method:, order:)
      instance = find_or_initialize_by(payment_method: payment_method, source: order.user || order)

      instance.stripe_id ||
        instance.create_stripe_customer.tap { instance.update!(stripe_id: _1.id) }.id
    end

    def create_stripe_customer
      payment_method.gateway.request { Stripe::Customer.create(email: source.email) }
    end
  end
end
