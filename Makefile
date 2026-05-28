REGISTRY ?= yourname
TAG      ?= latest
EC2      ?= ec2-user@your-ec2-ip
EC2_DIR  ?= /opt/im

# ── Local dev ──────────────────────────────────────────────────────────────
up:
	cd open-im-server && docker compose up -d
	cd im-business && docker compose up -d --build
	docker compose -f docker-compose.server.yml up -d

down:
	docker compose -f docker-compose.server.yml down
	cd im-business && docker compose down
	cd open-im-server && docker compose down

setup:
	./setup.sh   # updates minio.yml + config.dart _host, restarts openim-server

logs:
	docker compose -f docker-compose.server.yml logs -f

# ── Build & push images ────────────────────────────────────────────────────
build:
	docker build -t $(REGISTRY)/im-business:$(TAG) ./im-business
	docker build -f Dockerfile.openim-server -t $(REGISTRY)/openim-server:$(TAG) .

push:
	docker push $(REGISTRY)/im-business:$(TAG)
	docker push $(REGISTRY)/openim-server:$(TAG)

build-push: build push

# ── EC2 deploy ─────────────────────────────────────────────────────────────
# Syncs config/compose files only — no source code, no openimsdk-core
deploy-config:
	rsync -avz --delete \
	  --exclude='.git' \
	  --exclude='.claude' \
	  --exclude='im-wallet-app' \
	  --exclude='openimsdk-core' \
	  --exclude='open-im-server' \
	  --exclude='im-business' \
	  --exclude='env.json' \
	  --exclude='.env' \
	  . $(EC2):$(EC2_DIR)/
	rsync -avz \
	  open-im-server/docker-compose.yml \
	  open-im-server/.env \
	  $(EC2):$(EC2_DIR)/open-im-server/

deploy-up:
	ssh $(EC2) 'cd $(EC2_DIR)/open-im-server && docker compose up -d'
	ssh $(EC2) 'cd $(EC2_DIR) && docker compose -f docker-compose.prod.yml --env-file .env.prod pull && docker compose -f docker-compose.prod.yml --env-file .env.prod up -d'

deploy: deploy-config deploy-up

.PHONY: up down setup logs build push build-push deploy-config deploy-up deploy
