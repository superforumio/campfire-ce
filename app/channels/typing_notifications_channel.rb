class TypingNotificationsChannel < RoomChannel
  def start(data)
    return unless room

    broadcast_to room, action: :start, user: current_user_attributes
  end

  def stop(data)
    return unless room

    broadcast_to room, action: :stop, user: current_user_attributes
  end

  private
    # In AnyCable HTTP RPC mode, @room isn't preserved between calls.
    # Look it up from params if needed.
    def room
      return nil unless current_user

      @room ||= current_user.rooms.find_by(id: params[:room_id])
    end

    def current_user_attributes
      current_user.slice(:id, :name)
    end
end
