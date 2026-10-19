from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field
from typing import Optional

from backend.app.auth import get_current_user
from backend.app.supabase import supabase_admin
from backend.app.supabase_retry import (
    execute_read_with_retry,
    execute_write_safely,
    is_transient_supabase_error,
)


router = APIRouter(prefix="/api/admin", tags=["admin"])


# ---------------------------------------------------------------------------
# ADMIN AUTH
# ---------------------------------------------------------------------------

def get_admin_user(user=Depends(get_current_user)):
    user_id = getattr(user, "id", None)

    if not user_id:
        raise HTTPException(status_code=401, detail="Invalid authentication")

    try:
        result = execute_read_with_retry(
            supabase_admin
            .table("profiles")
            .select("id,full_name,email,role,phone,is_active")
            .eq("id", user_id)
            .maybe_single(),
            operation="ADMIN AUTH PROFILE",
        )
    except HTTPException:
        raise
    except Exception as exc:
        print(
            "ADMIN AUTH PROFILE ERROR:",
            repr(exc),
            flush=True,
        )

        raise HTTPException(
            status_code=500,
            detail="Unable to verify administrator account",
        )

    profile = result.data

    if not profile:
        raise HTTPException(status_code=403, detail="Profile not found")

    if profile.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Admin access required")

    if not profile.get("is_active"):
        raise HTTPException(status_code=403, detail="Account is inactive")

    return profile


# ---------------------------------------------------------------------------
# MODELS
# ---------------------------------------------------------------------------

class OrderStatusUpdate(BaseModel):
    status: str


class PaymentStatusUpdate(BaseModel):
    payment_status: str = Field(
        min_length=1,
        max_length=20,
    )
    amount_paid: Decimal = Field(
        ge=0,
        max_digits=12,
        decimal_places=2,
    )


class ProductCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    sku: str = Field(
        min_length=1,
        max_length=100,
    )
    name: str = Field(
        min_length=1,
        max_length=200,
    )
    description: Optional[str] = Field(
        default=None,
        max_length=2000,
    )
    category_id: Optional[int] = Field(
        default=None,
        gt=0,
    )
    brand_id: Optional[int] = Field(
        default=None,
        gt=0,
    )
    unit_price: float = Field(
        ge=0,
    )
    cost_price: float = Field(
        default=0,
        ge=0,
    )
    stock_quantity: int = Field(
        default=0,
        ge=0,
    )
    reorder_level: int = Field(
        default=0,
        ge=0,
    )
    image_url: Optional[str] = Field(
        default=None,
        max_length=2048,
    )
    is_active: bool = True


class ProductUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    sku: Optional[str] = Field(
        default=None,
        min_length=1,
        max_length=100,
    )
    name: Optional[str] = Field(
        default=None,
        min_length=1,
        max_length=200,
    )
    description: Optional[str] = Field(
        default=None,
        max_length=2000,
    )
    category_id: Optional[int] = Field(
        default=None,
        gt=0,
    )
    brand_id: Optional[int] = Field(
        default=None,
        gt=0,
    )
    unit_price: Optional[float] = Field(
        default=None,
        ge=0,
    )
    cost_price: Optional[float] = Field(
        default=None,
        ge=0,
    )
    reorder_level: Optional[int] = Field(
        default=None,
        ge=0,
    )
    image_url: Optional[str] = Field(
        default=None,
        max_length=2048,
    )
    is_active: Optional[bool] = None


class StockAdjustment(BaseModel):
    model_config = ConfigDict(extra="forbid")

    adjustment: int = Field(
        ne=0,
        ge=-1_000_000,
        le=1_000_000,
    )


# ---------------------------------------------------------------------------
# DASHBOARD
# ---------------------------------------------------------------------------

@router.get("/dashboard")
def dashboard(admin=Depends(get_admin_user)):
    orders = (
        execute_read_with_retry(
            supabase_admin
            .table("orders")
            .select(
                "id,order_no,customer_id,status,total_amount,amount_paid,"
                "payment_method,payment_status,created_at,updated_at"
            )
            .order("created_at", desc=True),
            operation="ADMIN DASHBOARD ORDERS",
        ).data
        or []
    )

    products = (
        execute_read_with_retry(
            supabase_admin
            .table("products")
            .select(
                "id,name,sku,stock_quantity,reorder_level,is_active"
            )
            .eq("is_active", True),
            operation="ADMIN DASHBOARD PRODUCTS",
        ).data
        or []
    )

    customers = (
        execute_read_with_retry(
            supabase_admin
            .table("customers")
            .select("id"),
            operation="ADMIN DASHBOARD CUSTOMERS",
        ).data
        or []
    )

    pending = sum(1 for o in orders if o["status"] == "pending")

    low_stock = [
        p for p in products
        if p["stock_quantity"] <= p["reorder_level"]
    ]

    from datetime import datetime, timezone

    today = datetime.now(timezone.utc).date().isoformat()

    today_orders = [
        o for o in orders
        if o.get("created_at", "").startswith(today)
    ]

    today_sales = sum(
        float(o.get("amount_paid") or 0)
        for o in today_orders
        if o.get("status") != "cancelled"
    )

    total_sales = sum(
        float(o.get("total_amount") or 0)
        for o in orders
        if o.get("status") != "cancelled"
    )

    return {
        "stats": {
            "total_orders": len(orders),
            "pending_orders": pending,
            "today_orders": len(today_orders),
            "today_sales": today_sales,
            "total_sales": total_sales,
            "customers": len(customers),
            "products": len(products),
            "low_stock": len(low_stock),
        },
        "recent_orders": orders[:10],
        "low_stock_products": low_stock[:20],
    }


# ---------------------------------------------------------------------------
# ORDERS
# ---------------------------------------------------------------------------

@router.get("/orders")
def list_orders(
    status: Optional[str] = None,
    payment_status: Optional[str] = None,
    search: Optional[str] = None,
    limit: int = Query(default=100, ge=1, le=500),
    admin=Depends(get_admin_user),
):
    query = (
        supabase_admin
        .table("orders")
        .select(
            "id,order_no,customer_id,status,subtotal,discount,tax,"
            "total_amount,payment_method,payment_status,"
            "shipping_address,phone,notes,created_at,updated_at"
        )
        .order("created_at", desc=True)
        .limit(limit)
    )

    if status:
        query = query.eq("status", status)

    if payment_status:
        query = query.eq("payment_status", payment_status)

    result = query.execute()
    orders = result.data or []

    customer_ids = list({
        o["customer_id"]
        for o in orders
        if o.get("customer_id") is not None
    })

    customers = {}

    if customer_ids:
        customer_rows = (
            supabase_admin
            .table("customers")
            .select("id,user_id,name,phone,email,address")
            .in_("id", customer_ids)
            .execute()
            .data
            or []
        )

        customers = {
            c["id"]: c for c in customer_rows
        }

    for order in orders:
        order["customer"] = customers.get(order["customer_id"])

    if search:
        search_lower = search.lower()

        orders = [
            o for o in orders
            if search_lower in str(o.get("order_no", "")).lower()
            or search_lower in str(
                (o.get("customer") or {}).get("name", "")
            ).lower()
            or search_lower in str(o.get("phone", "")).lower()
        ]

    return orders


@router.get("/orders/{order_id}")
def get_order(
    order_id: int,
    admin=Depends(get_admin_user),
):
    order_result = (
        supabase_admin
        .table("orders")
        .select("*")
        .eq("id", order_id)
        .maybe_single()
        .execute()
    )

    order = order_result.data

    if not order:
        raise HTTPException(status_code=404, detail="Order not found")

    customer = (
        supabase_admin
        .table("customers")
        .select(
            "id,user_id,name,phone,email,address,"
            "credit_limit,credit_balance,created_at"
        )
        .eq("id", order["customer_id"])
        .maybe_single()
        .execute()
        .data
    )

    items = (
        supabase_admin
        .table("order_items")
        .select(
            "id,order_id,product_id,quantity,unit_price,"
            "discount,subtotal,created_at"
        )
        .eq("order_id", order_id)
        .execute()
        .data
        or []
    )

    product_ids = list({
        item["product_id"]
        for item in items
        if item.get("product_id") is not None
    })

    products = {}

    if product_ids:
        rows = (
            supabase_admin
            .table("products")
            .select("id,sku,name,image_url")
            .in_("id", product_ids)
            .execute()
            .data
            or []
        )

        products = {p["id"]: p for p in rows}

    for item in items:
        item["product"] = products.get(item["product_id"])

    return {
        "order": order,
        "customer": customer,
        "items": items,
    }


@router.patch("/orders/{order_id}/status")
def update_order_status(
    order_id: int,
    payload: OrderStatusUpdate,
    admin=Depends(get_admin_user),
):
    new_status = payload.status.strip().lower()

    allowed = {
        "pending",
        "confirmed",
        "processing",
        "shipped",
        "delivered",
        "cancelled",
    }

    if new_status not in allowed:
        raise HTTPException(
            status_code=400,
            detail="Invalid order status",
        )

    # Cancellation has its own transactional RPC because it
    # must restore inventory, reverse outstanding credit,
    # and synchronize the linked POS sale.
    if new_status == "cancelled":
        try:
            result = supabase_admin.rpc(
                "cancel_store_order",
                {"p_order_id": order_id},
            ).execute()
        except Exception as exc:
            print(
                "ADMIN ORDER CANCELLATION ERROR:",
                repr(exc),
                flush=True,
            )

            raise HTTPException(
                status_code=400,
                detail="Could not cancel order.",
            )

        if not result.data:
            raise HTTPException(
                status_code=404,
                detail="Order not found",
            )

        cancelled = result.data[0]

        return {
            "id": cancelled["order_id"],
            "order_no": cancelled["order_no"],
            "status": "cancelled",
            "restored": cancelled["restored"],
        }

    # Normal fulfilment transitions are checked and updated
    # atomically inside PostgreSQL while the order row is locked.
    try:
        result = supabase_admin.rpc(
            "update_store_order_status",
            {
                "p_order_id": order_id,
                "p_new_status": new_status,
            },
        ).execute()
    except Exception as exc:
        message = str(exc).lower()

        print(
            "ADMIN ORDER STATUS UPDATE ERROR:",
            repr(exc),
            flush=True,
        )

        if "order not found" in message:
            raise HTTPException(
                status_code=404,
                detail="Order not found",
            )

        if "terminal state" in message:
            raise HTTPException(
                status_code=400,
                detail="This order can no longer be changed.",
            )

        if "invalid status transition" in message:
            raise HTTPException(
                status_code=400,
                detail="Invalid order status transition.",
            )

        raise HTTPException(
            status_code=400,
            detail="Could not update order status.",
        )

    if not result.data:
        raise HTTPException(
            status_code=404,
            detail="Order not found",
        )

    return result.data[0]


@router.patch("/orders/{order_id}/payment-status")
def update_payment_status(
    order_id: int,
    payload: PaymentStatusUpdate,
    admin=Depends(get_admin_user),
):
    if order_id <= 0:
        raise HTTPException(
            status_code=400,
            detail="Invalid order ID",
        )

    payment_status = payload.payment_status.strip().lower()

    allowed = {
        "paid",
        "partial",
        "unpaid",
    }

    if payment_status not in allowed:
        raise HTTPException(
            status_code=400,
            detail="Invalid payment status",
        )

    # The database RPC is the authoritative payment operation.
    # It locks the order row, validates the amount/status combination,
    # synchronizes customer credit, and updates the linked POS sale
    # in the same transaction.
    #
    # For paid/unpaid, the amount is determined by the database order
    # total rather than trusting a client-supplied amount.
    if payment_status == "paid":
        amount_paid = None
    elif payment_status == "unpaid":
        amount_paid = Decimal("0.00")
    else:
        amount_paid = payload.amount_paid

        if amount_paid <= Decimal("0.00"):
            raise HTTPException(
                status_code=400,
                detail="Partial payment must be greater than 0.",
            )

    try:
        if payment_status == "paid":
            order_result = (
                supabase_admin
                .table("orders")
                .select("total_amount")
                .eq("id", order_id)
                .maybe_single()
                .execute()
            )

            order = order_result.data

            if not order:
                raise HTTPException(
                    status_code=404,
                    detail="Order not found",
                )

            amount_paid = Decimal(
                str(order["total_amount"])
            )

        result = supabase_admin.rpc(
            "update_store_order_payment",
            {
                "p_order_id": order_id,
                "p_payment_status": payment_status,
                "p_amount_paid": float(amount_paid),
            },
        ).execute()

    except HTTPException:
        raise

    except Exception as exc:
        message = str(exc).lower()

        print(
            "ADMIN PAYMENT UPDATE ERROR:",
            repr(exc),
            flush=True,
        )

        if "order not found" in message:
            raise HTTPException(
                status_code=404,
                detail="Order not found",
            )

        if "cancelled orders cannot receive payments" in message:
            raise HTTPException(
                status_code=400,
                detail="Cancelled orders cannot receive payments.",
            )

        if "amount paid cannot exceed order total" in message:
            raise HTTPException(
                status_code=400,
                detail="Amount paid cannot exceed the order total.",
            )

        if "paid status requires" in message:
            raise HTTPException(
                status_code=400,
                detail="Paid status requires the full order amount.",
            )

        if "unpaid status requires" in message:
            raise HTTPException(
                status_code=400,
                detail="Unpaid status requires an amount of 0.",
            )

        if "partial payment must" in message:
            raise HTTPException(
                status_code=400,
                detail="Partial payment must be greater than 0 and less than the order total.",
            )

        if "customer account not found" in message:
            raise HTTPException(
                status_code=400,
                detail="Customer account could not be verified.",
            )

        raise HTTPException(
            status_code=400,
            detail="Could not update payment.",
        )

    if not result.data:
        raise HTTPException(
            status_code=404,
            detail="Order not found",
        )

    return result.data[0]


# ---------------------------------------------------------------------------
# PRODUCTS / INVENTORY
# ---------------------------------------------------------------------------

@router.get("/products")
def admin_products(
    search: Optional[str] = None,
    low_stock: bool = False,
    include_inactive: bool = False,
    admin=Depends(get_admin_user),
):
    query = (
        supabase_admin
        .table("products")
        .select(
            "id,sku,name,description,category_id,brand_id,"
            "unit_price,cost_price,stock_quantity,reorder_level,"
            "is_active,created_at,updated_at,image_url"
        )
        .order("name")
    )

    if not include_inactive:
        query = query.eq("is_active", True)

    result = query.execute()

    products = result.data or []

    if search:
        s = search.lower()
        products = [
            p for p in products
            if s in str(p.get("name", "")).lower()
            or s in str(p.get("sku", "")).lower()
        ]

    if low_stock:
        products = [
            p for p in products
            if p["stock_quantity"] <= p["reorder_level"]
        ]

    return products


@router.post("/products")
def create_product(
    payload: ProductCreate,
    admin=Depends(get_admin_user),
):
    data = payload.model_dump()

    data["sku"] = data["sku"].strip()
    data["name"] = data["name"].strip()

    if data["description"] is not None:
        data["description"] = data["description"].strip() or None

    if not data["sku"]:
        raise HTTPException(
            status_code=400,
            detail="SKU cannot be empty.",
        )

    if not data["name"]:
        raise HTTPException(
            status_code=400,
            detail="Product name cannot be empty.",
        )

    if data["image_url"] is not None:
        image_url = data["image_url"].strip()

        if image_url:
            lowered_url = image_url.lower()

            if lowered_url.startswith(
                ("javascript:", "data:", "vbscript:")
            ):
                raise HTTPException(
                    status_code=400,
                    detail="Invalid image URL.",
                )

            data["image_url"] = image_url
        else:
            data["image_url"] = None

    existing = None

    try:
        existing = (
            supabase_admin
            .table("products")
            .select("id")
            .eq("sku", data["sku"])
            .maybe_single()
            .execute()
            .data
        )
    except Exception as exc:
        print(
            "ADMIN PRODUCT SKU CHECK ERROR:",
            repr(exc),
            flush=True,
        )

        raise HTTPException(
            status_code=500,
            detail="Unable to verify product SKU.",
        )

    if existing:
        raise HTTPException(
            status_code=409,
            detail="SKU already exists",
        )

    try:
        result = (
            supabase_admin
            .table("products")
            .insert(data)
            .execute()
        )
    except Exception as exc:
        message = str(exc).lower()

        print(
            "ADMIN PRODUCT CREATE ERROR:",
            repr(exc),
            flush=True,
        )

        if (
            "duplicate key" in message
            or "products_sku_key" in message
            or "unique constraint" in message
        ):
            raise HTTPException(
                status_code=409,
                detail="SKU already exists",
            )

        if (
            "products_brand_id_fkey" in message
            or "products_category_id_fkey" in message
            or "foreign key" in message
        ):
            raise HTTPException(
                status_code=400,
                detail="Invalid category or brand.",
            )

        raise HTTPException(
            status_code=500,
            detail="Could not create product.",
        )

    if not result.data:
        raise HTTPException(
            status_code=500,
            detail="Could not create product.",
        )

    return result.data[0]


