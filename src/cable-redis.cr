require "redis"

module Cable
  class RedisBackend < Cable::BackendCore
    VERSION = "0.1.0"

    # How long to wait before reconnecting the subscribe connection after
    # the pubsub block loop crashes (see cable-cr/cable#105).
    SUBSCRIBE_RECONNECT_BACKOFF = 1.second

    register "redis"  # redis://
    register "rediss" # rediss://

    # connection management
    getter redis_subscribe : Redis::Connection = Redis::Connection.new(URI.parse(Cable.settings.url))
    getter redis_publish : Redis::Client = Redis::Client.new(URI.parse(Cable.settings.url))

    # Tracks every stream identifier we have an active SUBSCRIBE on, so that
    # if the underlying TCP dies we can replay the subscriptions onto a fresh
    # connection (see cable-cr/cable#105). The internal control channel passed
    # to open_subscribe_connection is excluded — it's re-subscribed implicitly
    # when the reconnect loop re-enters the pubsub block.
    @subscribed_channels = Set(String).new
    @subscribed_channels_mutex = Mutex.new

    # Set when the backend is being torn down. The reconnect loop checks this
    # so a clean shutdown does not get interpreted as a transient failure.
    @shutting_down : Bool = false

    # connection management
    def subscribe_connection : Redis::Connection
      redis_subscribe
    end

    def publish_connection : Redis::Client
      redis_publish
    end

    def close_subscribe_connection
      @shutting_down = true
      redis_subscribe.unsubscribe
      redis_subscribe.close
    rescue IO::Error
      # connection was already torn down
    end

    def close_publish_connection
      redis_publish.close
    rescue IO::Error
      # connection was already torn down
    end

    # internal pub/sub
    #
    # The pubsub block loop is wrapped in a reconnect cycle so that a transient
    # backend death (Redis restart, network blip, idle reap) does not permanently
    # kill message dispatch — see cable-cr/cable#105.
    def open_subscribe_connection(channel)
      loop do
        begin
          # Replay any tracked subscriptions onto the (possibly fresh) connection
          # once the pubsub block has actually entered subscribe mode. The spawned
          # fiber runs while the main fiber is blocked waiting for messages.
          spawn(name: "Cable::RedisBackend - replay subscriptions") { replay_tracked_subscriptions }

          redis_subscribe.subscribe(channel) do |subscription|
            subscription.on_message do |sub_channel, message|
              if sub_channel == Cable::INTERNAL[:channel] && message == "ping"
                Cable::Logger.debug { "Cable::Server#subscribe -> PONG" }
              elsif sub_channel == Cable::INTERNAL[:channel] && message == "debug"
                Cable.server.debug
              else
                Cable.server.fiber_channel.send({sub_channel, message})
                Cable::Logger.debug { "Cable::Server#subscribe channel:#{sub_channel} message:#{message}" }
              end
            end
          end
          # Falling through here means the subscribe block returned without
          # raising. jgaskins/redis exits its read loop cleanly when `read?`
          # returns nil — which is what `CLIENT KILL TYPE pubsub` and other
          # server-side disconnects look like — so we must treat a clean
          # return as a reconnect signal, not as success.
        rescue e : IO::Error
          Cable::Logger.error(exception: e) { "Cable::RedisBackend subscribe loop crashed" }
          Cable.settings.on_error.call(e, "Cable::RedisBackend#open_subscribe_connection (reconnecting)", nil)
        end

        break if @shutting_down
        Cable::Logger.warn { "Cable::RedisBackend subscribe disconnected; reconnecting in #{SUBSCRIBE_RECONNECT_BACKOFF.total_seconds}s" }
        sleep SUBSCRIBE_RECONNECT_BACKOFF
        break if @shutting_down
        @redis_subscribe = Redis::Connection.new(URI.parse(Cable.settings.url))
      end
    end

    # external pub/sub
    def publish_message(stream_identifier : String, message : String)
      redis_publish.publish(stream_identifier, message)
    end

    # channel management
    def subscribe(stream_identifier : String)
      @subscribed_channels_mutex.synchronize { @subscribed_channels << stream_identifier }
      redis_subscribe.subscribe(stream_identifier)
    rescue e : IO::Error
      # The connection is dead — the recovery loop in open_subscribe_connection
      # will replay this subscription when it reconnects.
      Cable::Logger.error(exception: e) { "Cable::RedisBackend subscribe(#{stream_identifier}) failed; will be replayed after reconnect" }
    end

    def unsubscribe(stream_identifier : String)
      @subscribed_channels_mutex.synchronize { @subscribed_channels.delete(stream_identifier) }
      redis_subscribe.unsubscribe(stream_identifier)
    rescue e : IO::Error
      # Connection died before we could send UNSUBSCRIBE — the channel has been
      # removed from the replay set so the next reconnect will not resubscribe.
      Cable::Logger.error(exception: e) { "Cable::RedisBackend unsubscribe(#{stream_identifier}) failed" }
    end

    # ping/pong

    # since @server.redis_subscribe connection is called on a block loop
    # we basically cannot call ping outside of the block
    # instead, we just spin up another new redis connection
    # then publish a special channel/message broadcast
    # the @server.redis_subscribe picks up this special combination
    # and calls ping on the block loop for us
    def ping_subscribe_connection
      Cable.server.publish(Cable::INTERNAL[:channel], "ping")
    end

    def ping_publish_connection
      result = redis_publish.run({"ping"})
      Cable::Logger.debug { "Cable::BackendPinger.ping_publish_connection -> #{result}" }
    end

    private def replay_tracked_subscriptions
      channels_to_replay = @subscribed_channels_mutex.synchronize { @subscribed_channels.dup }
      channels_to_replay.each do |id|
        begin
          redis_subscribe.subscribe(id)
        rescue e : IO::Error
          # The next reconnect iteration will retry from the tracked set.
          Cable::Logger.error(exception: e) { "Cable::RedisBackend channel replay failed for #{id}" }
        end
      end
    end
  end
end
