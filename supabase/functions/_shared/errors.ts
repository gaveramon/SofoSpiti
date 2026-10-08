/** Do not retry: the input or configuration is wrong. */
export class PermanentError extends Error {
  constructor(message: string, public code = "permanent") {
    super(message);
    this.name = "PermanentError";
  }
}

/** Retry later: network trouble, provider outage, rate limit. */
export class RetryableError extends Error {
  constructor(message: string, public code = "retryable") {
    super(message);
    this.name = "RetryableError";
  }
}

/** Access token rejected by the provider: refresh once, then retry. */
export class AuthExpiredError extends RetryableError {
  constructor(message = "access token rejected") {
    super(message, "auth_expired");
    this.name = "AuthExpiredError";
  }
}

export function errInfo(e: unknown): { message: string; code: string } {
  if (e instanceof Error) {
    const code = (e as { code?: string }).code ?? e.name;
    return { message: e.message.slice(0, 1000), code };
  }
  return { message: String(e).slice(0, 1000), code: "unknown" };
}

export const isPermanent = (e: unknown) => e instanceof PermanentError;
