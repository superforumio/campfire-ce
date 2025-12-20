class FirstRun
  FIRST_ROOM_NAME = "All Talk"
  LOCK_FILE = "tmp/auto_bootstrap.lock"

  def self.account_name
    Branding.app_name
  end

  def self.create!(user_params)
    account = Account.create!(name: account_name)
    room    = Rooms::Open.new(name: FIRST_ROOM_NAME)

    administrator = room.creator = User.new(user_params.merge(role: :administrator))
    room.save!

    room.memberships.grant_to administrator

    administrator
  end

  # Auto-bootstrap: headless setup for Campfire Cloud
  # Creates admin account with one-time login link
  # For Kamal/self-hosted: use the manual first_run flow instead
  def self.auto_bootstrap_enabled?
    ENV["AUTO_BOOTSTRAP"] == "true" &&
      ENV["ADMIN_EMAIL"].present? &&
      ENV["ADMIN_AUTH_TOKEN"].present?
  end

  def self.should_auto_bootstrap?
    auto_bootstrap_enabled? && Account.none?
  end

  def self.auto_bootstrap!
    return false unless should_auto_bootstrap?

    with_lock do
      return false if Account.any?

      token_value = ENV["ADMIN_AUTH_TOKEN"]
      if token_value.length < 32
        raise ArgumentError, "ADMIN_AUTH_TOKEN must be at least 32 characters for security"
      end

      Rails.logger.info "[AutoBootstrap] Creating admin account for Campfire Cloud..."

      admin = create!(
        name: ENV.fetch("ADMIN_NAME", "Administrator"),
        email_address: ENV["ADMIN_EMAIL"],
        password: SecureRandom.hex(32)  # Random password, never used
      )
      admin.update!(verified_at: Time.current)

      # Create AuthToken for one-time login link
      admin.auth_tokens.create!(
        token: token_value,
        expires_at: 24.hours.from_now
      )

      Rails.logger.info "[AutoBootstrap] Admin account created for #{admin.email_address}"
      admin
    end
  rescue => e
    Rails.logger.error "[AutoBootstrap] Failed to create admin: #{e.message}"
    raise
  end

  def self.with_lock(&block)
    lock_path = Rails.root.join(LOCK_FILE)
    FileUtils.mkdir_p(lock_path.dirname)

    File.open(lock_path, File::RDWR | File::CREAT, 0644) do |f|
      f.flock(File::LOCK_EX)
      yield
    end
  end
end