@router.patch("/products/{product_id}")
def update_product(
    product_id: int,
    payload: ProductUpdate,
    admin=Depends(get_admin_user),
):
    if product_id <= 0:
        raise HTTPException(
            status_code=400,
            detail="Invalid product ID.",
        )

    data = payload.model_dump(exclude_unset=True)

    if not data:
        raise HTTPException(
            status_code=400,
            detail="No changes supplied",
        )

    if "sku" in data:
        data["sku"] = data["sku"].strip()

        if not data["sku"]:
            raise HTTPException(
                status_code=400,
                detail="SKU cannot be empty.",
            )

    if "name" in data:
        data["name"] = data["name"].strip()

        if not data["name"]:
            raise HTTPException(
                status_code=400,
                detail="Product name cannot be empty.",
            )

    if "description" in data and data["description"] is not None:
        data["description"] = data["description"].strip() or None

    if "image_url" in data:
        if data["image_url"] is not None:
            image_url = data["image_url"].strip()

            if image_url:
                lowered_url = image_url.lower()

                if lowered_url.startswith(
                    ("javascript:", "data:", "vbscript:")
                ):
                    raise HTTPException(
                        status_code=400,
                        detail="Invalid image URL.",
                    )

                data["image_url"] = image_url
            else:
                data["image_url"] = None

    if "sku" in data:
        try:
            existing = (
                supabase_admin
                .table("products")
                .select("id")
                .eq("sku", data["sku"])
                .neq("id", product_id)
                .maybe_single()
                .execute()
                .data
            )
        except Exception as exc:
            print(
                "ADMIN PRODUCT SKU CHECK ERROR:",
                repr(exc),
                flush=True,
            )

            raise HTTPException(
                status_code=500,
                detail="Unable to verify product SKU.",
            )

        if existing:
            raise HTTPException(
                status_code=409,
                detail="SKU already exists",
            )

    try:
        result = (
            supabase_admin
            .table("products")
            .update(data)
            .eq("id", product_id)
            .execute()
        )
    except Exception as exc:
        message = str(exc).lower()

        print(
            "ADMIN PRODUCT UPDATE ERROR:",
            repr(exc),
            flush=True,
        )

        if (
            "duplicate key" in message
            or "products_sku_key" in message
            or "unique constraint" in message
        ):
            raise HTTPException(
                status_code=409,
                detail="SKU already exists",
            )

        if (
            "products_brand_id_fkey" in message
            or "products_category_id_fkey" in message
            or "foreign key" in message
        ):
            raise HTTPException(
                status_code=400,
                detail="Invalid category or brand.",
            )

        raise HTTPException(
            status_code=500,
            detail="Could not update product.",
        )

    if not result.data:
        raise HTTPException(
            status_code=404,
            detail="Product not found",
        )

    return result.data[0]


# ---------------------------------------------------------------------------
# INVENTORY
# ---------------------------------------------------------------------------

@router.patch("/products/{product_id}/stock")
def adjust_product_stock(
    product_id: int,
    payload: StockAdjustment,
    admin=Depends(get_admin_user),
):
    if product_id <= 0:
        raise HTTPException(
            status_code=400,
            detail="Invalid product ID.",
        )

    try:
        result = supabase_admin.rpc(
            "adjust_store_product_stock",
            {
                "p_product_id": product_id,
                "p_adjustment": payload.adjustment,
            },
        ).execute()

    except Exception as exc:
        message = str(exc).lower()

        print(
            "ADMIN STOCK ADJUSTMENT ERROR:",
            repr(exc),
            flush=True,
        )

        if "product not found" in message:
            raise HTTPException(
                status_code=404,
                detail="Product not found.",
            )

        if "insufficient stock" in message:
            raise HTTPException(
                status_code=409,
                detail="Insufficient stock for this adjustment.",
            )

        if "invalid product" in message:
            raise HTTPException(
                status_code=400,
                detail="Invalid product.",
            )

        if "stock adjustment cannot be zero" in message:
            raise HTTPException(
                status_code=400,
                detail="Stock adjustment cannot be zero.",
            )

        if "stock data is invalid" in message:
            raise HTTPException(
                status_code=409,
                detail="Product stock data is invalid.",
            )

        raise HTTPException(
            status_code=500,
            detail="Could not adjust product stock.",
        )

    if not result.data:
        raise HTTPException(
            status_code=404,
            detail="Product not found.",
        )

    row = result.data[0]

    return {
        "success": True,
        "product_id": row["product_id"],
        "stock_quantity": row["stock_quantity"],
        "adjustment": payload.adjustment,
    }


# ---------------------------------------------------------------------------
# CUSTOMERS
# ---------------------------------------------------------------------------

@router.get("/customers")
def admin_customers(
    search: Optional[str] = None,
    admin=Depends(get_admin_user),
):
    customers = (
        supabase_admin
        .table("customers")
        .select(
            "id,user_id,name,phone,email,address,"
            "credit_limit,credit_balance,created_at"
        )
        .order("created_at", desc=True)
        .execute()
        .data
        or []
    )

    if search:
        s = search.lower()

        customers = [
            c for c in customers
            if s in str(c.get("name", "")).lower()
            or s in str(c.get("email", "")).lower()
            or s in str(c.get("phone", "")).lower()
        ]

    return customers

# ---------------------------------------------------------------------------
# STORE PROMOTIONS / DELIVERY SETTINGS
# ---------------------------------------------------------------------------

class PromotionCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: str = Field(min_length=1, max_length=100)
    name: Optional[str] = Field(default=None, max_length=200)
    description: Optional[str] = Field(default=None, max_length=2000)

    discount_type: str = Field(min_length=1, max_length=20)
    discount_value: float = Field(default=0, ge=0)

    minimum_order_amount: Optional[float] = Field(default=None, ge=0)
    maximum_discount_amount: Optional[float] = Field(default=None, ge=0)

    starts_at: Optional[str] = None
    expires_at: Optional[str] = None

    usage_limit: Optional[int] = Field(default=None, gt=0)
    per_customer_limit: Optional[int] = Field(default=None, gt=0)

    is_active: bool = True


class PromotionUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: Optional[str] = Field(default=None, min_length=1, max_length=100)
    name: Optional[str] = Field(default=None, max_length=200)
    description: Optional[str] = Field(default=None, max_length=2000)

    discount_type: Optional[str] = Field(default=None, min_length=1, max_length=20)
    discount_value: Optional[float] = Field(default=None, ge=0)

    minimum_order_amount: Optional[float] = Field(default=None, ge=0)
    maximum_discount_amount: Optional[float] = Field(default=None, ge=0)

    starts_at: Optional[str] = None
    expires_at: Optional[str] = None

    usage_limit: Optional[int] = Field(default=None, gt=0)
    per_customer_limit: Optional[int] = Field(default=None, gt=0)

    is_active: Optional[bool] = None


class DeliveryChargeUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    delivery_charge: float = Field(ge=0)


def _validate_promotion_data(data):
    discount_type = str(data.get("discount_type", "")).strip().lower()
    discount_value = float(data.get("discount_value", 0) or 0)

    if discount_type not in {
        "percentage",
        "fixed",
        "free_delivery",
    }:
        raise HTTPException(
            status_code=400,
            detail="Invalid discount type.",
        )

    if discount_type == "percentage":
        if discount_value <= 0 or discount_value > 100:
            raise HTTPException(
                status_code=400,
                detail="Percentage discount must be greater than 0 and at most 100.",
            )

    elif discount_type == "fixed":
        if discount_value <= 0:
            raise HTTPException(
                status_code=400,
                detail="Fixed discount must be greater than 0.",
            )

    elif discount_type == "free_delivery":
        if discount_value != 0:
            raise HTTPException(
                status_code=400,
                detail="Free delivery discount value must be 0.",
            )

    minimum_order = data.get("minimum_order_amount")
    maximum_discount = data.get("maximum_discount_amount")

    if (
        minimum_order is not None
        and float(minimum_order) < 0
    ):
        raise HTTPException(
            status_code=400,
            detail="Minimum order amount cannot be negative.",
        )

    if (
        maximum_discount is not None
        and float(maximum_discount) < 0
    ):
        raise HTTPException(
            status_code=400,
            detail="Maximum discount amount cannot be negative.",
        )

    starts_at = data.get("starts_at")
    expires_at = data.get("expires_at")

    if starts_at and expires_at and expires_at <= starts_at:
        raise HTTPException(
            status_code=400,
            detail="Expiry date must be after the start date.",
        )

    data["discount_type"] = discount_type
    data["discount_value"] = discount_value

    return data


@router.get("/promotions")
def admin_promotions(
    include_inactive: bool = True,
    admin=Depends(get_admin_user),
):
    query = (
        supabase_admin
        .table("store_promotions")
        .select(
            "id,code,name,description,discount_type,discount_value,"
            "minimum_order_amount,maximum_discount_amount,starts_at,"
            "expires_at,usage_limit,usage_count,per_customer_limit,"
            "is_active,created_at,updated_at"
        )
        .order("created_at", desc=True)
    )

    if not include_inactive:
        query = query.eq("is_active", True)

    try:
        result = execute_read_with_retry(
            query,
            operation="ADMIN PROMOTIONS LIST",
        )
    except HTTPException:
        raise
    except Exception as exc:
        print(
            "ADMIN PROMOTIONS LIST ERROR:",
            repr(exc),
            flush=True,
        )
        raise HTTPException(
            status_code=500,
            detail="Could not load promotions.",
        )

    return result.data or []


@router.post("/promotions")
def create_promotion(
    payload: PromotionCreate,
    admin=Depends(get_admin_user),
):
    data = payload.model_dump()

    data["code"] = data["code"].strip().upper()

    if not data["code"]:
        raise HTTPException(
            status_code=400,
            detail="Promo code cannot be empty.",
        )

    if data.get("name") is not None:
        data["name"] = data["name"].strip() or None

    if data.get("description") is not None:
        data["description"] = (
            data["description"].strip() or None
        )

    data = _validate_promotion_data(data)

    try:
        result = (
            supabase_admin
            .table("store_promotions")
            .insert(data)
            .execute()
        )
    except Exception as exc:
        message = str(exc).lower()

        print(
            "ADMIN PROMOTION CREATE ERROR:",
            repr(exc),
            flush=True,
        )

        if (
            "duplicate"
            in message
            or "unique"
            in message
            or "store_promotions_code_unique"
            in message
        ):
            raise HTTPException(
                status_code=409,
                detail="A promotion with this code already exists.",
            )

        raise HTTPException(
            status_code=400,
            detail="Could not create promotion.",
        )

    if not result.data:
        raise HTTPException(
            status_code=500,
            detail="Promotion was not created.",
        )

    return result.data[0]


@router.patch("/promotions/{promotion_id}")
def update_promotion(
    promotion_id: int,
    payload: PromotionUpdate,
    admin=Depends(get_admin_user),
):
    if promotion_id <= 0:
        raise HTTPException(
            status_code=400,
            detail="Invalid promotion ID.",
        )

    data = payload.model_dump(exclude_unset=True)

    if not data:
        raise HTTPException(
            status_code=400,
            detail="No promotion changes supplied.",
        )

    if "code" in data and data["code"] is not None:
        data["code"] = data["code"].strip().upper()

        if not data["code"]:
            raise HTTPException(
                status_code=400,
                detail="Promo code cannot be empty.",
            )

    if "name" in data and data["name"] is not None:
        data["name"] = data["name"].strip() or None

    if "description" in data and data["description"] is not None:
        data["description"] = (
            data["description"].strip() or None
        )

    try:
        current_result = (
            supabase_admin
            .table("store_promotions")
            .select(
                "id,code,name,description,discount_type,"
                "discount_value,minimum_order_amount,"
                "maximum_discount_amount,starts_at,expires_at,"
                "usage_limit,usage_count,per_customer_limit,is_active"
            )
            .eq("id", promotion_id)
            .maybe_single()
            .execute()
        )
    except Exception as exc:
        print(
            "ADMIN PROMOTION LOAD ERROR:",
            repr(exc),
            flush=True,
        )
        raise HTTPException(
            status_code=500,
            detail="Could not load promotion.",
        )

    current = current_result.data

    if not current:
        raise HTTPException(
            status_code=404,
            detail="Promotion not found.",
        )

    merged = dict(current)
    merged.update(data)

    merged = _validate_promotion_data(merged)

    # Never allow usage_count to be edited from the admin API.
    data.pop("usage_count", None)

    # Re-validate only fields that are actually being updated.
    validation_data = dict(merged)
    validation_data.pop("id", None)
    validation_data.pop("created_at", None)
    validation_data.pop("updated_at", None)

    _validate_promotion_data(validation_data)

    try:
        result = (
            supabase_admin
            .table("store_promotions")
            .update(data)
            .eq("id", promotion_id)
            .execute()
        )
    except Exception as exc:
        message = str(exc).lower()

        print(
            "ADMIN PROMOTION UPDATE ERROR:",
            repr(exc),
            flush=True,
        )

        if (
            "duplicate"
            in message
            or "unique"
            in message
            or "store_promotions_code_unique"
            in message
        ):
            raise HTTPException(
                status_code=409,
                detail="A promotion with this code already exists.",
            )

        raise HTTPException(
            status_code=400,
            detail="Could not update promotion.",
        )

    if not result.data:
        raise HTTPException(
            status_code=404,
            detail="Promotion not found.",
        )

    return result.data[0]


