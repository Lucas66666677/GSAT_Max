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

## Release preflight

`backend/release_preflight.py` checks a release before it goes out: the shape of
the production configuration, Alembic migration readiness, the backend health
contracts, and the frontend-to-backend URL wiring. It reads no secret value,
opens no database connection, makes no network request, and changes nothing --
secrets are reduced to a presence flag and a length at the input boundary, and
`DATABASE_URL` to a credential-free shape, so the report is safe to paste into a
pull request or a CI log.

```powershell
.\.venv\Scripts\python.exe -m backend.release_preflight `
  --from-environ --frontend-origin https://your-domain
```

Pass `--env-file` instead of `--from-environ` to check a configuration file, and
`--json` for a machine-readable report. The exit code is non-zero when any check
fails. The cross-cutting check worth knowing about is
`web_build_host_is_trusted_by_the_api`: the backend hostname the web build is
compiled against has to be one the API's own `TrustedHostMiddleware` accepts,
because a mismatch answers every request with `400` while both sides look
individually healthy.

`GET /health` is unauthenticated, so whatever it returns is public. Two checks
hold that line, and both read the fields `backend/main.py` actually returns
rather than a list kept alongside them:
`health_contract_matches_the_served_payload` fails when the handler and the
declared contract drift apart, and `health_fields_reduce_secrets_to_presence`
fails when a field is built out of a secret. A field name can be innocuous while
its value is not -- `"service": f"GSAT_Max Backend ({DATABASE_URL})"` leaves the
key set untouched and publishes the database password -- so the field names are
checked and so is what produces each value. Reducing a secret to presence or
length, as `bool(OPENAI_API_KEY)` does, stays allowed.

The deployment health gate probes `GET /livez`, not `GET /health`. `/health`
executes a query, so a gate pointed at it reports the backend process as dead
whenever the database is briefly unreachable and holds back everything gated on
it. `/livez` consults nothing and returns a literal, which is the question a
gate asks. `deployment_health_gate_probes_liveness` reads the probe out of
`compose.yaml` and fails when it drifts onto a dependency-sensitive route or
becomes unreadable; `liveness_route_consults_no_dependency` fails if `/livez`
ever grows an injected dependency; `liveness_payload_reads_nothing` fails if it
grows a field built from anything but a literal; and `/livez` is in
`REQUIRED_ROUTES`, so deleting it fails the release rather than leaving the gate
probing a 404.

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
