.DEFAULT_GOAL := ci

ARCH ?= amd64
REPO ?= rancher
DEFAULT_BUILD_ARGS=--build-arg="REPO=$(REPO)" --build-arg="TAG=$(TAG)" --build-arg="ARCH=$(ARCH)" --build-arg="DIRTY=$(DIRTY)"
DIRTY := $(shell git status --porcelain --untracked-files=no)
ifneq ($(DIRTY),)
	DIRTY="-dirty"
endif

clean:
	rm -rf ./bin ./dist

.PHONY: validate
validate:
	DOCKER_BUILDKIT=1 docker build \
		$(DEFAULT_BUILD_ARGS) --build-arg="SKIP_VALIDATE=$(SKIP_VALIDATE)" \
		--target=validate -f Dockerfile .

.PHONY: build
build:
	DOCKER_BUILDKIT=1 docker build \
		$(DEFAULT_BUILD_ARGS) --build-arg="DRONE_TAG=$(DRONE_TAG)" \
		-f Dockerfile --target=binary --output=. .

.PHONY: multi-arch-build
PLATFORMS = linux/amd64,linux/arm64,linux/arm/v7,linux/riscv64
multi-arch-build:
	docker buildx build --build-arg="REPO=$(REPO)" --build-arg="TAG=$(TAG)" --build-arg="DIRTY=$(DIRTY)" --platform=$(PLATFORMS) --target=multi-arch-binary --output=type=local,dest=bin .
	mv bin/linux*/kine* bin/
	rmdir bin/linux*
	mkdir -p dist/artifacts
	cp bin/kine* dist/artifacts/

.PHONY: package
package:
	ARCH=$(ARCH) ./scripts/package

.PHONY: ci
ci: validate build package

.PHONY: test
test:
	go test -cover -tags=test $(shell go list ./... | grep -v nats)

MAKEFLAGS += --no-print-directory

_wait-for-service:
	@bash -c 'while `! nc -z -v -w5 $(HP) > /dev/null 2>&1`; do sleep 1; done'

KINE_FLAGS?=--slow-sql-threshold=0 --metrics-bind-address=:9200 --compact-interval=5m
KINE_SQLITE_DB?=$(SQLITE_DIR)/state.db
KINE_LISTEN_ADDRESS?=0.0.0.0:2369
KINE_CONN_POOL?=--datastore-max-idle-connections=5 --datastore-max-open-connections=90 --datastore-connection-max-lifetime=5m

_kine-start:
	CGO_ENABLED=1 \
	CGO_CFLAGS="-DSQLITE_ENABLE_DBSTAT_VTAB=1 -DSQLITE_USE_ALLOCA=1" \
	go run main.go --listen-address=$(KINE_LISTEN_ADDRESS) $(KINE_FLAGS) $(KINE_CONN_POOL) --endpoint="$(KINE_ENDPOINT)"

kine-start-sqlite: sqlite-start
	KINE_ENDPOINT="sqlite://$(KINE_SQLITE_DB)?_journal=WAL&cache=shared&_busy_timeout=30000&_txlock=immediate" $(MAKE) _kine-start

kine-start-mysql: mysql-start
	KINE_ENDPOINT="mysql://root:passwd@tcp(127.0.0.1:3306)/kine_db" $(MAKE) _kine-start

kine-start-pgsql: pgsql-start
	KINE_ENDPOINT="postgres://postgres:passwd@127.0.0.1:5432/kine_db" $(MAKE) _kine-start

DB_CPU?=2
DB_MEM?=512m
SQLITE_DIR?=./db
MYSQL_PORT?=3306
PGSQL_PORT?=5432

sqlite-start:
	@mkdir -p $(SQLITE_DIR)

sqlite-exec:
	sqlite3 "$(KINE_SQLITE_DB)"

sqlite-kill:
	@rm -rf $(SQLITE_DIR)

