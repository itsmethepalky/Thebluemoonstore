import os

from dotenv import load_dotenv

load_dotenv()


class Settings:
    SUPABASE_URL: str = os.getenv("SUPABASE_URL", "")
    SUPABASE_ANON_KEY: str = os.getenv("SUPABASE_ANON_KEY", "")
    SUPABASE_SERVICE_ROLE_KEY: str = os.getenv(
        "SUPABASE_SERVICE_ROLE_KEY",
        "",
    )
    OSM_NOMINATIM_URL: str = os.getenv(
        "OSM_NOMINATIM_URL",
        "https://nominatim.openstreetmap.org",
    ).rstrip("/")
    OSM_ROUTING_URL: str = os.getenv(
        "OSM_ROUTING_URL",
        "https://router.project-osrm.org",
    ).rstrip("/")
    STORE_CONTACT_EMAIL: str = os.getenv(
        "STORE_CONTACT_EMAIL",
        "",
    )
    STORE_ORIGIN_LATITUDE: str = os.getenv(
        "STORE_ORIGIN_LATITUDE",
        "",
    )
    STORE_ORIGIN_LONGITUDE: str = os.getenv(
        "STORE_ORIGIN_LONGITUDE",
        "",
    )

    def validate(self):
        missing = []

        if not self.SUPABASE_URL:
            missing.append("SUPABASE_URL")

        if not self.SUPABASE_ANON_KEY:
            missing.append("SUPABASE_ANON_KEY")

        if not self.SUPABASE_SERVICE_ROLE_KEY:
            missing.append("SUPABASE_SERVICE_ROLE_KEY")

        if missing:
            raise RuntimeError(
                "Missing required environment variables: "
                + ", ".join(missing)
            )


settings = Settings()
