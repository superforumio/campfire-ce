module Account::Joinable
  extend ActiveSupport::Concern

  included do
    has_one :join_code, class_name: "Account::JoinCode", dependent: :destroy

    after_create :create_join_code
  end

  def reset_join_code
    join_code.reset
  end

  private
    def create_join_code
      build_join_code.save!
    end
end
