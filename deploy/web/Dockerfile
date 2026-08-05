FROM ghcr.io/cirruslabs/flutter:3.44.7 AS builder

ARG APP_ENV=production
ARG API_BASE_URL=/api

WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
RUN flutter build web --release \
    --dart-define=APP_ENV=${APP_ENV} \
    --dart-define=API_BASE_URL=${API_BASE_URL}

FROM nginx:1.27-alpine
COPY deploy/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /src/build/web /usr/share/nginx/html
EXPOSE 80