@router.delete("/promotions/{promotion_id}")
def delete_promotion(
    promotion_id: int,
    admin=Depends(get_admin_user),
):
    if promotion_id <= 0:
        raise HTTPException(
            status_code=400,
            detail="Invalid promotion ID.",
        )

    try:
        current_result = (
            supabase_admin
            .table("store_promotions")
            .select("id,usage_count,is_active")
            .eq("id", promotion_id)
            .maybe_single()
            .execute()
        )
    except Exception as exc:
        print(
            "ADMIN PROMOTION LOAD FOR DELETE ERROR:",
            repr(exc),
            flush=True,
        )
        raise HTTPException(
            status_code=500,
            detail="Could not load promotion.",
        )

    current = current_result.data

    if not current:
        raise HTTPException(
            status_code=404,
            detail="Promotion not found.",
        )

    # A promotion that has already been used may be referenced by
    # historical orders, so deactivate it instead of physically
    # deleting it.
    if int(current.get("usage_count") or 0) > 0:
        try:
            result = (
                supabase_admin
                .table("store_promotions")
                .update({"is_active": False})
                .eq("id", promotion_id)
                .execute()
            )
        except Exception as exc:
            print(
                "ADMIN PROMOTION DEACTIVATE ERROR:",
                repr(exc),
                flush=True,
            )
            raise HTTPException(
                status_code=400,
                detail="Could not deactivate promotion.",
            )

        if not result.data:
            raise HTTPException(
                status_code=404,
                detail="Promotion not found.",
            )

        return {
            "success": True,
            "deleted": False,
            "deactivated": True,
            "promotion": result.data[0],
        }

    try:
        (
            supabase_admin
            .table("store_promotions")
            .delete()
            .eq("id", promotion_id)
            .execute()
        )
    except Exception as exc:
        print(
            "ADMIN PROMOTION DELETE ERROR:",
            repr(exc),
            flush=True,
        )

        raise HTTPException(
            status_code=400,
            detail="Could not delete promotion. Try deactivating it instead.",
        )

    return {
        "success": True,
        "deleted": True,
        "deactivated": False,
        "promotion_id": promotion_id,
    }


@router.get("/store-settings")
def get_store_settings(
    admin=Depends(get_admin_user),
):
    try:
        result = (
            supabase_admin
            .table("store_settings")
            .select("id,delivery_charge,updated_at")
            .eq("id", 1)
            .maybe_single()
            .execute()
        )
    except Exception as exc:
        print(
            "ADMIN STORE SETTINGS LOAD ERROR:",
            repr(exc),
            flush=True,
        )
        raise HTTPException(
            status_code=500,
            detail="Could not load store settings.",
        )

    if not result.data:
        raise HTTPException(
            status_code=404,
            detail="Store settings not found.",
        )

    return result.data


@router.patch("/store-settings/delivery-charge")
def update_delivery_charge(
    payload: DeliveryChargeUpdate,
    admin=Depends(get_admin_user),
):
    try:
        result = (
            supabase_admin
            .table("store_settings")
            .update({
                "delivery_charge": payload.delivery_charge,
            })
            .eq("id", 1)
            .execute()
        )
    except Exception as exc:
        print(
            "ADMIN DELIVERY CHARGE UPDATE ERROR:",
            repr(exc),
            flush=True,
        )
        raise HTTPException(
            status_code=400,
            detail="Could not update delivery charge.",
        )

    if not result.data:
        raise HTTPException(
            status_code=404,
            detail="Store settings not found.",
        )

    return result.data[0]
