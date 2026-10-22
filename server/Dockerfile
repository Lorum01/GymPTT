# Immagine del server GymTalk (usata da Render).
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && dart compile exe bin/server.dart -o /app/server

# Immagine finale piccola: solo l'eseguibile e i certificati per l'HTTPS
# verso LiveKit e Neon.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /app/server
USER nobody
EXPOSE 8080
CMD ["/app/server"]
