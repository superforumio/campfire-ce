# AnyCable Implementation Plan

This document outlines the plan to add AnyCable support to campfire-ce for improved WebSocket scalability.

## Problem

Rails Action Cable has significant scalability limitations for real-time chat applications:

| Metric | Action Cable | AnyCable |
|--------|-------------|----------|
| Concurrent connections | ~200 before crashes | 52,000+ |
| Memory per connection | 3.1MB | 0.2MB |
| P95 latency | 840ms | 62ms |
| Message loss under load | 17% | 0% |
| Recovery time | 8+ seconds | 1.4 seconds |

Reference: https://github.com/antiwork/smallbets/issues/97

## Solution: HTTP RPC Mode

AnyCable offers multiple RPC modes. We'll use **HTTP RPC** as the simplest approach:

- No gRPC dependencies
- No separate RPC process
- Rails mounts an HTTP endpoint that AnyCable-Go calls
- Minimal configuration

### Architecture

**Before (Action Cable):**
```
┌─────────────────────────────────────────────────────┐
│                   campfire-ce instance              │
│  ┌──────────┐   ┌────────────────┐   ┌───────────┐ │
│  │  Caddy   │──▶│  campfire-web  │   │ Litestream│ │
│  │  :443    │   │   Rails+Redis  │   │  backup   │ │
│  └──────────┘   │   ActionCable  │   └───────────┘ │
│                 │     :3000      │                  │
│                 └────────────────┘                  │
└─────────────────────────────────────────────────────┘
```

**After (AnyCable):**
```
┌──────────────────────────────────────────────────────────────┐
│                     campfire-ce instance                     │
│                                                              │
│  ┌────────┐   /cable    ┌─────────────┐                     │
│  │ Caddy  │────────────▶│ anycable-go │                     │
│  │  :443  │             │    :8080    │                     │
│  │        │   /*        │             │                     │
│  │        │────────┐    └──────┬──────┘                     │
│  └────────┘        │           │                            │
│                    │           │ HTTP RPC (/_anycable)      │
│                    │           │ HTTP Broadcast (/_broadcast)│
│                    │           ▼                            │
│                    │    ┌────────────────┐   ┌───────────┐  │
│                    └───▶│  campfire-web  │   │ Litestream│  │
│                         │  Rails :3000   │   │  backup   │  │
│                         └────────────────┘   └───────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **WebSocket Connection**: Client connects to `wss://domain.com/cable`
2. **Caddy Routing**: Routes `/cable` to `anycable-go:8080`
3. **Authentication**: AnyCable-Go calls Rails at `/_anycable` to authenticate
4. **Channel Subscription**: AnyCable-Go calls Rails RPC for channel logic (subscribe/unsubscribe)
5. **Broadcasting**: Rails broadcasts via HTTP to AnyCable-Go at `/_broadcast`
6. **Message Delivery**: AnyCable-Go pushes to connected WebSocket clients

## Development Testing

Test AnyCable changes locally before deploying to production.

### Step 1: Install AnyCable-Go Binary

```bash
# macOS (Homebrew)
brew install anycable-go

# Or download directly
curl -fsSL https://github.com/anycable/anycable-go/releases/download/v1.6.3/anycable-go-darwin-arm64 -o /usr/local/bin/anycable-go
chmod +x /usr/local/bin/anycable-go

# Verify installation
anycable-go --version
```

### Step 2: Add AnyCable Gem

```bash
cd /path/to/campfire-ce
bundle add anycable-rails
```

### Step 3: Create Configuration Files

**config/anycable.yml:**
```yaml
default: &default
  # Mount HTTP RPC endpoint in Rails
  http_rpc_mount_path: "/_anycable"

  # Use HTTP for broadcasting
  broadcast_adapter: http
  http_broadcast_url: "http://localhost:8080/_broadcast"

development:
  <<: *default
  websocket_url: "ws://localhost:8080/cable"
  secret: "development-secret-change-in-production"

test:
  <<: *default
  secret: "test-secret"

production:
  <<: *default
  websocket_url: <%= "wss://#{ENV['APP_HOST']}/cable" %>
  secret: <%= ENV["ANYCABLE_SECRET"] %>
```

### Step 4: Update Cable Configuration

