import base64
import hashlib
import hmac
import json
import os
import secrets
import threading
import time
import urllib.parse
import urllib.request
from decimal import Decimal, InvalidOperation
from typing import Literal

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from ..auth import get_current_customer
from ..config import settings
from ..supabase import supabase_admin


router = APIRouter(
    prefix="/api/checkout",
    tags=["Checkout"],
)


ESEWA_PRODUCT_CODE = os.getenv(
    "ESEWA_PRODUCT_CODE",
    "EPAYTEST",
)

ESEWA_SECRET_KEY = os.getenv(
    "ESEWA_SECRET_KEY",
    "",
)

ESEWA_FORM_URL = os.getenv(
    "ESEWA_FORM_URL",
    "https://rc-epay.esewa.com.np/api/epay/main/v2/form",
)

ESEWA_STATUS_URL = os.getenv(
    "ESEWA_STATUS_URL",
    "https://uat.esewa.com.np/api/epay/transaction/status/",
)

STORE_PUBLIC_URL = os.getenv(
    "STORE_PUBLIC_URL",
    "http://127.0.0.1:8001",
).rstrip("/")
NOMINATIM_MIN_INTERVAL_SECONDS = 1.0
_nominatim_lock = threading.Lock()
_last_nominatim_request = 0.0


class CheckoutItem(BaseModel):
    product_id: int = Field(gt=0)
    quantity: int = Field(gt=0)


class CheckoutRequest(BaseModel):
    phone: str = Field(min_length=7, max_length=30)
    shipping_address: str = Field(min_length=5, max_length=500)
    delivery_latitude: float = Field(ge=-90, le=90)
    delivery_longitude: float = Field(ge=-180, le=180)

    # The Store exposes only:
    #   cod = Cash on Delivery
    #   esewa = eSewa
    #
    # eSewa is stored internally as the existing "mobile" enum value
    # because the POS shares the same payment_method enum.
    payment_method: Literal["cod", "esewa"]

    notes: str | None = Field(default=None, max_length=1000)

    # Customers may submit only a promo code.
    # Discount, delivery charge, and final total are always
    # calculated and verified server-side.
    promo_code: str | None = Field(
        default=None,
        max_length=100,
    )

    items: list[CheckoutItem] = Field(
        min_length=1,
        max_length=100,
    )


def _store_origin() -> tuple[float, float]:
    try:
        origin_latitude = float(settings.STORE_ORIGIN_LATITUDE)
        origin_longitude = float(settings.STORE_ORIGIN_LONGITUDE)
    except (TypeError, ValueError) as exc:
        raise HTTPException(
            status_code=503,
            detail="Delivery route service is not configured.",
        ) from exc

    if (
        not -90 <= origin_latitude <= 90
        or not -180 <= origin_longitude <= 180
    ):
        raise HTTPException(
            status_code=503,
            detail="Delivery route service is not configured.",
        )

    return origin_latitude, origin_longitude


def _nominatim_request(path: str, params: dict) -> httpx.Response:
    global _last_nominatim_request

    with _nominatim_lock:
        elapsed = time.monotonic() - _last_nominatim_request
        if elapsed < NOMINATIM_MIN_INTERVAL_SECONDS:
            time.sleep(NOMINATIM_MIN_INTERVAL_SECONDS - elapsed)

        headers = {
            "User-Agent": (
                "TheBlueMoonStore/1.0 "
                "(https://thebluemoonstore.onrender.com"
                + (
                    f"; contact: {settings.STORE_CONTACT_EMAIL}"
                    if settings.STORE_CONTACT_EMAIL
                    else ""
                )
                + ")"
            ),
            "Accept": "application/json",
        }
        try:
            response = httpx.get(
                f"{settings.OSM_NOMINATIM_URL}{path}",
                params=params,
                headers=headers,
                timeout=6.0,
            )
        except httpx.RequestError as exc:
            raise HTTPException(
                status_code=503,
                detail="Address search is temporarily unavailable.",
            ) from exc
        finally:
            _last_nominatim_request = time.monotonic()

    if response.is_error:
        raise HTTPException(
            status_code=503,
            detail="Address search is temporarily unavailable.",
        )
    return response


