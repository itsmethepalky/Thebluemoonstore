from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
import httpx

from .supabase import supabase_admin
from .supabase_retry import execute_read_with_retry

bearer_scheme = HTTPBearer(auto_error=False)


def _auth_service_unavailable(exc: Exception):
    print(
        "AUTH SERVICE TEMPORARY ERROR:",
        type(exc).__name__,
        repr(exc),
        flush=True,
    )

    raise HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail="Authentication service temporarily unavailable",
        headers={"Retry-After": "2"},
    )


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(
        bearer_scheme
    ),
):
    if not credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required",
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = credentials.credentials.strip()

    if not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required",
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        claims_response = supabase_admin.auth.get_claims(token)

    except httpx.RequestError as exc:
        _auth_service_unavailable(exc)

    except Exception as exc:
        error_name = type(exc).__name__
        error_text = repr(exc)

        temporary_names = {
            "RemoteProtocolError",
            "ConnectError",
            "ConnectTimeout",
            "ReadTimeout",
            "WriteTimeout",
            "PoolTimeout",
            "TimeoutException",
            "ConnectionTerminated",
        }

        if (
            error_name in temporary_names
            or "RemoteProtocolError" in error_text
            or "ConnectionTerminated" in error_text
            or "ConnectionResetError" in error_text
            or "ConnectError" in error_text
        ):
            _auth_service_unavailable(exc)

        print(
            "AUTH CLAIMS VALIDATION ERROR:",
            error_name,
            error_text,
            flush=True,
        )

        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired authentication token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    if not claims_response:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired authentication token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    claims = claims_response.get("claims")

    if not claims:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired authentication token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    user_id = claims.get("sub")

    if not user_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid authentication claims",
            headers={"WWW-Authenticate": "Bearer"},
        )

    class ClaimsUser:
        def __init__(self, claims):
            self.id = claims.get("sub")
            self.email = claims.get("email")
            self.role = claims.get("role")

    return ClaimsUser(claims)


def get_current_customer(user=Depends(get_current_user)):
    user_id = str(user.id)

    try:
        profile_response = execute_read_with_retry(
            supabase_admin
            .table("profiles")
            .select(
                "id,full_name,email,phone,role,is_active"
            )
            .eq("id", user_id)
            .maybe_single(),
            operation="AUTH CUSTOMER PROFILE",
        )

    except httpx.RequestError as exc:
        print(
            "AUTH PROFILE TEMPORARY ERROR:",
            type(exc).__name__,
            repr(exc),
            flush=True,
        )
        raise HTTPException(
            status_code=503,
            detail="Account service temporarily unavailable",
            headers={"Retry-After": "2"},
        )

    except Exception as exc:
        print(
            "AUTH PROFILE LOAD ERROR:",
            type(exc).__name__,
            repr(exc),
            flush=True,
        )
        raise HTTPException(
            status_code=500,
            detail="Unable to load customer profile",
        )

    profile = profile_response.data

    if not profile:
        raise HTTPException(
            status_code=403,
            detail="Customer profile not found",
        )

    if not profile.get("is_active", False):
        raise HTTPException(
            status_code=403,
            detail="Account is inactive",
        )

    if profile.get("role") != "customer":
        raise HTTPException(
            status_code=403,
            detail="Customer account required",
        )

    try:
        customer_response = execute_read_with_retry(
            supabase_admin
            .table("customers")
            .select(
                "id,user_id,name,phone,email,address,"
                "credit_limit,credit_balance,created_at"
            )
            .eq("user_id", user_id)
            .maybe_single(),
            operation="AUTH CUSTOMER ACCOUNT",
        )

    except httpx.RequestError as exc:
        print(
            "AUTH CUSTOMER TEMPORARY ERROR:",
            type(exc).__name__,
            repr(exc),
            flush=True,
        )
        raise HTTPException(
            status_code=503,
            detail="Account service temporarily unavailable",
            headers={"Retry-After": "2"},
        )

    except Exception as exc:
        print(
            "AUTH CUSTOMER LOAD ERROR:",
            type(exc).__name__,
            repr(exc),
            flush=True,
        )
        raise HTTPException(
            status_code=500,
            detail="Unable to load customer account",
        )

    customer = customer_response.data

    if not customer:
        raise HTTPException(
            status_code=403,
            detail="Customer account not found",
        )

    return {
        "auth_user": user,
        "profile": profile,
        "customer": customer,
    }
