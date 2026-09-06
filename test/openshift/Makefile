include ../Makefile

CRC_VERSION?=2.63.0
OS_VERSION?=4.22.0
# openshift 4.22.1 okd 4.21.0 microshift 4.22.0
OS_PRESET?=microshift
ifeq ($(OS_PRESET), "okd")
	OS_SUFIX?=-okd-scos.8
endif

PULL_SECRET?=$(shell cat .crc_pull_secret)

all: build test

deps:
	vagrant plugin install vagrant-libvirt
	vagrant plugin install vagrant-scp

.PHONY: setup-test
setup-test: cleanup-test
	vagrant up --provider=libvirt

_load:
	docker image save $(REPO)/$(IMAGE_NAME):$(TAG) -o $(TAG).tar
	vagrant rsync

_deploy:
	@vagrant ssh -c "echo -n '$(PULL_SECRET)' > /home/vagrant/.crc_pull_secret"

# 	vagrant ssh -c "curl -qL https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/crc/$(CRC_VERSION)/crc-linux-amd64.tar.xz | sudo tar -xJ -C /opt"
	vagrant ssh -c "sudo mkdir -p /opt/crc-linux-$(CRC_VERSION)-amd64 && sudo curl -qL 'https://github.com/mhmxs/crc/releases/download/v$(CRC_VERSION)%2Bhk.0/crc' -o /opt/crc-linux-$(CRC_VERSION)-amd64/crc && sudo chmod +x /opt/crc-linux-$(CRC_VERSION)-amd64/crc"

	vagrant ssh -c "([ -f /vagrant/.crc_cache/crc_$(OS_PRESET)_libvirt_$(OS_VERSION)$(OS_SUFIX)_amd64.crcbundle ] && crc config set bundle /vagrant/.crc_cache/crc_$(OS_PRESET)_libvirt_$(OS_VERSION)$(OS_SUFIX)_amd64.crcbundle) ||:"
	vagrant ssh -c "crc config set consent-telemetry no"
	vagrant ssh -c "crc config set disable-update-check true"
	vagrant ssh -c "crc config set developer-password developer"
	vagrant ssh -c "crc config set kubeadmin-password kubeadmin"
	vagrant ssh -c "crc config set preset $(OS_PRESET)"
	vagrant ssh -c "crc config set cpus 8"
	vagrant ssh -c "crc config set memory 5632"
	vagrant ssh -c "crc setup --log-level=debug"

	vagrant ssh -c "crc start --pull-secret-file=/vagrant/.crc_pull_secret --log-level=debug"

	vagrant ssh -c "oc create serviceaccount remote-admin -n kube-system"
	vagrant ssh -c "oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:kube-system:remote-admin"
	vagrant ssh -c 'oc login --server=https://$$(dirname $$(ip -f inet addr show eth0 | awk "/inet / {print \$$2}")):6443 --token=$$(oc create token remote-admin -n kube-system --duration=8760h) --insecure-skip-tls-verify=true --kubeconfig=/home/vagrant/.kube/config.remote-admin'
	@rm -f $(KUBECONFIG) ||: ; mkdir -p $$(dirname $(KUBECONFIG)) ; vagrant scp default:/home/vagrant/.kube/config.remote-admin $(KUBECONFIG)

	kubectl wait --for=condition=Ready node/api.crc.testing --timeout=5m

	$(MAKE) _setup-test

	vagrant ssh -c "scp -i ~/.crc/machines/crc/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 2222 /vagrant/$(TAG).tar core@127.0.0.1:/home/core"
	vagrant ssh -c "ssh -i ~/.crc/machines/crc/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 core@127.0.0.1 sudo podman load --input /home/core/$(TAG).tar"
		
	$(MAKE) -BC ../helm _deploy

_test:
	vcluster connect harikube
	$(MAKE) -BC ../suites simple
	vcluster disconnect ||:

.PHONY: cleanup-test
cleanup-test:
	vcluster disconnect ||:
	@vagrant destroy -f ||:

_cleanup-test:

ssh:
	vagrant ssh -c "ssh -i ~/.crc/machines/crc/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 core@127.0.0.1"

cache-bundle:
	mkdir -p .crc_cache
	vagrant scp default:/home/vagrant/.crc/cache/crc_$(OS_PRESET)_libvirt_$(OS_VERSION)$(OS_SUFIX)_amd64.crcbundle .crc_cache/crc_$(OS_PRESET)_libvirt_$(OS_VERSION)$(OS_SUFIX)_amd64.crcbundle