import { SecretClient } from '@azure/keyvault-secrets';
import { DefaultAzureCredential } from '@azure/identity';

import { setSecretsCache } from './env.js';
import { logger } from './logger.js';

// Key Vault secret names use hyphens; env var names use underscores.
// e.g. ANTHROPIC-API-KEY -> ANTHROPIC_API_KEY
function vaultNameToEnvKey(name: string): string {
  return name.replace(/-/g, '_').toUpperCase();
}

// The secrets NanoClaw needs from Key Vault.
// Only fetch what exists — missing secrets are silently skipped.
const SECRET_NAMES = [
  'ANTHROPIC-API-KEY',
  'CLAUDE-CODE-OAUTH-TOKEN',
  'ANTHROPIC-AUTH-TOKEN',
];

export async function loadKeyVaultSecrets(vaultUrl: string): Promise<void> {
  const credential = new DefaultAzureCredential();
  const client = new SecretClient(vaultUrl, credential);

  const fetched: Record<string, string> = {};

  await Promise.all(
    SECRET_NAMES.map(async (name) => {
      try {
        const secret = await client.getSecret(name);
        if (secret.value) {
          fetched[vaultNameToEnvKey(name)] = secret.value;
        }
      } catch (err: unknown) {
        // SecretNotFound is expected when a secret isn't configured — skip silently.
        // Any other error (auth, network) is worth logging.
        const isNotFound =
          err instanceof Error && err.message.includes('SecretNotFound');
        if (!isNotFound) {
          logger.warn({ name, err }, 'Failed to fetch secret from Key Vault');
        }
      }
    }),
  );

  const count = Object.keys(fetched).length;
  logger.info({ vaultUrl, count }, 'Loaded secrets from Azure Key Vault');
  setSecretsCache(fetched);
}
