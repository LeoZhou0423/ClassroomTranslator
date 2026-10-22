/** Bounded requests. Mutations are never retried automatically. */
export class ApiError extends Error {
  readonly code: string;
  readonly requestId?: string;
  readonly retryable: boolean;

  constructor(message: string, code: string, retryable = false, requestId?: string) {
    super(message);
    this.name = 'ApiError';
    this.code = code;
    this.requestId = requestId;
    this.retryable = retryable;
  }
}

type RequestOptions = RequestInit & { timeoutMs?: number };

async function performRequest<T>(
  path: string,
  options: RequestOptions,
  readBody: (response: Response) => Promise<T>,
): Promise<T> {
  const { timeoutMs = 10_000, signal, ...init } = options;
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener('abort', abort, { once: true });
  if (signal?.aborted) controller.abort();
  const timer = setTimeout(abort, timeoutMs);
  try {
    const response = await fetch(path, { ...init, signal: controller.signal });
    if (!response.ok) {
      const problem = (await response.json().catch(() => ({}))) as {
        error?: unknown;
        code?: unknown;
        retryable?: boolean;
        request_id?: string;
      };
      throw new ApiError(
        typeof problem.error === 'string'
          ? problem.error
          : `请求失败（${response.status}），请重试。`,
        typeof problem.code === 'string' ? problem.code : `HTTP_${response.status}`,
        problem.retryable === true,
        problem.request_id,
      );
    }
    return await readBody(response);
  } catch (error) {
    if (error instanceof ApiError) throw error;
    if (signal?.aborted) throw new ApiError('请求已取消。', 'CANCELLED');
    const mutation = init.method !== undefined && init.method !== 'GET';
    if (controller.signal.aborted) {
      throw new ApiError(
        mutation
          ? '请求超时，操作可能仍在后台进行。请先检查任务状态，再决定是否重试。'
          : '连接超时，正在等待服务恢复。',
        'DEADLINE_EXCEEDED',
        !mutation,
      );
    }
    throw new ApiError('无法连接语音服务，请检查应用是否仍在运行。', 'UNAVAILABLE', !mutation);
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', abort);
  }
}

export function fetchJson<T>(path: string, options: RequestOptions = {}): Promise<T> {
  return performRequest(path, options, async (response) => {
    try {
      return (await response.json()) as T;
    } catch (error) {
      if (error instanceof Error && error.name === 'AbortError') throw error;
      throw new ApiError('服务返回了无法读取的数据，请刷新后重试。', 'INVALID_RESPONSE');
    }
  });
}

export function fetchBlob(path: string, options: RequestOptions = {}): Promise<Blob> {
  return performRequest(path, options, (response) => response.blob());
}

export function retryDelay(failures: number): number {
  return Math.min(8_000, 500 * 2 ** Math.max(0, failures - 1));
}