**config/cable.yml:**
```yaml
default: &default
  adapter: redis
  url: redis://localhost:6379

development:
  adapter: any_cable  # Change from redis to any_cable
  channel_prefix: campfire_development

test:
  adapter: test

performance:
  <<: *default
  channel_prefix: campfire_performance

production:
  adapter: any_cable  # Change from redis to any_cable
  channel_prefix: campfire_production
```

### Step 5: Update Procfile.dev

**Procfile.dev:**
```
vite: bin/vite dev
web: PORT=3000 bin/rails s
anycable: anycable-go --port=8080 --rpc_host=http://localhost:3000/_anycable --broadcast_adapter=http --secret=development-secret-change-in-production
```

### Step 6: Update JavaScript WebSocket URL

The JavaScript client needs to connect to AnyCable instead of Rails. Check if the WebSocket URL is hardcoded or uses the meta tag.

**app/views/layouts/application.html.erb:**
```erb
<%# Ensure this meta tag is present - it tells ActionCable JS where to connect %>
<%= action_cable_meta_tag %>
```

**app/frontend/entrypoints/application.js** (if WebSocket URL is configured):
```javascript
// If you have custom ActionCable configuration, update the URL:
// In development, this should point to AnyCable-Go at ws://localhost:8080/cable
// The action_cable_meta_tag helper handles this automatically
```

### Step 7: Run Development Server

```bash
# Terminal 1: Start all services with foreman/overmind
bin/rails dev

# Or run each process manually:
# Terminal 1: Rails
bin/rails s

# Terminal 2: Vite
bin/vite dev

# Terminal 3: AnyCable-Go
anycable-go --port=8080 \
  --rpc_host=http://localhost:3000/_anycable \
  --broadcast_adapter=http \
  --secret=development-secret-change-in-production \
  --log_level=debug
```

### Step 8: Verify It's Working

1. **Check AnyCable-Go started:**
   ```
   INFO 2024-01-01T00:00:00.000Z context=main Starting AnyCable 1.6.3
   INFO 2024-01-01T00:00:00.000Z context=main Handle WebSocket connections at http://localhost:8080/cable
   INFO 2024-01-01T00:00:00.000Z context=http RPC server endpoint: http://localhost:3000/_anycable
   ```

2. **Open browser console**, navigate to a room, check WebSocket connection:
   ```
   // Should see connection to ws://localhost:8080/cable instead of ws://localhost:3000/cable
   ```

3. **Test real-time features:**
   - Open two browser windows to the same room
   - Send a message - should appear in both windows
   - Start typing - typing indicator should appear
   - Check presence (user online/offline status)

4. **Check AnyCable logs for RPC calls:**
   ```
   DEBUG context=rpc RPC Connect: {"user_id": 1}
   DEBUG context=rpc RPC Subscribe: {"channel": "RoomChannel", "room_id": 1}
   ```

### Step 9: Run Tests

```bash
# Run the full test suite to ensure nothing broke
bin/rails test

# Run system tests (these test real WebSocket behavior)
bin/rails test:system
```

### Troubleshooting Development Setup

**WebSocket still connecting to Rails (port 3000):**
- Check `action_cable_meta_tag` is in your layout
- Verify `config/anycable.yml` has correct `websocket_url` for development
- Clear browser cache / hard refresh

**RPC connection refused:**
- Ensure Rails is running and accessible at localhost:3000
- Check `http_rpc_mount_path: "/_anycable"` is set
- Test RPC endpoint: `curl http://localhost:3000/_anycable` (should return error about missing headers, not 404)

**Broadcasts not working:**
- Verify `broadcast_adapter: http` in anycable.yml
- Check AnyCable-Go is receiving broadcasts: look for `broadcast` in debug logs
- Ensure `http_broadcast_url` points to AnyCable-Go

**Channel subscription rejected:**
- Check Rails logs for authentication errors
- Verify the user is logged in
- Check channel authorization logic in `RoomChannel#find_room`

---

## Implementation

### Phase 1: campfire-ce Changes

#### 1.1 Add AnyCable Gem

```ruby
# Gemfile
gem "anycable-rails", "~> 1.5"
```

#### 1.2 Create AnyCable Configuration

