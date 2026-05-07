require "./spec_helper"

include RequestHelpers

describe Cable::RedisBackend do
  it "connects and publishes through Redis" do
    connect do |connection, socket|
      connection.receive({"command" => "subscribe", "identifier" => {channel: "ChatChannel", room: "1"}.to_json}.to_json)
      sleep 0.1
      json_message = %({"foo": "bar"})
      Cable.server.publish(channel: "chat_1", message: json_message)
      sleep 0.1

      socket.messages.should contain({"type" => "confirm_subscription", "identifier" => {channel: "ChatChannel", room: "1"}.to_json}.to_json)
      socket.messages.should contain({"identifier" => {channel: "ChatChannel", room: "1"}.to_json, "message" => JSON.parse(%({"foo": "bar"}))}.to_json)
    end
  end

  # Reproduces the failure mode from cable-cr/cable#105 against a real Redis:
  # kill the subscribe-side TCP, wait for the reconnect loop to swap in a
  # fresh connection and replay subscriptions, then verify message dispatch
  # resumes. This test is timing-sensitive by nature — if it flakes, the
  # `sleep` after the kill needs to grow to comfortably exceed
  # SUBSCRIBE_RECONNECT_BACKOFF + replay time.
  describe "subscribe-connection recovery (cable-cr/cable#105)" do
    it "resumes message dispatch after the pubsub TCP is killed" do
      connect do |connection, socket|
        connection.receive({"command" => "subscribe", "identifier" => {channel: "ChatChannel", room: "1"}.to_json}.to_json)
        sleep 0.1

        # Baseline: messages flow before the kill.
        Cable.server.publish(channel: "chat_1", message: %({"foo": "before-kill"}))
        sleep 0.2
        socket.messages.any?(&.includes?("before-kill")).should be_true

        # Kill all pubsub TCP connections from the Redis side. This is the same
        # signal as `redis-cli CLIENT KILL TYPE pubsub` and matches the
        # production reproduction in the issue.
        backend = Cable.server.backend.as(Cable::RedisBackend)
        killed = backend.publish_connection.run({"CLIENT", "KILL", "TYPE", "pubsub"})
        killed.to_s.to_i.should be > 0

        # Give the reconnect loop time to: notice the death, wait out the
        # backoff, build a fresh connection, and replay subscriptions onto it.
        sleep(Cable::RedisBackend::SUBSCRIBE_RECONNECT_BACKOFF + 1.5.seconds)

        # If recovery worked, a fresh publish flows through the new connection.
        Cable.server.publish(channel: "chat_1", message: %({"foo": "after-kill"}))
        sleep 0.5

        socket.messages.any?(&.includes?("after-kill")).should be_true
      end
    end
  end
end

private class ChatChannel < Cable::Channel
  def subscribed
    stream_from "chat_#{params["room"]}"
  end

  def receive(message)
  end

  def perform(action, action_params)
  end

  def unsubscribed
  end
end

private class ConnectionTest < Cable::Connection
  identified_by :identifier

  def connect
    if tk = token
      self.identifier = tk
    end
  end

  def broadcast_to(channel, message)
  end
end

def connect(&)
  socket = DummySocket.new(IO::Memory.new)
  connection = ConnectionTest.new(builds_request(token: "test-token"), socket)

  yield connection, socket

  connection.close
  socket.close
end