mysql-start:
	docker run -d --name mysql${MYSQL_PORT} -e PUID=1000 -e PGID=1000 -e MYSQL_ROOT_PASSWORD=passwd -e TZ=Europe/Budapest -p ${MYSQL_PORT}:3306 --cpus="$(DB_CPU)" --memory="$(DB_MEM)" ghcr.io/linuxserver/mariadb:10.11.8
	HP='127.0.0.1 $(MYSQL_PORT)' timeout 120s $(MAKE) _wait-for-service
	@while `! docker exec mysql${MYSQL_PORT} mysql -uroot -ppasswd -e "SELECT 1" > /dev/null 2>&1`; do sleep 1; done

mysql-exec:
	docker exec -it mysql${MYSQL_PORT} mysql -uroot -ppasswd kine_db

mysql-kill:
	@docker rm -f mysql${MYSQL_PORT} > /dev/null 2>&1 ||:

mysql-start-multi:
	ETCD_PORT=2479 ETCD_PORT2=2480 $(MAKE) etcd-start
	@for port in 3306 3307 3308 3309 3310 3311 ; do \
		MYSQL_PORT=$$port $(MAKE) mysql-start ; \
	done

pgsql-start:
	docker run -d --name pgsql${PGSQL_PORT} -e POSTGRES_PASSWORD=passwd -e PGDATA=/config -p ${PGSQL_PORT}:5432 --cpus="$(DB_CPU)" --memory="$(DB_MEM)" postgres:17-alpine3.20
	HP='127.0.0.1 $(PGSQL_PORT)' timeout 120s $(MAKE) _wait-for-service
	@while `! docker exec pgsql5432 su postgres -c "psql -c 'SELECT 1'" > /dev/null 2>&1`; do sleep 1; done

pgsql-exec:
	docker exec -it pgsql${PGSQL_PORT} su postgres -c "psql -d kine_db"

pgsql-kill:
	@docker rm -f pgsql${PGSQL_PORT} > /dev/null 2>&1 ||:

db-kill: sqlite-kill
	@for port in 3306 3307 3308 3309 3310 3311 ; do \
		MYSQL_PORT=$$port $(MAKE) mysql-kill ; \
	done
	@for port in 5432 5433 5434 5435 5436 5437 ; do \
		PGSQL_PORT=$$port $(MAKE) pgsql-kill ; \
	done

KIND_CLUSTER ?= kine-test

KUBE_TEST_RUN?=sig-api-machinery|sig-apps|sig-auth|sig-instrumentation|sig-scheduling
KUBE_TEST_SKIP?=Alpha|Flaky|[Aa]uto[Ss]cal|mysql|zookeeper|redis|CockroachDB|ClusterTrustBundle|SchedulerAsyncPreemption|BoundServiceAccountTokenVolume|StorageVersionAPI|StatefulUpgrade|CoordinatedLeaderElection|capture the life of a ResourceClaim|should rollback without unnecessary restarts|should grab all metrics from|compacted away
KUBE_TEST_TIMEOUT?=2h
KUBE_TEST_RETRIES?=1
KUBE_TEST_PARALLEL?=1

kube-start:
	kind create cluster --name $(KIND_CLUSTER) --config hack/kind-config.yaml

	kubectl wait --for=condition=Ready node/$(KIND_CLUSTER)-control-plane --timeout=120s

kube-test:
	cd $(KUBE_LOCATION) ; \
		kubetest2-noop --up && kubetest2-tester-ginkgo --parallel=$(KUBE_TEST_PARALLEL) --timeout=$(KUBE_TEST_TIMEOUT) \
			--use-binaries-from-path=true \
			--focus-regex="$(KUBE_TEST_RUN)" \
			--ginkgo-args='--v --seed=1 --flake-attempts=$(KUBE_TEST_RETRIES)' \
			--skip-regex="$(KUBE_TEST_SKIP)"

kube-test-kine:
	KUBE_TEST_RUN=sig-api-machinery KUBE_TEST_TIMEOUT=20m KUBE_TEST_RETRIES=3 KUBE_TEST_PARALLEL=10 KUBE_TEST_SKIP='StorageVersionAPI|Slow|Flaky|Alpha' $(MAKE) kube-test

kube-kill:
	kind delete cluster --name $(KIND_CLUSTER)
