# Database migration strategy

Storage:
- **SQLite** `safeguard.db` (`SafeGuardDatabase`, schema **v4**) for
  rules, events, counters, meta, protected apps, AI feedback and keywords.
- **SharedPreferences** for settings.
- **Keystore-backed secure storage** for the PIN.
- A private **config backup file** (Phase 8).

## Rules

1. **One step per version.** `onUpgrade` runs `migrateToV2`, `V3`, `V4`,
   … in order, so every older version reaches the current one.
2. **Additive only during normal updates.** New tables, new columns with
   defaults, new indexes. Never drop a table or column that holds user
   configuration, and never rewrite user rows destructively.
3. **Transactions.** Android's `SQLiteOpenHelper` runs `onCreate` /
   `onUpgrade` / `onDowngrade` inside one transaction. If any statement
   throws, the whole migration rolls back and the version isn't bumped,
   so the next open retries from the same state.
4. **Defaults preserve behaviour.** Example: v4's
   `include_subdomains DEFAULT 1` keeps existing allowlist entries
   covering subdomains, as before.
5. **Test every migration.** `MigrationTest` (Robolectric) builds the
   verbatim v1 schema with user rows and checks they survive to the
   current version. **It runs in CI and has not been executed in the
   development container.** Add a case for every new version.
6. **Preferences.** Readers are tolerant: unknown keys are ignored and
   missing keys fall back to defaults (`AppSettings.fromJson`,
   `ProtectionConfigStore` getters). A key is renamed only with a
   one-time copy and delete at start-up. Example: Phase 6 deleted
   `event_hash_key` after moving it to the Keystore.

## Adding a migration (checklist)

- [ ] Bump `SafeGuardDatabase.VERSION`.
- [ ] Add `migrateToVn(db)` with additive statements.
- [ ] Update `onCreate` so fresh installs get the same schema.
- [ ] Add a `MigrationTest` case from vn-1 with representative user data.
- [ ] If a table holding user configuration changes, update
      `UserConfigBackup` (format version) so backups still restore.
- [ ] CHANGELOG *Migration notes* + *Rollback*.

## Recovery

| Situation | Behaviour |
|---|---|
| Migration throws | Transaction rolls back; old schema intact; retried next start. Rule lookups fail closed to the bundled lists (Phase 7), and the health monitor reports the database layer and retries with backoff (Phase 8) |
| Database file corrupted | SQLite's default error handler deletes the file; `onCreate` rebuilds it (`createdFresh`), built-in rules are re-seeded, and **the user's lists, keywords and protected apps are restored from `no_backup/user-config.bak`** (re-validated line by line) |
| Older app installed over newer (downgrade) | `onDowngrade` rebuilds the schema, then the same config restore runs. The log and statistics are lost; configuration is kept |
| Temporary failure (disk full, locked) | Log writes are dropped and counted (`logWriteFailures`); lookups fall back to bundled lists; the monitor re-checks |
| "Delete all data" | The DB is cleared **and** the backup file is deleted first, so nothing comes back |

The backup never contains logs or statistics. It lives in
`noBackupFilesDir`, so it's never part of Android cloud backup.

## Backward compatibility

- Settings JSON (`sg.settings.v1`) and protection state (`sg.protection.v1`) are decoded
  tolerantly, so older and newer versions can read each other's data.
- The DB schema is v4 in 1.4.0–1.7.0, so installing any of these over
  another keeps all data.
- Play doesn't allow installing a lower `versionCode`. A production
  "rollback" is a new release with the old code and a higher
  `versionCode` (docs/RELEASE.md).
