class Account::JoinCode < ApplicationRecord
  CODE_LENGTH = 12

  belongs_to :account

  validates :code, uniqueness: true

  scope :active, -> { where("usage_limit IS NULL OR usage_count < usage_limit") }

  before_validation :generate_code, on: :create, if: -> { code.blank? }

  def redeem
    with_lock do
      return false unless active?
      increment!(:usage_count)
      true
    end
  end

  def active?
    unlimited? || usage_count < usage_limit
  end

  def reset
    update!(code: generate_new_code, usage_count: 0)
  end

  def unlimited?
    usage_limit.nil?
  end

  def usage_display
    unlimited? ? "#{usage_count} uses" : "#{usage_count}/#{usage_limit} uses"
  end

  private
    def generate_code
      self.code = generate_new_code
    end

    def generate_new_code
      loop do
        candidate = SecureRandom.base58(CODE_LENGTH).scan(/.{4}/).join("-")
        break candidate unless self.class.exists?(code: candidate)
      end
    end
end
