import time

import httpx
from fastapi import HTTPException


READ_MAX_RETRIES = 3
READ_RETRY_DELAYS = (0.2, 0.5, 1.0)


def is_transient_supabase_error(exc: Exception) -> bool:
    error_name = type(exc).__name__
    error_text = repr(exc).lower()

    transient_names = {
        "RemoteProtocolError",
        "ConnectError",
        "ConnectTimeout",
        "ReadTimeout",
        "WriteTimeout",
        "PoolTimeout",
        "TimeoutException",
        "ConnectionTerminated",
    }

    if isinstance(exc, httpx.RequestError):
        return True

    if error_name in transient_names:
        return True

    transient_text = (
        "remoteprotocolerror",
        "connectionterminated",
        "connectionreseterror",
        "connection aborted",
        "connection reset",
        "connection closed",
        "server disconnected",
        "http2",
    )

    return any(
        text in error_text
        for text in transient_text
    )


def execute_read_with_retry(query, operation="Supabase read"):
    last_error = None

    for attempt in range(READ_MAX_RETRIES):
        try:
            return query.execute()

        except Exception as exc:
            last_error = exc

            if not is_transient_supabase_error(exc):
                raise

            print(
                f"{operation} transient error "
                f"(attempt {attempt + 1}/{READ_MAX_RETRIES}): "
                f"{type(exc).__name__}: {exc}",
                flush=True,
            )

            if attempt < READ_MAX_RETRIES - 1:
                time.sleep(READ_RETRY_DELAYS[attempt])

    print(
        f"{operation} temporarily unavailable after "
        f"{READ_MAX_RETRIES} attempts: "
        f"{type(last_error).__name__ if last_error else 'UnknownError'}: "
        f"{repr(last_error)}",
        flush=True,
    )

    raise HTTPException(
        status_code=503,
        detail="Store data service temporarily unavailable. Please try again.",
        headers={"Retry-After": "2"},
    )


def execute_write_safely(query, operation="Supabase write"):
    try:
        return query.execute()

    except Exception as exc:
        if is_transient_supabase_error(exc):
            print(
                f"{operation} transport error: "
                f"{type(exc).__name__}: {exc}",
                flush=True,
            )

            raise HTTPException(
                status_code=503,
                detail="Store service temporarily unavailable. Please try again.",
                headers={"Retry-After": "2"},
            )

        raise