```yaml
# config/anycable.yml
default: &default
  # Mount HTTP RPC endpoint in Rails
  http_rpc_mount_path: "/_anycable"

  # Use HTTP for broadcasting (AnyCable-Go receives at /_broadcast)
  broadcast_adapter: http
  http_broadcast_url: "http://localhost:8080/_broadcast"

development:
  <<: *default
  websocket_url: "ws://localhost:8080/cable"
  secret: "development-secret"

test:
  <<: *default

production:
  <<: *default
  websocket_url: <%= "wss://#{ENV['APP_HOST']}/cable" %>
  secret: <%= ENV["ANYCABLE_SECRET"] %>
```

#### 1.3 Update Cable Configuration

```yaml
# config/cable.yml
default: &default
  adapter: redis
  url: redis://localhost:6379

development:
  <<: *default
  channel_prefix: campfire_development

test:
  adapter: test

production:
  adapter: any_cable
```

#### 1.4 Update Layout for JWT Auth (if needed)

If using JWT authentication for WebSocket connections:

```erb
<%# app/views/layouts/application.html.erb %>
<%= action_cable_with_jwt_meta_tag if defined?(action_cable_with_jwt_meta_tag) %>
```

#### 1.5 Environment Variables

New required environment variable:
- `ANYCABLE_SECRET` - Shared secret between Rails and AnyCable-Go

### Phase 2: campfire_cloud Changes

#### 2.1 Update DockerComposeGenerator

Add AnyCable container to `generate_compose_file`:

```ruby
def generate_compose_file
  # ... existing code ...

  <<~YAML
    services:
      web:
        # ... existing web config ...

      anycable:
        image: anycable/anycable-go:1.6
        container_name: campfire-anycable
        restart: unless-stopped
        environment:
          - ANYCABLE_HOST=0.0.0.0
          - ANYCABLE_PORT=8080
          - ANYCABLE_RPC_HOST=http://web:3000/_anycable
          - ANYCABLE_BROADCAST_ADAPTER=http
          - ANYCABLE_HTTP_BROADCAST_PORT=8080
          - ANYCABLE_SECRET=${ANYCABLE_SECRET}
          - ANYCABLE_LOG_LEVEL=info
        depends_on:
          web:
            condition: service_healthy
        healthcheck:
          test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
          interval: 30s
          timeout: 10s
          retries: 3
          start_period: 10s
        logging:
          driver: "json-file"
          options:
            max-size: "10m"
            max-file: "3"

      litestream:
        # ... existing litestream config ...

      caddy:
        # ... existing caddy config ...
        depends_on:
          - web
          - anycable  # Add dependency

    volumes:
      # ... existing volumes ...
  YAML
end
```

#### 2.2 Update Caddyfile Generator

```ruby
def generate_caddyfile
  base_domain = Rails.application.credentials.dig(:base_domain) || ENV["BASE_DOMAIN"] || "campfirecloud.com"
  domains = ["#{@server.subdomain}.#{base_domain}"]
  domains << @server.custom_domain if @server.custom_domain.present?

  <<~CADDY
    # Automatic HTTPS for: #{domains.join(", ")}
    #{domains.join(", ")} {
        # Route WebSocket connections to AnyCable
        handle /cable {
            reverse_proxy anycable:8080
        }

        # Route AnyCable health checks (optional, for debugging)
        handle /anycable/health {
            reverse_proxy anycable:8080/health
        }

        # Everything else to Rails
        handle {
            reverse_proxy web:3000
        }

        # Enable compression
        encode gzip

        # Security headers
        header {
            Strict-Transport-Security "max-age=31536000;"
            X-Content-Type-Options "nosniff"
            X-Frame-Options "SAMEORIGIN"
            X-XSS-Protection "1; mode=block"
            Referrer-Policy "strict-origin-when-cross-origin"
        }

        # Logging
        log {
            output file /data/access.log
            format json
        }
    }
  CADDY
end
```

#### 2.3 Update Environment File Generator

Add AnyCable secret generation to `generate_env_file`:

```ruby
def generate_env_file
  env_vars = parse_environment_variables

  # ... existing code ...

  # AnyCable secret (generate once and persist)
  if env_vars["ANYCABLE_SECRET"].blank?
    env_vars["ANYCABLE_SECRET"] = SecureRandom.hex(32)
    @server.update(environment_variables: env_vars.to_json)
    @server.reload
  end

  # ... rest of existing code ...
end
```

#### 2.4 Update Container Monitoring

Update `wait_for_containers` in `DeployApplicationJob`:

