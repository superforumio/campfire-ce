class PresenceChannel < RoomChannel
  on_subscribe   :present, unless: :subscription_rejected?
  on_unsubscribe :absent,  unless: :subscription_rejected?

  def present
    return unless membership

    membership.present
    broadcast_read_room
  end

  def absent
    return unless membership

    membership.disconnected
  end

  def refresh
    return unless membership

    membership.refresh_connection
  end

  private
    def membership
      return nil unless current_user

      # In AnyCable HTTP RPC mode, @room isn't preserved between calls.
      # Look it up from params if needed.
      @room ||= current_user.rooms.find_by(id: params[:room_id])
      return nil unless @room

      @room.memberships.find_by(user: current_user)
    end

    def broadcast_read_room
      ActionCable.server.broadcast "user_#{current_user.id}_reads", { room_id: membership.room_id }
    end
end
