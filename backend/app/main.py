from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .auth import get_current_customer, get_current_user
from .routers import admin, catalog, checkout
from .supabase import supabase_admin
from .supabase_retry import execute_read_with_retry


BASE_DIR = Path(__file__).resolve().parents[2]
FRONTEND_DIR = BASE_DIR / "frontend"


app = FastAPI(
    title="The Blue Moon Store API",
    version="1.0.0",
)


app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://thebluemoonstore.onrender.com",
        "http://127.0.0.1:8001",
        "http://localhost:8001",
    ],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Accept", "Cache-Control"],
)


@app.middleware("http")
async def security_headers(request, call_next):
    response = await call_next(request)

    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["Permissions-Policy"] = (
        "camera=(), microphone=(), geolocation=(), "
        "payment=(), usb=()"
    )

    if request.url.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store"

    return response


app.include_router(catalog.router)
app.include_router(checkout.router)
app.include_router(admin.router)


@app.get("/api/health")
def health():
    return {
        "status": "ok",
        "service": "The Blue Moon Store API",
    }


@app.get("/api/auth/me")
def auth_me(
    user=Depends(get_current_user),
):
    try:
        response = execute_read_with_retry(
            supabase_admin
            .table("profiles")
            .select(
                "id,full_name,email,phone,role,is_active"
            )
            .eq("id", str(user.id))
            .limit(1),
            operation="AUTH PROFILE",
        )
    except HTTPException:
        raise
    except Exception as exc:
        print(
            "AUTH PROFILE ERROR:",
            repr(exc),
            flush=True,
        )

        raise HTTPException(
            status_code=500,
            detail="Unable to load account profile",
        )

    rows = response.data or []

    if not rows:
        raise HTTPException(
            status_code=403,
            detail="Profile not found",
        )

    profile = rows[0]

    if not profile.get("is_active", False):
        raise HTTPException(
            status_code=403,
            detail="Account is inactive",
        )

    return {
        "id": str(user.id),
        "email": (
            profile.get("email")
            or getattr(user, "email", None)
        ),
        "role": profile.get("role"),
        "profile": profile,
    }



@app.get("/api/account/me")
def account_me(
    current=Depends(get_current_customer),
):
    return {
        "profile": current["profile"],
        "customer": current["customer"],
    }


@app.get("/api/account/orders")
def account_orders(
    current=Depends(get_current_customer),
):
    customer_id = current["customer"]["id"]

    try:
        response = (
            supabase_admin
            .table("orders")
            .select(
                """
                id,
                order_no,
                status,
                subtotal,
                discount,
                tax,
                total_amount,
                payment_method,
                payment_status,
                shipping_address,
                phone,
                notes,
                created_at,
                updated_at,
                order_items(
                    id,
                    product_id,
                    quantity,
                    unit_price,
                    discount,
                    subtotal,
                    products(
                        id,
                        name,
                        sku
                    )
                )
                """
            )
            .eq("customer_id", customer_id)
            .order("created_at", desc=True)
            .execute()
        )
    except Exception as exc:
        print(
            "ACCOUNT ORDERS ERROR:",
            repr(exc),
            flush=True,
        )

        raise HTTPException(
            status_code=500,
            detail="Unable to load orders",
        )

    return response.data or []


@app.get("/api/account/orders/{order_id}")
def account_order(
    order_id: int,
    current=Depends(get_current_customer),
):
    customer_id = current["customer"]["id"]

    try:
        response = (
            supabase_admin
            .table("orders")
            .select(
                """
                id,
                order_no,
                status,
                subtotal,
                discount,
                tax,
                total_amount,
                payment_method,
                payment_status,
                shipping_address,
                phone,
                notes,
                created_at,
                updated_at,
                order_items(
                    id,
                    product_id,
                    quantity,
                    unit_price,
                    discount,
                    subtotal,
                    products(
                        id,
                        name,
                        sku
                    )
                )
                """
            )
            .eq("id", order_id)
            .eq("customer_id", customer_id)
            .maybe_single()
            .execute()
        )
    except Exception as exc:
        print(
            "ACCOUNT ORDER ERROR:",
            repr(exc),
            flush=True,
        )

        raise HTTPException(
            status_code=500,
            detail="Unable to load order",
        )

    if not response.data:
        raise HTTPException(
            status_code=404,
            detail="Order not found",
        )

    return response.data


def serve_page(filename: str):
    return FileResponse(FRONTEND_DIR / filename)


@app.get("/", include_in_schema=False)
def frontend_home():
    return serve_page("index.html")


@app.get("/admin/orders", include_in_schema=False)
def admin_orders_page():
    return FileResponse(FRONTEND_DIR / "admin-orders.html")


@app.get("/admin/order", include_in_schema=False)
def admin_order_page():
    return FileResponse(FRONTEND_DIR / "admin-order.html")


@app.get("/admin/products", include_in_schema=False)
def admin_products_page():
    return FileResponse(FRONTEND_DIR / "admin-products.html")


@app.get("/admin/account", include_in_schema=False)
def admin_account_page():
    return FileResponse(FRONTEND_DIR / "admin-account.html")


@app.get("/admin/customers", include_in_schema=False)
def admin_customers_page():
    return FileResponse(FRONTEND_DIR / "admin-customers.html")


@app.get("/admin", include_in_schema=False)
def admin_page():
    return FileResponse(FRONTEND_DIR / "admin.html")


@app.get("/shop", include_in_schema=False)
def frontend_shop():
    return serve_page("shop.html")


@app.get("/product", include_in_schema=False)
def frontend_product():
    return serve_page("product.html")


@app.get("/cart", include_in_schema=False)
def frontend_cart():
    return serve_page("cart.html")


@app.get("/checkout", include_in_schema=False)
def frontend_checkout():
    return serve_page("checkout.html")


@app.get("/login", include_in_schema=False)
def frontend_login():
    return serve_page("login.html")


@app.get("/register", include_in_schema=False)
def frontend_register():
    return serve_page("register.html")


@app.get("/account", include_in_schema=False)
def frontend_account():
    return serve_page("account.html")


@app.get("/orders", include_in_schema=False)
def frontend_orders():
    return serve_page("orders.html")


@app.get("/order", include_in_schema=False)
def frontend_order():
    return serve_page("order.html")


app.mount(
    "/",
    StaticFiles(
        directory=FRONTEND_DIR,
        html=True,
    ),
    name="frontend",
)