```ruby
def wait_for_containers(server, deployment, ssh, max_attempts: 20)
  expected_containers = [
    "campfire-web",
    "campfire-anycable",  # Add AnyCable
    "campfire-caddy",
    "campfire-litestream"
  ]
  # ... rest of method ...
end
```

Update `capture_container_logs`:

```ruby
def capture_container_logs(ssh, deployment)
  %w[campfire-web campfire-anycable campfire-caddy campfire-litestream].each do |container|
    # ... existing code ...
  end
end
```

### Phase 3: Testing

#### 3.1 Local Testing

1. Update campfire-ce locally with AnyCable config
2. Create a test docker-compose.yml with all 4 containers
3. Verify WebSocket connections route correctly
4. Test all 14 ActionCable channels work:
   - `RoomChannel`
   - `PresenceChannel`
   - `TypingNotificationsChannel`
   - `InboxMentionsChannel`
   - `InboxThreadsChannel`
   - `UnreadRoomsChannel`
   - `UserUnreadRoomsChannel`
   - `RoomListChannel`
   - `HeartbeatChannel`
   - `ReadRoomsChannel`
   - `UnreadNotificationsChannel`
   - `UserInvolvementsChannel`

#### 3.2 Integration Testing

1. Deploy a test instance via campfire_cloud
2. Monitor AnyCable logs for connection/RPC issues
3. Load test with multiple concurrent users
4. Verify presence, typing indicators, real-time messages work

### Phase 4: Rollout

#### 4.1 Feature Flag (Optional)

Add server-level toggle for AnyCable:

```ruby
# Server model
# Add: anycable_enabled boolean column

def generate_compose_file
  if @server.anycable_enabled?
    generate_compose_with_anycable
  else
    generate_compose_legacy
  end
end
```

#### 4.2 Gradual Rollout

1. Deploy to staging/test instances first
2. Monitor for 1-2 weeks
3. Enable for new instances by default
4. Migrate existing instances during maintenance windows

## Configuration Reference

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ANYCABLE_SECRET` | Shared secret for auth and signing | Generated |
| `ANYCABLE_LOG_LEVEL` | Log verbosity (debug/info/warn/error) | info |

### AnyCable-Go Settings

| Setting | Value | Purpose |
|---------|-------|---------|
| `ANYCABLE_HOST` | 0.0.0.0 | Listen on all interfaces |
| `ANYCABLE_PORT` | 8080 | WebSocket server port |
| `ANYCABLE_RPC_HOST` | http://web:3000/_anycable | Rails RPC endpoint |
| `ANYCABLE_BROADCAST_ADAPTER` | http | Use HTTP for broadcasts |
| `ANYCABLE_HTTP_BROADCAST_PORT` | 8080 | Broadcast receiver port |

## Monitoring

### Health Checks

- **AnyCable-Go**: `GET /health` on port 8080
- **Rails RPC**: Responds at `/_anycable` (internal)

### Metrics (Future)

AnyCable-Go exposes Prometheus metrics at `/metrics`:
- `anycable_clients_num` - Current connected clients
- `anycable_clients_total` - Total connections
- `anycable_broadcast_msg_total` - Broadcast messages
- `anycable_rpc_call_total` - RPC calls to Rails

## Troubleshooting

### Common Issues

**WebSocket connection fails:**
1. Check Caddy logs for routing issues
2. Verify AnyCable container is healthy
3. Check `ANYCABLE_SECRET` matches in both containers

**Channel subscriptions fail:**
1. Check AnyCable logs for RPC errors
2. Verify Rails is responding at `/_anycable`
3. Check Rails logs for authentication issues

**Broadcasts not received:**
1. Verify `broadcast_adapter: http` in anycable.yml
2. Check AnyCable-Go is receiving at `/_broadcast`
3. Verify client is subscribed to correct channel

### Debug Mode

Enable verbose logging:
```yaml
environment:
  - ANYCABLE_LOG_LEVEL=debug
  - ANYCABLE_DEBUG=true
```

## Resources

- [AnyCable Documentation](https://docs.anycable.io/)
- [AnyCable Rails Guide](https://docs.anycable.io/rails/getting_started)
- [AnyCable Kamal Deployment](https://docs.anycable.io/deployment/kamal)
- [HTTP RPC Documentation](https://docs.anycable.io/ruby/http_rpc)
- [GitHub Issue #97](https://github.com/antiwork/smallbets/issues/97)
