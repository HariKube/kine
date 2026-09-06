export HKTPF=-helm
include ../Makefile

all: build test

_load:
	kind load docker-image -n $(KIND_CLUSTER) $(REPO)/$(IMAGE_NAME):$(TAG)

_deploy:
	kubectl create namespace $(NAMESPACE) ||:
	kubectl label namespace $(NAMESPACE) harikube.info/$(NAMESPACE)-middleware=enabled --overwrite
	kubectl label namespace $(NAMESPACE) harikube.info/$(NAMESPACE)-apiserver=enabled --overwrite
	kubectl label namespace $(NAMESPACE) harikube.info/$(NAMESPACE)-controllermanager=enabled --overwrite

	helm install harikube ../../harikube-helm-charts/harikube \
		--debug \
		--namespace $(NAMESPACE) \
		--set middleware.image.tag=$(TAG) \
		--set middleware.monitoring.create=true \
		--set middleware.networkPolicy.create=true \
		--set apiServer.create=true \
		--set apiServer.monitoring.create=true \
		--set apiServer.networkPolicy.create=true \
		--set controllerManager.create=true \
		--set controllerManager.monitoring.create=true \
		--set controllerManager.networkPolicy.create=true
	kubectl wait -n $(NAMESPACE) --for=jsonpath='{.status.readyReplicas}'=1 statefulset/harikube --timeout=15m

_test:
	vcluster connect harikube
	$(MAKE) -BC ../suites vcluster
	$(MAKE) -BC ../suites simple
	vcluster disconnect ||:

_cleanup-test:
	vcluster disconnect ||:
