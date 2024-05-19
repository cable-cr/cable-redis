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
