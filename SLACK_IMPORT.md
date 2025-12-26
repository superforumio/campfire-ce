# Slack Import Feature

Import Slack workspace data into Campfire, enabling teams to migrate their chat history from Slack.

## Overview

The Slack Import feature allows users to upload a Slack export ZIP file and have it processed into Campfire's data model. The import handles users, channels, messages, threads, and reactions.

## Architecture

The feature spans two codebases:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         CAMPFIRE CLOUD                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Browser Upload                                                          │
│       │                                                                  │
│       ▼                                                                  │
│  SlackImportsController#create                                           │
│       │                                                                  │
│       ▼                                                                  │
│  ValidateSlackImportJob ──────► R2 Storage                              │
│       │                              │                                   │
│       ▼                              │                                   │
│  ProcessSlackImportJob ◄─────────────┘                                   │
│       │                                                                  │
│       │ SCP + SSH                                                        │
│       ▼                                                                  │
└───────┼──────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      DEPLOYED CAMPFIRE-CE                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  bin/rails slack:import[/disk/slack_export.zip]                         │
│       │                                                                  │
│       ▼                                                                  │
│  SlackImporter Service                                                   │
│       │                                                                  │
│       ├──► Users (placeholder, no email)                                │
│       ├──► Rooms (Open/Closed/Direct)                                   │
│       ├──► Messages (with timestamps preserved)                         │
│       ├──► Threads (from thread_ts)                                     │
│       └──► Boosts (from reactions)                                      │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Slack Export Format

Slack exports are ZIP files with this structure:

```
export.zip/
├── users.json           # User profiles
├── channels.json        # Public channels
├── groups.json          # Private channels (Business+ only)
├── dms.json             # Direct messages (Business+ only)
└── <channel-name>/      # Message folder per channel
    ├── 2024-01-01.json
    ├── 2024-01-02.json
    └── ...
```

**Export Limitations by Plan:**
- Free/Pro: Public channels only
- Business+/Enterprise: Full export including private channels and DMs

## Data Mapping

| Slack Entity | Campfire Entity | Notes |
|--------------|-----------------|-------|
| User | User | Placeholder (no email, claimable later) |
| Public Channel | Rooms::Open | Auto-membership for listed members |
| Private Channel | Rooms::Closed | Explicit membership |
| DM | Rooms::Direct | 2+ participant matching |
| Thread (thread_ts) | Rooms::Thread | Linked to parent message |
| Reaction | Boost | Emoji name → Unicode mapping |
| `<@U123>` mention | `@username` | Plain text conversion |
| `<#C123\|name>` | `#name` | Channel reference |
| `<!channel>` | `@channel` | Broadcast mention |

## Usage

### Via Rake Task (campfire-ce)

Run directly on a Campfire instance:

```bash
bin/rails slack:import[/path/to/slack_export.zip]
```

Output:
```
Starting Slack import from: /path/to/slack_export.zip
Found 25 users in export
Imported 23 users
Found 10 public channels
Created room: #General
Created room: #Random
...
Imported 5432 messages...
Processing 89 thread replies...
Created 45 threads

IMPORT_COMPLETE
IMPORT_STATS:{"users":23,"rooms":10,"messages":5432,"threads":45,"boosts":234}
```

### Via Web UI (campfire_cloud)

1. Navigate to Server Settings → Import Data → From Slack
2. Upload your `slack_export.zip` file (max 500MB)
3. System validates the ZIP structure
4. Progress updates shown in real-time via WebSocket
5. Import completes with summary stats

## Implementation Details

### campfire-ce Components

**`lib/tasks/slack.rake`**
Entry point for the import. Accepts ZIP path, runs SlackImporter, outputs parseable stats.

**`app/services/slack_importer.rb`**
Core import logic:
- Transaction-wrapped for atomicity
- Imports users as placeholders (no email required)
- Creates rooms with appropriate STI types
- Preserves original message timestamps
- Handles thread_ts for thread creation
- Converts reactions to Boosts with emoji mapping

### campfire_cloud Components

**Model:** `SlackImport`
- Status: `pending` → `validating` → `uploading` → `processing` → `completed|failed`
- Stores stats, validation results, error messages

**Jobs:**
- `ValidateSlackImportJob` - Validates ZIP structure, uploads to R2
- `ProcessSlackImportJob` - Downloads from R2, transfers via SSH, runs rake task

**Controller:** `SlackImportsController`
- `new` - Upload form with instructions
- `create` - File validation, record creation
- `show` - Progress page with Turbo Stream updates
- `index` - Import history

## User Handling

Imported users are created as **placeholder accounts**:
- No email address (bypasses validation)
- No password (cannot log in)
- Marked with `slack_import: true` in preferences
- Stores `slack_user_id` and `slack_username` for future claiming

Users can later claim their imported account by:
1. Signing up with matching email
2. Admin manually linking accounts

## Message Conversion

### Mentions
```
<@U12345ABC>           → @username (first name)
<@U12345ABC|display>   → @username
<!channel>             → @channel
<!here>                → @here
<!everyone>            → @everyone
```

### Links
```
<https://example.com>              → https://example.com
<https://example.com|Example>      → Example (https://example.com)
```

### Channel References
```
<#C12345ABC|general>   → #general
```

### Skipped Message Types
- `channel_join` - User joined channel
- `channel_leave` - User left channel
- `channel_purpose` - Purpose was set
- `channel_topic` - Topic was changed

## Emoji Mapping

Common Slack emoji names are mapped to Unicode:

| Slack | Unicode |
|-------|---------|
| thumbsup, +1 | 👍 |
| heart | ❤️ |
| fire | 🔥 |
| tada | 🎉 |
| rocket | 🚀 |
| eyes | 👀 |
| 100 | 💯 |

Unknown emoji default to 👍.

## Error Handling

| Scenario | Handling |
|----------|----------|
| Invalid ZIP format | Validation fails with error message |
| Missing users.json/channels.json | Validation fails |
| SSH connection failure | Job retry (2 attempts) |
| Rake task error | Status set to failed, error logged |
| Malformed JSON | Skip entry, log warning, continue |
| Duplicate slugs | Auto-increment suffix (general-1, general-2) |

All imports are wrapped in a database transaction - if any step fails, all changes are rolled back.

## Testing

Run the test suite:

```bash
bin/rails test test/services/slack_importer_test.rb
```

Test fixtures are in `test/fixtures/slack_export/`:
- `users.json` - Sample users (active, deleted, bot)
- `channels.json` - Sample channels
- `general/2024-01-15.json` - Messages with mentions, reactions, threads
- `random/2024-01-15.json` - Messages with channel references

## Security Considerations

- **File size limit**: 500MB max upload
- **R2 storage**: Keys scoped to `slack_imports/{subdomain}/`
- **Cleanup**: Files deleted from R2 and server after import
- **Access control**: Only server owners/admins can import
- **Execution**: Rake task runs inside Docker container isolation
- **No credentials**: Imported users have no login capability

## Limitations

- **No file attachments**: Only message text is imported
- **No avatar images**: Users get default avatars
- **No private data without Business+**: Free/Pro exports only include public channels
- **No real-time sync**: One-time import only
- **Timestamp precision**: Preserved to the second (Slack uses microseconds)

## Future Enhancements

Potential improvements:
- Email matching for auto-claiming user accounts
- File/attachment download support
- Import progress percentage
- Selective channel import
- Dry-run mode for previewing changes
