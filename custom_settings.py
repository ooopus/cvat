from cvat.settings.production import *
import os
from pathlib import Path

# CSRF trusted origins - configure via environment variable for reverse proxy setups
# Example: CSRF_TRUSTED_ORIGINS=https://cvat.example.com,https://192.168.1.100
_csrf_origins = os.environ.get("CSRF_TRUSTED_ORIGINS", "")
CSRF_TRUSTED_ORIGINS = [origin.strip() for origin in _csrf_origins.split(",") if origin.strip()]

# Secret key - supports both environment variable and Docker secrets (_FILE suffix)
if (secret_key_file := os.getenv("DJANGO_SECRET_KEY_FILE")) is not None:
    if "DJANGO_SECRET_KEY" in os.environ:
        from django.core.exceptions import ImproperlyConfigured
        raise ImproperlyConfigured(
            "DJANGO_SECRET_KEY and DJANGO_SECRET_KEY_FILE must not be set at the same time"
        )
    SECRET_KEY = Path(secret_key_file).read_text(encoding="UTF-8").rstrip("\n")
