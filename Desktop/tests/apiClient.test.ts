import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { ApiError, fetchJson, retryDelay } from '../src/apiClient.ts';

const originalFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = originalFetch; });

test('structured errors retain the support identifier', async () => {
  globalThis.fetch = async () => new Response(JSON.stringify({error:'磁盘已满',code:'STORAGE_FULL',request_id:'abc'}), {status:507});
  await assert.rejects(fetchJson('/api/test'), (error: unknown) => error instanceof ApiError && error.code === 'STORAGE_FULL' && error.requestId === 'abc');
});

test('a mutation is sent once and never retried after disconnection', async () => {
  let calls = 0;
  globalThis.fetch = async () => { calls++; throw new TypeError('offline'); };
  await assert.rejects(fetchJson('/api/start', {method:'POST'}), (error: unknown) => error instanceof ApiError && !error.retryable && error.code === 'UNAVAILABLE');
  assert.equal(calls, 1);
});

test('deadline includes reading a stalled response body', async () => {
  globalThis.fetch = async (_url, options) => {
    const stream = new ReadableStream({start(controller) {
      options?.signal?.addEventListener('abort', () => controller.error(new DOMException('aborted', 'AbortError')));
    }});
    return new Response(stream);
  };
  await assert.rejects(fetchJson('/api/state', {timeoutMs:20}), (error: unknown) => error instanceof ApiError && error.code === 'DEADLINE_EXCEEDED');
});

test('caller cancellation is distinguished from timeout', async () => {
  globalThis.fetch = async (_url, options) => {
    if (options?.signal?.aborted) throw new DOMException('aborted', 'AbortError');
    throw new Error('unexpected');
  };
  const controller = new AbortController(); controller.abort();
  await assert.rejects(fetchJson('/api/state', {signal:controller.signal}), (error: unknown) => error instanceof ApiError && error.code === 'CANCELLED');
});

test('invalid JSON has an actionable response error', async () => {
  globalThis.fetch = async () => new Response('<html>broken</html>');
  await assert.rejects(fetchJson('/api/state'), (error: unknown) => error instanceof ApiError && error.code === 'INVALID_RESPONSE');
});

test('reconnect delay is bounded', () => {
  assert.equal(retryDelay(1), 500);
  assert.equal(retryDelay(3), 2000);
  assert.equal(retryDelay(100), 8000);
});
