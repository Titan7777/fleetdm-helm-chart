CLUSTER   ?= fleet
NAMESPACE ?= fleet
RELEASE   ?= fleet
CHART     := charts/fleetdm
VALUES    ?= local/values-kind.yaml
FLEET_URL ?= https://localhost:8443
CA_FILE   ?= fleet-ca.crt
# Override to use another local cluster, e.g. KUBE_CONTEXT=docker-desktop
KUBE_CONTEXT ?= kind-$(CLUSTER)

KUBECTL := kubectl --context $(KUBE_CONTEXT) -n $(NAMESPACE)
HELM    := helm --kube-context $(KUBE_CONTEXT) -n $(NAMESPACE)

.PHONY: help cluster install uninstall verify ca agent lint destroy

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

cluster: ## Create the local Kind cluster
	@kind get clusters | grep -qx $(CLUSTER) || kind create cluster --name $(CLUSTER) --config local/kind-config.yaml --wait 120s

install: ## Install (or upgrade) the chart
	$(HELM) upgrade --install $(RELEASE) $(CHART) --create-namespace -f $(VALUES) --wait --timeout 15m
	@echo "Fleet UI: $(FLEET_URL)  (run 'make verify' to check, 'make ca' for the agent CA)"

uninstall: ## Remove the release and everything it created
	-$(HELM) uninstall $(RELEASE) --wait
	-kubectl --context $(KUBE_CONTEXT) delete namespace $(NAMESPACE) --ignore-not-found
	-docker rm -f fleet-test-agent 2>/dev/null
	rm -f $(CA_FILE) local/.admin.env

verify: ca ## Check that Fleet, MySQL and Redis are operational
	$(KUBECTL) rollout status deploy/$(RELEASE)-fleetdm --timeout 5m
	$(KUBECTL) exec sts/$(RELEASE)-fleetdm-mysql -- sh -c 'MYSQL_PWD="$$MYSQL_ROOT_PASSWORD" mysql -uroot -N -e "SELECT COUNT(*) FROM $$MYSQL_DATABASE.migration_status_tables"'
	$(KUBECTL) exec deploy/$(RELEASE)-fleetdm-redis -- redis-cli ping
	$(HELM) test $(RELEASE)
	curl -fsS --cacert $(CA_FILE) $(FLEET_URL)/healthz && echo "healthz ok"
	curl -fsS --cacert $(CA_FILE) $(FLEET_URL)/version

ca: ## Save the CA that agents need to trust into $(CA_FILE)
	@$(KUBECTL) get secret $(RELEASE)-fleetdm-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > $(CA_FILE)

agent: ca ## Enrol a throwaway osquery agent to prove agents can reach Fleet
	FLEET_URL=$(FLEET_URL) CA_FILE=$(CA_FILE) ./local/enroll-test-agent.sh

lint: ## Lint the chart
	helm lint $(CHART) -f $(VALUES)

destroy: ## Delete the Kind cluster
	kind delete cluster --name $(CLUSTER)