def _calculate_delivery_distance_km(
    latitude: float,
    longitude: float,
) -> Decimal:
    origin_latitude, origin_longitude = _store_origin()

    try:
        response = httpx.get(
            (
                f"{settings.OSM_ROUTING_URL}/route/v1/driving/"
                f"{origin_longitude},{origin_latitude};"
                f"{longitude},{latitude}"
            ),
            params={
                "alternatives": "true",
                "overview": "false",
                "steps": "false",
            },
            timeout=8.0,
        )
    except httpx.RequestError as exc:
        print(
            "OSM ROUTE REQUEST ERROR:",
            type(exc).__name__,
            flush=True,
        )
        raise HTTPException(
            status_code=503,
            detail="Unable to calculate the delivery route. Please try again.",
        ) from exc

    if response.is_error:
        print(
            "OSM ROUTE SERVICE ERROR:",
            response.status_code,
            flush=True,
        )
        raise HTTPException(
            status_code=503,
            detail="Unable to calculate the delivery route. Please try again.",
        )

    try:
        routes = response.json().get("routes") or []
        route_distances = [
            Decimal(str(route["distance"]))
            for route in routes
        ]
    except (
        AttributeError,
        IndexError,
        KeyError,
        InvalidOperation,
        TypeError,
        ValueError,
    ) as exc:
        raise HTTPException(
            status_code=422,
            detail="No driving route is available for this address.",
        ) from exc

    if not route_distances or any(
        not distance.is_finite() or distance < 0
        for distance in route_distances
    ):
        raise HTTPException(
            status_code=422,
            detail="No driving route is available for this address.",
        )

    distance_meters = min(route_distances)
    return distance_meters / Decimal("1000")


def _delivery_rpc_arguments(
    payload: CheckoutRequest,
) -> dict:
    distance_km = _calculate_delivery_distance_km(
        payload.delivery_latitude,
        payload.delivery_longitude,
    )
    return {
        "p_delivery_distance_km": str(distance_km),
        "distance_km": distance_km,
    }


def _checkout_migration_missing(exc: Exception) -> str | None:
    error_text = str(exc).lower()
    if "pgrst202" not in error_text:
        return None
    if "create_store_order_with_delivery_location" in error_text:
        return (
            "Delivery location storage is not installed. "
            "Apply database migration 015 in Supabase."
        )
    if (
        "preview_store_checkout_with_delivery" in error_text
        or "create_store_order_with_delivery" in error_text
    ):
        return (
            "Route-based delivery pricing is not installed. "
            "Apply database migration 014 in Supabase."
        )
    return None


def _signature(message: str) -> str:
    if not ESEWA_SECRET_KEY:
        raise RuntimeError("ESEWA_SECRET_KEY is not configured")

    digest = hmac.new(
        ESEWA_SECRET_KEY.encode("utf-8"),
        message.encode("utf-8"),
        hashlib.sha256,
    ).digest()

    return base64.b64encode(digest).decode("utf-8")


def _create_esewa_signature(
    total_amount: str,
    transaction_uuid: str,
) -> str:
    message = (
        f"total_amount={total_amount},"
        f"transaction_uuid={transaction_uuid},"
        f"product_code={ESEWA_PRODUCT_CODE}"
    )

    return _signature(message)


def _verify_esewa_response(data: dict) -> bool:
    signed_fields = data.get("signed_field_names")

    if not signed_fields:
        return False

    signature = data.get("signature")

    if not signature:
        return False

    parts = []

    for field_name in signed_fields.split(","):
        if field_name not in data:
            return False

        parts.append(
            f"{field_name}={data[field_name]}"
        )

    message = ",".join(parts)

    expected = _signature(message)

    return hmac.compare_digest(
        expected,
        signature,
    )


