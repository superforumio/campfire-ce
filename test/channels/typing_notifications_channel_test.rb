require "test_helper"

class TypingNotificationsChannelTest < ActionCable::Channel::TestCase
  setup do
    stub_connection(current_user: users(:david))
    @room = users(:david).rooms.first
  end

  test "subscribes to a room" do
    subscribe room_id: @room.id

    assert subscription.confirmed?
    assert_has_stream_for @room
  end

  test "broadcasts start typing notification" do
    subscribe room_id: @room.id

    assert_broadcast_on(@room, action: :start, user: { id: users(:david).id, name: users(:david).name }) do
      perform :start
    end
  end

  test "broadcasts stop typing notification" do
    subscribe room_id: @room.id

    assert_broadcast_on(@room, action: :stop, user: { id: users(:david).id, name: users(:david).name }) do
      perform :stop
    end
  end

  test "rejects subscription to a room user is not a member of" do
    other_room = Rooms::Closed.create!(name: "Secret Room", creator: users(:jason))

    subscribe room_id: other_room.id

    assert subscription.rejected?
  end
end
