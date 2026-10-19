from typing import Optional
import time

import httpx
from fastapi import APIRouter, HTTPException, Query

from ..supabase import supabase_admin

router = APIRouter(prefix="/api", tags=["Catalog"])


# Small, controlled retry for temporary Supabase/PostgREST
# connection problems. Do NOT retry normal database/API errors.
MAX_RETRIES = 3
RETRY_DELAYS = (0.2, 0.5, 1.0)


def is_transient_error(exc: Exception) -> bool:
    error_name = type(exc).__name__
    error_text = repr(exc)

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
        "RemoteProtocolError",
        "ConnectionTerminated",
        "ConnectionResetError",
        "Connection aborted",
        "connection reset",
        "connection closed",
        "server disconnected",
    )

    return any(
        text.lower() in error_text.lower()
        for text in transient_text
    )


def execute_with_retry(query):
    last_error = None

    for attempt in range(MAX_RETRIES):
        try:
            return query.execute()

        except Exception as exc:
            last_error = exc

            if not is_transient_error(exc):
                raise

            print(
                f"SUPABASE TRANSIENT ERROR "
                f"(attempt {attempt + 1}/{MAX_RETRIES}): "
                f"{type(exc).__name__}: {exc}",
                flush=True,
            )

            if attempt < MAX_RETRIES - 1:
                time.sleep(RETRY_DELAYS[attempt])

    print(
        "SUPABASE SERVICE TEMPORARILY UNAVAILABLE:",
        type(last_error).__name__ if last_error else "UnknownError",
        repr(last_error),
        flush=True,
    )

    raise HTTPException(
        status_code=503,
        detail="Store data service temporarily unavailable. Please try again.",
        headers={"Retry-After": "2"},
    )


def clean_product(product: dict) -> dict:
    images = product.get("product_images") or []

    images.sort(
        key=lambda image: (
            not image.get("is_primary", False),
            image.get("sort_order", 0),
            image.get("id", 0),
        )
    )

    return {
        "id": product.get("id"),
        "sku": product.get("sku"),
        "name": product.get("name"),
        "description": product.get("description"),
        "category_id": product.get("category_id"),
        "brand_id": product.get("brand_id"),
        "unit_price": product.get("unit_price"),
        "stock_quantity": product.get("stock_quantity"),
        "is_active": product.get("is_active"),
        "images": [
            {
                "id": image.get("id"),
                "image_url": image.get("image_url"),
                "is_primary": image.get("is_primary", False),
                "sort_order": image.get("sort_order", 0),
            }
            for image in images
        ],
    }


@router.get("/categories")
def list_categories():
    query = (
        supabase_admin
        .table("categories")
        .select("id,name,description")
        .eq("is_active", True)
        .order("name")
    )

    response = execute_with_retry(query)

    return response.data or []


@router.get("/brands")
def list_brands():
    query = (
        supabase_admin
        .table("brands")
        .select("id,name")
        .eq("is_active", True)
        .order("name")
    )

    response = execute_with_retry(query)

    return response.data or []


@router.get("/products")
def list_products(
    search: Optional[str] = Query(default=None, max_length=100),
    category_id: Optional[int] = None,
    brand_id: Optional[int] = None,
    in_stock: bool = False,
):
    query = (
        supabase_admin
        .table("products")
        .select(
            """
            id,
            sku,
            name,
            description,
            category_id,
            brand_id,
            unit_price,
            stock_quantity,
            is_active,
            product_images(
                id,
                image_url,
                is_primary,
                sort_order
            )
            """
        )
        .eq("is_active", True)
    )

    if search and search.strip():
        text = search.strip()
        query = query.or_(
            f"name.ilike.%{text}%,sku.ilike.%{text}%"
        )

    if category_id is not None:
        query = query.eq("category_id", category_id)

    if brand_id is not None:
        query = query.eq("brand_id", brand_id)

    if in_stock:
        query = query.gt("stock_quantity", 0)

    query = query.order("name")

    response = execute_with_retry(query)

    return [
        clean_product(product)
        for product in (response.data or [])
    ]


@router.get("/products/{product_id}")
def get_product(product_id: int):
    query = (
        supabase_admin
        .table("products")
        .select(
            """
            id,
            sku,
            name,
            description,
            category_id,
            brand_id,
            unit_price,
            stock_quantity,
            is_active,
            product_images(
                id,
                image_url,
                is_primary,
                sort_order
            )
            """
        )
        .eq("id", product_id)
        .eq("is_active", True)
        .maybe_single()
    )

    response = execute_with_retry(query)

    if not response.data:
        raise HTTPException(
            status_code=404,
            detail="Product not found",
        )

    return clean_product(response.data)