def _decode_esewa_response(encoded: str) -> dict:
    try:
        decoded = base64.b64decode(
            encoded,
            validate=True,
        ).decode("utf-8")

        data = json.loads(decoded)

    except Exception as exc:
        raise HTTPException(
            status_code=400,
            detail="Invalid eSewa payment response.",
        ) from exc

    if not isinstance(data, dict):
        raise HTTPException(
            status_code=400,
            detail="Invalid eSewa payment response.",
        )

    return data


def _extract_order_id(transaction_uuid: str) -> int:
    # Format:
    # bm-{order_id}-{random}
    parts = transaction_uuid.split("-")

    if len(parts) != 3 or parts[0] != "bm":
        raise HTTPException(
            status_code=400,
            detail="Invalid eSewa transaction.",
        )

    try:
        order_id = int(parts[1])
    except ValueError as exc:
        raise HTTPException(
            status_code=400,
            detail="Invalid eSewa transaction.",
        ) from exc

    if order_id <= 0:
        raise HTTPException(
            status_code=400,
            detail="Invalid eSewa transaction.",
        )

    return order_id


def _check_esewa_status(
    total_amount: str,
    transaction_uuid: str,
) -> dict:
    params = urllib.parse.urlencode(
        {
            "product_code": ESEWA_PRODUCT_CODE,
            "total_amount": total_amount,
            "transaction_uuid": transaction_uuid,
        }
    )

    url = f"{ESEWA_STATUS_URL}?{params}"

    request = urllib.request.Request(
        url,
        method="GET",
        headers={
            "Accept": "application/json",
            "User-Agent": "The-Blue-Moon-Store/1.0",
        },
    )

    try:
        with urllib.request.urlopen(
            request,
            timeout=15,
        ) as response:
            raw = response.read().decode(
                "utf-8",
                errors="replace",
            )

    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail="Unable to verify the eSewa transaction.",
        ) from exc

    try:
        result = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=502,
            detail="Invalid response from eSewa.",
        ) from exc

    return result


def _load_order(order_id: int):
    try:
        response = (
            supabase_admin
            .table("orders")
            .select(
                "id,order_no,total_amount,payment_method,"
                "payment_status,status"
            )
            .eq("id", order_id)
            .maybe_single()
            .execute()
        )
    except Exception as exc:
        print(
            "ESEWA ORDER LOAD ERROR:",
            repr(exc),
            flush=True,
        )

        raise HTTPException(
            status_code=500,
            detail="Unable to load the order.",
        )

    if not response.data:
        raise HTTPException(
            status_code=404,
            detail="Order not found.",
        )

    return response.data


def _mark_order_paid(
    order_id: int,
    amount: Decimal,
):
    try:
        response = supabase_admin.rpc(
            "update_store_order_payment",
            {
                "p_order_id": order_id,
                "p_payment_status": "paid",
                "p_amount_paid": float(amount),
            },
        ).execute()

    except Exception as exc:
        print(
            "ESEWA PAYMENT UPDATE ERROR:",
            repr(exc),
            flush=True,
        )

        raise HTTPException(
            status_code=500,
            detail="Payment was verified but the order could not be updated.",
        )

    return response


@router.get("/address-search")
def address_search(
    q: str = Query(min_length=3, max_length=120),
    current=Depends(get_current_customer),
):
    response = _nominatim_request(
        "/search",
        {
            "q": q.strip(),
            "format": "jsonv2",
            "addressdetails": 1,
            "limit": 5,
            "countrycodes": "np",
            **(
                {"email": settings.STORE_CONTACT_EMAIL}
                if settings.STORE_CONTACT_EMAIL
                else {}
            ),
        },
    )
    try:
        results = response.json()
        return [
            {
                "display_name": item["display_name"],
                "latitude": float(item["lat"]),
                "longitude": float(item["lon"]),
            }
            for item in results
            if item.get("display_name")
        ]
    except (AttributeError, KeyError, TypeError, ValueError) as exc:
        raise HTTPException(
            status_code=502,
            detail="Address search returned an invalid response.",
        ) from exc


