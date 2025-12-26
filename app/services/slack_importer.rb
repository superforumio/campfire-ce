require "zip"

class SlackImporter
  attr_reader :zip_path, :stats

  EMOJI_MAP = {
    "thumbsup" => "👍",
    "+1" => "👍",
    "thumbsdown" => "👎",
    "-1" => "👎",
    "heart" => "❤️",
    "fire" => "🔥",
    "tada" => "🎉",
    "clap" => "👏",
    "100" => "💯",
    "rocket" => "🚀",
    "eyes" => "👀",
    "pray" => "🙏",
    "raised_hands" => "🙌",
    "sparkles" => "✨",
    "star" => "⭐",
    "white_check_mark" => "✅",
    "x" => "❌",
    "thinking_face" => "🤔",
    "laughing" => "😂",
    "joy" => "😂",
    "smile" => "😄",
    "slightly_smiling_face" => "🙂",
    "wink" => "😉",
    "sob" => "😭",
    "cry" => "😢",
    "muscle" => "💪",
    "wave" => "👋",
    "point_up" => "☝️",
    "point_down" => "👇",
    "ok_hand" => "👌",
    "v" => "✌️",
    "metal" => "🤘",
    "call_me_hand" => "🤙",
    "fist" => "✊",
    "punch" => "👊",
    "handshake" => "🤝",
    "hugging_face" => "🤗",
    "rolling_on_the_floor_laughing" => "🤣",
    "upside_down_face" => "🙃",
    "grimacing" => "😬",
    "sweat_smile" => "😅",
    "confused" => "😕",
    "neutral_face" => "😐",
    "expressionless" => "😑",
    "unamused" => "😒",
    "face_with_rolling_eyes" => "🙄",
    "smirk" => "😏",
    "sunglasses" => "😎",
    "nerd_face" => "🤓",
    "warning" => "⚠️",
    "boom" => "💥",
    "zap" => "⚡",
    "bulb" => "💡",
    "memo" => "📝",
    "bell" => "🔔",
    "link" => "🔗",
    "lock" => "🔒",
    "key" => "🔑",
    "mag" => "🔍",
    "gear" => "⚙️",
    "wrench" => "🔧",
    "hammer" => "🔨",
    "construction" => "🚧",
    "package" => "📦",
    "gift" => "🎁",
    "balloon" => "🎈",
    "confetti_ball" => "🎊",
    "trophy" => "🏆",
    "medal" => "🏅",
    "crown" => "👑",
    "gem" => "💎",
    "moneybag" => "💰",
    "chart_with_upwards_trend" => "📈",
    "chart_with_downwards_trend" => "📉",
    "coffee" => "☕",
    "beer" => "🍺",
    "pizza" => "🍕",
    "hamburger" => "🍔",
    "fries" => "🍟",
    "popcorn" => "🍿",
    "cake" => "🎂",
    "cookie" => "🍪",
    "apple" => "🍎",
    "lemon" => "🍋",
    "avocado" => "🥑",
    "dog" => "🐕",
    "cat" => "🐈",
    "unicorn" => "🦄",
    "rainbow" => "🌈",
    "sunny" => "☀️",
    "cloud" => "☁️",
    "snowflake" => "❄️",
    "ocean" => "🌊",
    "earth_americas" => "🌎"
  }.freeze

  def initialize(zip_path)
    @zip_path = zip_path
    @stats = { users: 0, rooms: 0, messages: 0, boosts: 0, threads: 0 }
    @user_map = {}      # slack_user_id => User
    @channel_map = {}   # slack_channel_id => Room
    @message_map = {}   # slack_ts => Message (for threading)
    @thread_replies = [] # Messages that are thread replies (to process after all messages)
  end

  def import!
    Zip::File.open(zip_path) do |zip|
      @zip = zip

      ActiveRecord::Base.transaction do
        import_users
        import_channels
        import_private_channels if file_exists?("groups.json")
        import_dms if file_exists?("dms.json")
        import_messages_for_all_channels
        create_threads
      end
    end

    @stats
  end

  private

  def import_users
    users_data = parse_json("users.json")
    log_progress "Found #{users_data.count} users in export"

    users_data.each do |slack_user|
      next if slack_user["is_bot"] || slack_user["deleted"]

      display_name = slack_user.dig("profile", "real_name").presence ||
                     slack_user.dig("profile", "display_name").presence ||
                     slack_user["name"]

      user = User.new(
        name: display_name.presence || "Slack User",
        email_address: nil,
        status: :active,
        role: :member,
        bio: slack_user.dig("profile", "title")
      )
      user.save!(validate: false)

      # Store slack metadata in preferences for future account claiming
      user.update_column(:preferences, {
        slack_import: true,
        slack_user_id: slack_user["id"],
        slack_username: slack_user["name"]
      }.to_json)

      @user_map[slack_user["id"]] = user
      @stats[:users] += 1
    end

    log_progress "Imported #{@stats[:users]} users"
  end

  def import_channels
    channels_data = parse_json("channels.json")
    log_progress "Found #{channels_data.count} public channels"

    channels_data.each do |channel|
      slug = generate_unique_slug(channel["name"])

      room = Rooms::Open.create!(
        name: channel["name"].tr("-_", " ").titleize,
        slug: slug,
        creator: first_admin_or_system_user
      )

      # Add imported Slack members
      member_users = (channel["members"] || []).filter_map { |id| @user_map[id] }
      room.memberships.grant_to(member_users) if member_users.any?

      # Grant access to all existing active users (Open rooms are visible to everyone)
      existing_users = User.active.where.not(id: member_users.map(&:id))
      room.memberships.grant_to(existing_users) if existing_users.exists?

      @channel_map[channel["id"]] = room
      @stats[:rooms] += 1

      log_progress "Created room: ##{room.name}"
    end
  end

  def import_private_channels
    groups_data = parse_json("groups.json")
    log_progress "Found #{groups_data.count} private channels"

    groups_data.each do |group|
      slug = generate_unique_slug(group["name"])

      room = Rooms::Closed.create!(
        name: group["name"].tr("-_", " ").titleize,
        slug: slug,
        creator: first_admin_or_system_user
      )

      # Add members
      member_users = (group["members"] || []).filter_map { |id| @user_map[id] }
      room.memberships.grant_to(member_users) if member_users.any?

      @channel_map[group["id"]] = room
      @stats[:rooms] += 1
    end
  end

  def import_dms
    dms_data = parse_json("dms.json")
    log_progress "Found #{dms_data.count} direct message conversations"

    dms_data.each do |dm|
      members = (dm["members"] || []).filter_map { |id| @user_map[id] }
      next if members.size < 2

      Current.user = members.first
      room = Rooms::Direct.find_or_create_for(members)
      @channel_map[dm["id"]] = room
      @stats[:rooms] += 1
    end
    Current.user = nil
  end

  def import_messages_for_all_channels
    @channel_map.each do |channel_id, room|
      import_messages_for_channel(channel_id, room)
    end
  end

  def import_messages_for_channel(channel_id, room)
    channel_folder = find_channel_folder(channel_id)
    return unless channel_folder

    message_files = @zip.entries.select do |entry|
      entry.name.start_with?("#{channel_folder}/") &&
      entry.name.end_with?(".json") &&
      entry.name != "#{channel_folder}/"
    end

    return if message_files.empty?

    # Sort by filename (date) to preserve chronological order
    message_files.sort_by(&:name).each do |entry|
      messages = JSON.parse(@zip.read(entry.name))
      messages.each { |msg| import_message(msg, room) }
    rescue JSON::ParserError => e
      log_progress "Warning: Failed to parse #{entry.name}: #{e.message}"
    end
  end

  def import_message(msg, room)
    return unless msg["type"] == "message"
    return if msg["subtype"].in?(%w[channel_join channel_leave channel_purpose channel_topic])

    user = @user_map[msg["user"]]
    return unless user

    # Convert Slack timestamp to Ruby time
    timestamp = Time.at(msg["ts"].to_f)

    # Convert mention syntax: <@U12345> -> @username
    body = convert_mentions(msg["text"])

    # Skip empty messages
    return if body.blank?

    message = Message.new(
      room: room,
      creator: user,
      body: body,
      client_message_id: "slack_#{msg['ts']}"
    )

    # Bypass callbacks for bulk import performance
    message.save!(validate: false)

    # Set the created_at after save to preserve original timestamp
    message.update_columns(created_at: timestamp, updated_at: timestamp)

    # Store for threading
    @message_map[msg["ts"]] = message

    # Track thread replies for later processing
    if msg["thread_ts"].present? && msg["thread_ts"] != msg["ts"]
      @thread_replies << {
        message: message,
        thread_ts: msg["thread_ts"],
        room: room
      }
    end

    # Import reactions as boosts
    import_reactions(msg["reactions"], message) if msg["reactions"]

    @stats[:messages] += 1

    if @stats[:messages] % 500 == 0
      log_progress "Imported #{@stats[:messages]} messages..."
    end
  end

  def import_reactions(reactions, message)
    reactions.each do |reaction|
      emoji = convert_emoji(reaction["name"])

      (reaction["users"] || []).each do |user_id|
        user = @user_map[user_id]
        next unless user

        boost = Boost.new(
          message: message,
          booster: user,
          content: emoji
        )
        boost.save!(validate: false)
        boost.update_columns(created_at: message.created_at)

        @stats[:boosts] += 1
      end
    end
  end

  def create_threads
    log_progress "Processing #{@thread_replies.count} thread replies..."

    # Group replies by their parent thread_ts
    replies_by_thread = @thread_replies.group_by { |r| r[:thread_ts] }

    replies_by_thread.each do |thread_ts, replies|
      parent = @message_map[thread_ts]
      next unless parent

      # Find or create thread room for this parent message
      thread_room = parent.threads.first
      unless thread_room
        Current.user = parent.creator

        # Get unique users from parent and all replies
        thread_users = [ parent.creator ] + replies.map { |r| r[:message].creator }
        thread_users = thread_users.uniq

        thread_room = Rooms::Thread.create_for(
          { parent_message_id: parent.id, creator: parent.creator },
          users: thread_users
        )
        @stats[:threads] += 1
        Current.user = nil
      end

      # Move reply messages to the thread room
      replies.each do |reply_data|
        reply = reply_data[:message]
        reply.update_columns(room_id: thread_room.id)

        # Grant membership to reply creator if not already
        thread_room.memberships.grant_to([ reply.creator ])
      end
    end

    log_progress "Created #{@stats[:threads]} threads"
  end

  def convert_mentions(text)
    return "" if text.blank?

    # Convert <@U12345ABC> to @username
    text.gsub(/<@([A-Z0-9]+)(\|[^>]*)?>/) do
      user = @user_map[$1]
      if user
        first_name = user.name.split.first&.downcase || "user"
        "@#{first_name}"
      else
        "@unknown"
      end
    end
    .gsub(/<#[A-Z0-9]+\|([^>]+)>/, '#\1')  # Convert <#C123|channel-name> to #channel-name
    .gsub(/<(https?:\/\/[^|>]+)\|([^>]+)>/, '\2 (\1)')  # Convert <url|text> to text (url)
    .gsub(/<(https?:\/\/[^>]+)>/, '\1')  # Convert <url> to url
    .gsub(/<!here>/, "@here")
    .gsub(/<!channel>/, "@channel")
    .gsub(/<!everyone>/, "@everyone")
  end

  def convert_emoji(slack_emoji)
    EMOJI_MAP[slack_emoji] || "👍"
  end

  def file_exists?(name)
    @zip.find_entry(name).present?
  end

  def parse_json(name)
    content = @zip.read(name)
    JSON.parse(content)
  rescue JSON::ParserError => e
    log_progress "Warning: Failed to parse #{name}: #{e.message}"
    []
  end

  def find_channel_folder(channel_id)
    # Try channels.json first
    if file_exists?("channels.json")
      channel = parse_json("channels.json").find { |c| c["id"] == channel_id }
      return channel["name"] if channel && folder_exists?(channel["name"])
    end

    # Check groups.json
    if file_exists?("groups.json")
      group = parse_json("groups.json").find { |g| g["id"] == channel_id }
      return group["name"] if group && folder_exists?(group["name"])
    end

    # Check dms.json
    if file_exists?("dms.json")
      dm = parse_json("dms.json").find { |d| d["id"] == channel_id }
      return dm["id"] if dm && folder_exists?(dm["id"])
    end

    nil
  end

  def folder_exists?(name)
    # Check for explicit directory entry or any files starting with the folder name
    @zip.find_entry("#{name}/") || @zip.entries.any? { |e| e.name.start_with?("#{name}/") }
  end

  def generate_unique_slug(name)
    base_slug = name.to_s.parameterize
    slug = base_slug
    counter = 1

    while Room.exists?(slug: slug) || Room::RESERVED_SLUGS.include?(slug)
      slug = "#{base_slug}-#{counter}"
      counter += 1
    end

    slug
  end

  def first_admin_or_system_user
    @admin_user ||= User.find_by(role: :administrator) || @user_map.values.first || create_system_user
  end

  def create_system_user
    User.create!(
      name: "Slack Import",
      email_address: nil,
      status: :active,
      role: :member
    ).tap do |user|
      user.update_column(:preferences, { system_user: true, slack_import: true }.to_json)
    end
  end

  def log_progress(message)
    puts message
    Rails.logger.info("[SlackImport] #{message}")
  end
end
