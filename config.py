from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):
    # Supabase
    supabase_url: str
    supabase_service_key: str

    # Meta WhatsApp
    wa_phone_number_id: str
    wa_access_token: str
    wa_verify_token: str = "magnus_sofia_2026"
    wa_api_version: str = "v23.0"

    # Anthropic
    anthropic_api_key: str

    # App
    app_env: str = "production"
    santiago_phone: str = ""
    log_level: str = "INFO"

    class Config:
        env_file = ".env"


@lru_cache
def get_settings() -> Settings:
    return Settings()
