# GSAT_Max Website Deployment

The website is the Flutter application compiled for Web. It shares the same
FastAPI authentication, progress, vocabulary, writing, OCR, and AI data as the
Android/iOS application.

## Local full stack

Install Docker Desktop, then run:

```powershell
.\scripts\start_full_stack.ps1
```

Open `http://localhost:8080`. Nginx serves the responsive Flutter website and
proxies `http://localhost:8080/api/*` to FastAPI, so the browser remains on one
origin. SQLite data persists in the `gsat_max_data` Docker volume. Backend
startup runs `alembic upgrade head` before the idempotent 500-word/50-concept
seed, then starts Uvicorn.

## Static Web build

For a frontend host with a separate HTTPS backend:

```powershell
.\scripts\build_web.ps1 -ApiBaseUrl https://api.example.com
```

For a reverse proxy that exposes FastAPI under the same domain at `/api`:

```powershell
.\scripts\build_web.ps1 -ApiBaseUrl /api
```

Upload the generated `build/web/` directory. The host must serve `index.html`
as the fallback for unknown paths and must not cache `index.html` or
`flutter_service_worker.js` permanently.

## Production checklist

1. Terminate TLS at the hosting platform or an outer reverse proxy.
2. Set `APP_ENV=production`, `PUBLIC_APP_URL=https://your-domain`, a random
   `JWT_SECRET_KEY`, and explicit provider secrets in the deployment secret
   manager.
3. Persist `/data`, schedule database backups, and run only one SQLite-backed
   API replica. Move to managed PostgreSQL before horizontal scaling.
4. Keep AI keys on FastAPI only. Never pass them as Flutter `dart-define`
   values.
5. Replace the development email provider and complete RevenueCat store setup
   before accepting public payments.
