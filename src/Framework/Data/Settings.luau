-- Bullet Heaven data settings.
-- key:     DataStore key prefix (ProfileStore store name is `{key}_{version}`).
-- version: bump when Template's shape changes breakingly; add the matching MIGRATIONS[n] step in
--          Data/init.luau. The store name embeds this, so a bump is a hard cutover (no downgrade).
-- mock:    false = real DataStoreService (persists across playtests in Studio when "Game Settings ->
--          Security -> Enable Studio Access to API Services" is ON, and correct for production).
--          true = ProfileStore in-memory mock (wiped each playtest) — unit-test scaffolds only.

return {
    key = 'BulletHeaven';
    version = 1;
    mock = false;
}
