# cable-redis

This is a [Cable.cr](https://github.com/cable-cr/cable) backend extension for [jgaskins/redis](https://github.com/jgaskins/redis).

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     cable:
       github: cable-cr/cable
     cable-redis:
       github: cable-cr/cable-redis
   ```

2. Run `shards install`

## Usage

```crystal
require "cable"
require "cable-redis"

Cable.configure do |settings|
  settings.url = ENV.fetch("CABLE_BACKEND_URL", "redis://localhost:6379")
  settings.backend_class = Cable::RedisBackend
  # ... all other Cable config settings
end
```

## Redis

Redis is awesome, but it has complexities that need to be considered;

1. Redis Pub/Sub works really well until you lose the connection...
2. Redis connections can go stale without activity.
3. Redis connection TCP issues can cause unstable connections.
4. Redis DB's have a buffer related to the message sizes called [Output Buffer Limits](https://redis.io/docs/reference/clients/#output-buffer-limits). Exceeding this buffer will not disconnect the connection. It just yields it dead. You cannot know about this except by monitoring logs/metrics.

Here are some ways this shard can help with this.

### Restarting the server

When the first connection is made, the cable server spawns a single pub/sub connection for all subscriptions.
If the connection dies at any point, the server will continue to throw errors unless someone manually restarts the server...

The cable server provides an automated failure rate monitoring/restart function to automate the restart process.

When the server encounters (n) errors are trying to connect to the Redis connection, it restarts the server.
The error rate allowance avoids a vicious cycle i.e. (n) clients attempting to connect vs server restarts while Redis is down.
Generally, if the Redis connection is down, you'll exceed this error allowance quickly. So you may encounter severe back-to-back restarts if Redis is down for a substantial time.
This is expected for any system which uses a Redis backed, and Redis goes down. However, once Redis covers, Cable will self-heal and re-establish all the socket connections.

> NOTE: The automated restart process will also kill all the current client WS connections.
> However, this trade-off allows a fault-tolerant system vs leaving a dead Redis connection hanging around with no pub/sub activity.

**Restart allowance settings**

You can change this setting. However, we advise not going below 20.

```crystal
Cable.configure do |settings|
  settings.restart_error_allowance = 20 # default is 20. Use 0 to disable restarts
end
```

> NOTE: An error log `Cable.restart` will be invoked whenever a restart happens. We highly advise you to monitor these logs.

### Maintain Redis connection activity

When the first connection is made, the cable server starts a Redis PING/PONG task, which runs every 15 seconds. This helps to keep the Redis connection from going stale.

You can change this setting. However, we advise not going over 60 seconds.

```crystal
Cable.configure do |settings|
  settings.backend_ping_interval = 15.seconds # default is 15.
end
```

### Enable pooling and TCP keepalive

The Redis officially supported shard allows us to create a connection pool and also enable TCP keepalive settings.

**Recommended setup**

Start simple with the following settings.
The Redis shard has pretty good default settings for pooling and TCP keepalive.

```crystal
# .env

REDIS_URL: <redis_connection_string>?keepalive=true
```

```crystal
# config/cable.cr

Cable.configure do |settings|
  settings.url = ENV.fetch("REDIS_URL", "redis://localhost:6379")
end
```

> NOTE: This is not enabled by default. You must pass this param to the connection string to ensure this is enabled.

See the [full docs](https://github.com/jgaskins/redis#connection-pool) on the pooling and TCP keepalive capabilities.

### Increase your Redis [Output Buffer Limits](https://redis.io/docs/reference/clients/#output-buffer-limits)

> Technically, this shard cannot help with this.

Exceeding this buffer should be avoided to ensure a stable pub/sub connection.

Options;

1. Double or triple this setting on your Redis DB. 32Mb is usually the default.
2. Ensure you truncate the message sizes client side.


## Development

1. Make the update
2. Add a spec and run `crystal spec`
3. Format it `crystal tool format spec/ src/`
4. Ameba `./bin/ameba`
5. Commit it
6. GO TO 1

## Contributing

1. Fork it (<https://github.com/cable-cr/cable-redis/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jeremy Woertink](https://github.com/jwoertink) - creator and maintainer