@router.get("/address-reverse")
def reverse_delivery_address(
    latitude: float = Query(ge=-90, le=90),
    longitude: float = Query(ge=-180, le=180),
    current=Depends(get_current_customer),
):
    response = _nominatim_request(
        "/reverse",
        {
            "lat": latitude,
            "lon": longitude,
            "format": "jsonv2",
            "zoom": 18,
            **(
                {"email": settings.STORE_CONTACT_EMAIL}
                if settings.STORE_CONTACT_EMAIL
                else {}
            ),
        },
    )
    try:
        result = response.json()
        address = result.get("display_name")
    except (AttributeError, TypeError, ValueError) as exc:
        raise HTTPException(
            status_code=502,
            detail="Address lookup returned an invalid response.",
        ) from exc

    if not address:
        raise HTTPException(
            status_code=404,
            detail="No address found at that map location.",
        )
    return {"display_name": address}



@router.post("/preview")
def preview_checkout(
    payload: CheckoutRequest,
    current=Depends(get_current_customer),
):
    """
    Preview checkout pricing without creating an order.

    The database function is authoritative for:
    - product prices
    - stock availability
    - delivery charge
    - promotion validation
    - product discount
    - free delivery
    - final total

    This endpoint performs no checkout side effects.
    """
    customer = current["customer"]

    items = [
        {
            "product_id": item.product_id,
            "quantity": item.quantity,
        }
        for item in payload.items
    ]

    # The Store exposes:
    #   cod   -> database "cod"
    #   esewa -> database "mobile"
    database_payment_method = (
        "mobile"
        if payload.payment_method == "esewa"
        else "cod"
    )
    delivery = _delivery_rpc_arguments(payload)

    try:
        response = supabase_admin.rpc(
            "preview_store_checkout_with_delivery",
            {
                "p_customer_id": customer["id"],
                "p_phone": payload.phone.strip(),
                "p_shipping_address": payload.shipping_address.strip(),
                "p_payment_method": database_payment_method,
                "p_items": items,
                "p_promo_code": (
                    payload.promo_code.strip()
                    if payload.promo_code
                    else None
                ),
                "p_delivery_distance_km": delivery[
                    "p_delivery_distance_km"
                ],
            },
        ).execute()

    except Exception as exc:
        error_text = str(exc).lower()

        print(
            "CHECKOUT PREVIEW ERROR:",
            repr(exc),
            flush=True,
        )

        migration_detail = _checkout_migration_missing(exc)
        if migration_detail:
            raise HTTPException(
                status_code=503,
                detail=migration_detail,
            ) from exc

        # These messages are generated by the authoritative
        # preview_store_checkout PostgreSQL function.
        if "invalid promo code" in error_text:
            raise HTTPException(
                status_code=400,
                detail="Invalid promo code.",
            ) from exc

        if "promo code is inactive" in error_text:
            raise HTTPException(
                status_code=400,
                detail="Promo code is inactive.",
            ) from exc

        if "promo code is not active yet" in error_text:
            raise HTTPException(
                status_code=400,
                detail="Promo code is not active yet.",
            ) from exc

        if "promo code has expired" in error_text:
            raise HTTPException(
                status_code=400,
                detail="Promo code has expired.",
            ) from exc

        if "promo code usage limit reached" in error_text:
            raise HTTPException(
                status_code=409,
                detail="Promo code usage limit reached.",
            ) from exc

        if "promo code customer usage limit reached" in error_text:
            raise HTTPException(
                status_code=409,
                detail="You have reached the usage limit for this promo.",
            ) from exc

        if "minimum order amount for this promo is" in error_text:
            raise HTTPException(
                status_code=400,
                detail=str(exc),
            ) from exc

        if "customer account not found" in error_text:
            raise HTTPException(
                status_code=401,
                detail="Customer account not found.",
            ) from exc

        if "insufficient stock for product" in error_text:
            raise HTTPException(
                status_code=409,
                detail=str(exc),
            ) from exc

        if "product" in error_text and "no longer available" in error_text:
            raise HTTPException(
                status_code=409,
                detail=str(exc),
            ) from exc

        if "credit limit exceeded" in error_text:
            raise HTTPException(
                status_code=409,
                detail="Customer credit limit exceeded.",
            ) from exc

        if "customer credit is not available" in error_text:
            raise HTTPException(
                status_code=400,
                detail="Customer credit is not available.",
            ) from exc

        if "store delivery charge is invalid" in error_text:
            raise HTTPException(
                status_code=503,
                detail="Store delivery charge is temporarily unavailable.",
            ) from exc

        raise HTTPException(
            status_code=500,
            detail="Unable to calculate checkout pricing.",
        ) from exc

    if not response.data:
        raise HTTPException(
            status_code=500,
            detail="Checkout pricing preview returned no data.",
        )

    result = response.data[0]

    return {
        "subtotal": result.get("subtotal", 0),
        "discount": result.get("discount", 0),
        "original_delivery_charge": result.get(
            "original_delivery_charge",
            result.get("delivery_charge", 0),
        ),
        "delivery_discount": result.get(
            "delivery_discount",
            0,
        ),
        "delivery_charge": result.get(
            "delivery_charge",
            0,
        ),
        "promo_code": result.get("promo_code"),
        "total_amount": result.get("total_amount", 0),
        "delivery_distance_km": str(delivery["distance_km"]),
    }


