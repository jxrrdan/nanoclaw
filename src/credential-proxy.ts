/**
 * Credential proxy for container isolation.
 * Containers connect here instead of directly to the Anthropic API.
 * The proxy injects real credentials so containers never see them.
 *
 * Auth strategy:
 *   Primary:  Claude.ai OAuth (uses the Claude Code plan — no per-token cost).
 *   Fallback: Anthropic API key (pay-per-use), activated automatically when
 *             the Claude.ai plan quota is exhausted (429 rate_limit_error).
 *             Fallback resets at midnight so the plan is retried the next day.
 *
 * Per-request injection (handles both modes simultaneously so containers
 * started before a mode switch finish their session cleanly):
 *   x-api-key: placeholder     → inject real API key
 *   Authorization: Bearer placeholder → inject real OAuth token
 *   Any other credential       → pass through (e.g. temp key from OAuth exchange)
 */
import { createServer, Server } from 'http';
import { request as httpsRequest } from 'https';
import { request as httpRequest, RequestOptions } from 'http';

import { readEnvFile } from './env.js';
import { logger } from './logger.js';

export type AuthMode = 'api-key' | 'oauth';

export interface ProxyConfig {
  authMode: AuthMode;
}

// Secrets loaded once at startCredentialProxy() — before any containers spawn.
let _apiKey = '';
let _oauthToken = '';
let _upstreamUrl = new URL('https://api.anthropic.com');

// Fallback state: when Claude.ai plan quota is exhausted, switch to API key
// for new container spawns until midnight (when the plan resets).
let _fallbackActive = false;
let _fallbackUntil = 0;

function checkFallbackExpiry(): void {
  if (_fallbackActive && Date.now() > _fallbackUntil) {
    _fallbackActive = false;
    logger.info('Claude.ai plan quota reset — resuming OAuth primary mode');
  }
}

function activateFallback(): void {
  if (_fallbackActive || !_apiKey || !_oauthToken) return;
  _fallbackActive = true;
  const midnight = new Date();
  midnight.setDate(midnight.getDate() + 1);
  midnight.setHours(0, 0, 0, 0);
  _fallbackUntil = midnight.getTime();
  logger.warn(
    { resumesAt: midnight.toISOString() },
    'Claude.ai plan quota exhausted — switching to Anthropic API key fallback',
  );
}

/**
 * Returns the auth mode new containers should be started with.
 * Primary is always OAuth when configured; fallback is API key.
 * Called by container-runner at spawn time — not per-request.
 */
export function getCurrentAuthMode(): AuthMode {
  checkFallbackExpiry();
  if (!_oauthToken) return 'api-key'; // OAuth not configured — always API key
  if (_fallbackActive && _apiKey) return 'api-key'; // Quota exhausted — use API key
  return 'oauth';
}

/** Kept for backwards compatibility — delegates to getCurrentAuthMode(). */
export function detectAuthMode(): AuthMode {
  return getCurrentAuthMode();
}

export function startCredentialProxy(
  port: number,
  host = '127.0.0.1',
): Promise<Server> {
  const secrets = readEnvFile([
    'ANTHROPIC_API_KEY',
    'CLAUDE_CODE_OAUTH_TOKEN',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_BASE_URL',
  ]);

  _apiKey = secrets.ANTHROPIC_API_KEY || '';
  _oauthToken =
    secrets.CLAUDE_CODE_OAUTH_TOKEN || secrets.ANTHROPIC_AUTH_TOKEN || '';
  _upstreamUrl = new URL(
    secrets.ANTHROPIC_BASE_URL || 'https://api.anthropic.com',
  );

  const initialMode = getCurrentAuthMode();

  if (_oauthToken && !_apiKey) {
    logger.warn(
      'ANTHROPIC_API_KEY not set — quota fallback to API key is disabled',
    );
  }

  const isHttps = _upstreamUrl.protocol === 'https:';
  const makeRequest = isHttps ? httpsRequest : httpRequest;

  return new Promise((resolve, reject) => {
    const server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        const body = Buffer.concat(chunks);
        const headers: Record<string, string | number | string[] | undefined> =
          {
            ...(req.headers as Record<string, string>),
            host: _upstreamUrl.host,
            'content-length': body.length,
          };

        // Strip hop-by-hop headers that must not be forwarded by proxies
        delete headers['connection'];
        delete headers['keep-alive'];
        delete headers['transfer-encoding'];

        // Inject credentials based on the placeholder the container sent.
        // Handling both modes simultaneously means containers started before
        // a fallback switch finish their session without disruption.
        if (headers['x-api-key'] === 'placeholder') {
          if (_apiKey) headers['x-api-key'] = _apiKey;
        } else if (headers['authorization'] === 'Bearer placeholder') {
          if (_oauthToken) {
            headers['authorization'] = `Bearer ${_oauthToken}`;
          } else {
            delete headers['authorization'];
          }
        }
        // Any other credential (e.g. temp key from OAuth exchange) passes through.

        const upstream = makeRequest(
          {
            hostname: _upstreamUrl.hostname,
            port: _upstreamUrl.port || (isHttps ? 443 : 80),
            path: req.url,
            method: req.method,
            headers,
          } as RequestOptions,
          (upRes) => {
            // Detect quota exhaustion: buffer 429 responses to read the error
            // type, then activate API key fallback for subsequent container spawns.
            // Only triggers when both credentials are available and fallback isn't
            // already active.
            if (
              upRes.statusCode === 429 &&
              _oauthToken &&
              _apiKey &&
              !_fallbackActive
            ) {
              const responseChunks: Buffer[] = [];
              upRes.on('data', (c) => responseChunks.push(c));
              upRes.on('end', () => {
                const responseBody = Buffer.concat(responseChunks);
                try {
                  const parsed = JSON.parse(responseBody.toString());
                  if (parsed?.error?.type === 'rate_limit_error') {
                    activateFallback();
                  }
                } catch {
                  // Non-JSON 429 — ignore, don't activate fallback
                }
                // Forward the buffered error response to the container
                const outHeaders: Record<
                  string,
                  string | number | string[] | undefined
                > = { ...upRes.headers };
                delete outHeaders['transfer-encoding'];
                outHeaders['content-length'] = responseBody.length;
                res.writeHead(upRes.statusCode!, outHeaders);
                res.end(responseBody);
              });
              return;
            }

            res.writeHead(upRes.statusCode!, upRes.headers);
            upRes.pipe(res);
          },
        );

        upstream.on('error', (err) => {
          logger.error(
            { err, url: req.url },
            'Credential proxy upstream error',
          );
          if (!res.headersSent) {
            res.writeHead(502);
            res.end('Bad Gateway');
          }
        });

        upstream.write(body);
        upstream.end();
      });
    });

    server.listen(port, host, () => {
      logger.info({ port, host, authMode: initialMode }, 'Credential proxy started');
      resolve(server);
    });

    server.on('error', reject);
  });
}
