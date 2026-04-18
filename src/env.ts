import fs from 'fs';
import path from 'path';
import { logger } from './logger.js';

// In-memory cache populated at startup (e.g. from Azure Key Vault).
// Takes priority over .env and process.env so secrets never need to be on disk.
let _secretsCache: Record<string, string> = {};

export function setSecretsCache(secrets: Record<string, string>): void {
  _secretsCache = { ..._secretsCache, ...secrets };
}

/**
 * Parse the .env file and return values for the requested keys.
 * Does NOT load anything into process.env — callers decide what to
 * do with the values. This keeps secrets out of the process environment
 * so they don't leak to child processes.
 *
 * Priority: in-memory cache (Key Vault) > .env file > process.env
 */
export function readEnvFile(keys: string[]): Record<string, string> {
  const envFile = path.join(process.cwd(), '.env');
  let content = '';
  try {
    content = fs.readFileSync(envFile, 'utf-8');
  } catch {
    logger.debug('.env file not found, falling back to process.env');
  }

  const result: Record<string, string> = {};
  const wanted = new Set(keys);

  for (const line of content.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIdx = trimmed.indexOf('=');
    if (eqIdx === -1) continue;
    const key = trimmed.slice(0, eqIdx).trim();
    if (!wanted.has(key)) continue;
    let value = trimmed.slice(eqIdx + 1).trim();
    if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }
    if (value) result[key] = value;
  }

  // Fall back to process.env for any keys not found in the file.
  for (const key of keys) {
    if (!result[key] && process.env[key]) {
      result[key] = process.env[key]!;
    }
  }

  // In-memory cache (Key Vault) overrides everything — applied last so secrets
  // loaded at startup always win over stale .env values.
  for (const key of keys) {
    if (_secretsCache[key]) {
      result[key] = _secretsCache[key];
    }
  }

  return result;
}