@router.post("/create")
def create_checkout_order(
    payload: CheckoutRequest,
    current=Depends(get_current_customer),
):
    customer = current["customer"]

    items = [
        {
            "product_id": item.product_id,
            "quantity": item.quantity,
        }
        for item in payload.items
    ]

    # IMPORTANT:
    # The shared POS enum does not contain "esewa".
    # Therefore Store eSewa orders use the existing "mobile"
    # database value internally. The customer never sees "mobile".
    database_payment_method = (
        "mobile"
        if payload.payment_method == "esewa"
        else "cod"
    )
    delivery = _delivery_rpc_arguments(payload)

    try:
        response = supabase_admin.rpc(
            "create_store_order_with_delivery_location",
            {
                "p_customer_id": customer["id"],
                "p_phone": payload.phone.strip(),
                "p_shipping_address": payload.shipping_address.strip(),
                "p_payment_method": database_payment_method,
                "p_notes": (
                    payload.notes.strip()
                    if payload.notes
                    else None
                ),
                "p_items": items,
                "p_promo_code": (
                    payload.promo_code.strip()
                    if payload.promo_code
                    else None
                ),
                "p_delivery_distance_km": delivery[
                    "p_delivery_distance_km"
                ],
                "p_delivery_latitude":
                    payload.delivery_latitude,
                "p_delivery_longitude":
                    payload.delivery_longitude,
            },
        ).execute()

    except Exception as exc:
        print("CHECKOUT RPC ERROR:", repr(exc), flush=True)
        message = str(exc)
        migration_detail = _checkout_migration_missing(exc)

        if migration_detail:
            detail = migration_detail
            status_code = 503

        elif "Insufficient stock" in message:
            detail = (
                "One or more products do not have enough stock."
            )
            status_code = 409

        elif "no longer available" in message:
            detail = (
                "One or more products are no longer available."
            )
            status_code = 409

        elif "Cart is empty" in message:
            detail = "Your cart is empty."
            status_code = 400

        elif "Customer account" in message:
            detail = (
                "Customer account could not be verified."
            )
            status_code = 403

        elif "Invalid promo code" in message:
            detail = "The promo code is invalid."
            status_code = 400

        elif "Promo code is inactive" in message:
            detail = "This promo code is currently inactive."
            status_code = 400

        elif "Promo code has expired" in message:
            detail = "This promo code has expired."
            status_code = 400

        elif "Promo code has not started" in message:
            detail = "This promo code is not active yet."
            status_code = 400

        elif "Promo code usage limit reached" in message:
            detail = "This promo code has reached its usage limit."
            status_code = 409

        elif "Promo code customer usage limit reached" in message:
            detail = (
                "You have already used this promo code the maximum "
                "number of times."
            )
            status_code = 409

        elif "Minimum order amount" in message:
            detail = message
            status_code = 400

        else:
            detail = "Unable to create the order."
            status_code = 500

        raise HTTPException(
            status_code=status_code,
            detail=detail,
        )

    if not response.data:
        raise HTTPException(
            status_code=500,
            detail="Order was not created.",
        )

    result = response.data[0]

    order_id = int(result["order_id"])
    total_amount = Decimal(
        str(result["total_amount"])
    )

    if payload.payment_method == "cod":
        return {
            "success": True,
            "payment_required": False,
            "order": {
                "id": order_id,
                "order_no": result["order_no"],
                "subtotal": result["subtotal"],
                "discount": result["discount"],
                "delivery_charge": result["delivery_charge"],
                "promo_code": result.get("promo_code"),
                "delivery_distance_km": str(delivery["distance_km"]),
                "total_amount": result["total_amount"],
            },
        }

    if total_amount <= 0:
        raise HTTPException(
            status_code=400,
            detail="Invalid order amount.",
        )

    if not ESEWA_SECRET_KEY:
        raise HTTPException(
            status_code=500,
            detail="eSewa payment is not configured.",
        )

    # eSewa allows alphanumeric characters and hyphens.
    transaction_uuid = (
        f"bm-{order_id}-{secrets.token_hex(8)}"
    )

    total_string = format(
        total_amount,
        "f",
    )

    signature = _create_esewa_signature(
        total_string,
        transaction_uuid,
    )

    success_url = (
        f"{STORE_PUBLIC_URL}/api/checkout/esewa/success"
    )

    failure_url = (
        f"{STORE_PUBLIC_URL}/api/checkout/esewa/failure"
    )

    return {
        "success": True,
        "payment_required": True,
        "payment_gateway": "esewa",
        "order": {
            "id": order_id,
            "order_no": result["order_no"],
            "subtotal": result["subtotal"],
            "discount": result["discount"],
            "delivery_charge": result["delivery_charge"],
            "promo_code": result.get("promo_code"),
            "delivery_distance_km": str(delivery["distance_km"]),
            "total_amount": result["total_amount"],
        },
        "esewa": {
            "form_url": ESEWA_FORM_URL,
            "amount": total_string,
            "tax_amount": "0",
            "total_amount": total_string,
            "transaction_uuid": transaction_uuid,
            "product_code": ESEWA_PRODUCT_CODE,
            "product_service_charge": "0",
            "product_delivery_charge": "0",
            "success_url": success_url,
            "failure_url": failure_url,
            "signed_field_names": (
                "total_amount,transaction_uuid,product_code"
            ),
            "signature": signature,
        },
    }


