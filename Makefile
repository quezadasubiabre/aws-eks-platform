deploy-infra:
	AWS_PROFILE=myaws terraform -chdir=infraestructure/static init
	AWS_PROFILE=myaws terraform -chdir=infraestructure/static apply
static-detroy:
	AWS_PROFILE=myaws terraform -chdir=infraestructure/static destroy
deploy-eks:
	AWS_PROFILE=myaws terraform -chdir=infraestructure/eks init
	AWS_PROFILE=myaws terraform -chdir=infraestructure/eks apply
eks-login:
	AWS_PROFILE=myaws aws eks update-kubeconfig --region eu-west-1 --name k8s-cloud-project

install-argocd: eks-login
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	kubectl scale deployment argocd-dex-server -n argocd --replicas=0
	kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

open-argocd:
	kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
	kubectl port-forward svc/argocd-server -n argocd 8080:443

add-argocd-credentials:
	sed -e "s|\$${GITHUB_TOKEN}|$$GITHUB_TOKEN|" -e "s|\$${GITHUB_USERNAME}|$$GITHUB_USERNAME|" gitops/bootstrap/repo-credentials.yaml | kubectl apply -n argocd -f -

update-my-ip:
	$(eval MY_IP := $(shell curl -s https://checkip.amazonaws.com))
	sed -i '' -E "s#(aws-load-balancer-source-ranges: ).*#\1$(MY_IP)/32#" gitops/apps/traefik/values.yaml
	@echo "Set aws-load-balancer-source-ranges to $(MY_IP)/32 - review the diff, then commit and push"

add-cluster-issuer:
	sed "s|\$${ACME_EMAIL}|$$ACME_EMAIL|g" gitops/apps/cert-manager/manifests/cluster-issuer.yaml | kubectl apply -f -

open-graphana:
	kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80

create-cloudflare-secret:
	kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic cloudflare-api-token-secret -n cert-manager \
		--from-literal=api-token="$$(AWS_PROFILE=myaws aws ssm get-parameter \
			--region eu-west-1 \
			--name /k8s-cloud-project/cert-manager/cloudflare-api-token \
			--with-decryption --query Parameter.Value --output text)" \
		--dry-run=client -o yaml | kubectl apply -f -

install-app: create-cloudflare-secret
	kubectl apply -f gitops/bootstrap/aws-load-balancer-controller-app.yaml
	kubectl apply -f gitops/bootstrap/cert-manager-app.yaml
	$(MAKE) add-cluster-issuer
	kubectl apply -f gitops/bootstrap/traefik-app.yaml