@router.get(
    "/esewa/success",
    response_class=HTMLResponse,
)
def esewa_success(
    encoded_data: str | None = None,
    data: str | None = None,
    response: str | None = None,
):
    encoded = (
        encoded_data
        or data
        or response
    )

    if not encoded:
        return HTMLResponse(
            _result_page(
                False,
                "eSewa did not return a payment response.",
            ),
            status_code=400,
        )

    payment = _decode_esewa_response(encoded)

    if not _verify_esewa_response(payment):
        return HTMLResponse(
            _result_page(
                False,
                "The eSewa payment response could not be verified.",
            ),
            status_code=400,
        )

    if payment.get("status") != "COMPLETE":
        return HTMLResponse(
            _result_page(
                False,
                "The eSewa payment was not completed.",
            ),
            status_code=400,
        )

    if payment.get("product_code") != ESEWA_PRODUCT_CODE:
        return HTMLResponse(
            _result_page(
                False,
                "Invalid eSewa merchant code.",
            ),
            status_code=400,
        )

    transaction_uuid = str(
        payment.get("transaction_uuid", "")
    )

    order_id = _extract_order_id(
        transaction_uuid
    )

    try:
        returned_amount = Decimal(
            str(payment["total_amount"])
        )
    except (
        KeyError,
        InvalidOperation,
        TypeError,
    ) as exc:
        raise HTTPException(
            status_code=400,
            detail="Invalid eSewa payment amount.",
        ) from exc

    order = _load_order(order_id)

    try:
        order_total = Decimal(
            str(order["total_amount"])
        )
    except (
        InvalidOperation,
        TypeError,
    ) as exc:
        raise HTTPException(
            status_code=500,
            detail="Invalid order amount.",
        ) from exc

    if returned_amount != order_total:
        return HTMLResponse(
            _result_page(
                False,
                "The eSewa payment amount does not match the order.",
            ),
            status_code=400,
        )

    # Verify directly with eSewa as recommended.
    status = _check_esewa_status(
        format(order_total, "f"),
        transaction_uuid,
    )

    if str(status.get("status", "")).upper() != "COMPLETE":
        return HTMLResponse(
            _result_page(
                False,
                "eSewa has not confirmed this payment.",
            ),
            status_code=400,
        )

    try:
        verified_amount = Decimal(
            str(
                status.get(
                    "total_amount",
                    status.get("totalAmount"),
                )
            )
        )
    except (
        InvalidOperation,
        TypeError,
    ) as exc:
        raise HTTPException(
            status_code=502,
            detail="Invalid amount returned by eSewa.",
        ) from exc

    if verified_amount != order_total:
        return HTMLResponse(
            _result_page(
                False,
                "The verified eSewa amount does not match the order.",
            ),
            status_code=400,
        )

    if order.get("payment_status") != "paid":
        _mark_order_paid(
            order_id,
            order_total,
        )

    return HTMLResponse(
        _result_page(
            True,
            "Payment successful.",
            order_no=order["order_no"],
        )
    )


@router.get(
    "/esewa/failure",
    response_class=HTMLResponse,
)
def esewa_failure():
    return HTMLResponse(
        _result_page(
            False,
            "The eSewa payment was cancelled or could not be completed.",
        )
    )


def _result_page(
    success: bool,
    message: str,
    order_no: str | None = None,
) -> str:
    title = (
        "Payment Successful"
        if success
        else "Payment Not Completed"
    )

    color = (
        "#237a57"
        if success
        else "#a33b32"
    )

    order_text = ""

    if order_no:
        order_text = (
            f"<p><strong>Order:</strong> "
            f"{order_no}</p>"
        )

    return f"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport"
      content="width=device-width,initial-scale=1">
<title>{title} — The Blue Moon</title>
<style>
body {{
    margin: 0;
    min-height: 100vh;
    display: grid;
    place-items: center;
    background: #f5f1e8;
    font-family: system-ui, sans-serif;
    color: #172033;
}}
.card {{
    width: min(92vw, 520px);
    box-sizing: border-box;
    padding: 36px;
    background: white;
    border-radius: 18px;
    text-align: center;
    box-shadow: 0 12px 40px rgba(0,0,0,.10);
}}
.icon {{
    font-size: 48px;
    color: {color};
}}
h1 {{
    margin: 12px 0;
}}
p {{
    line-height: 1.6;
}}
a {{
    display: inline-block;
    margin-top: 18px;
    padding: 12px 20px;
    border-radius: 10px;
    background: #172033;
    color: white;
    text-decoration: none;
}}
</style>
</head>
<body>
<div class="card">
    <div class="icon">
        {"✓" if success else "!"}
    </div>
    <h1>{title}</h1>
    <p>{message}</p>
    {order_text}
    <a href="/orders">View My Orders</a>
</div>
</body>
</html>
"""
