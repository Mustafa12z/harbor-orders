package main

import future.keywords.if
import future.keywords.contains
import future.keywords.in

deny contains msg if {
	some workload in workloads
	some container in workload.containers
	not container.resources.requests.cpu
	msg := sprintf("%s/%s container %s missing cpu requests", [workload.kind, workload.name, container.name])
}

deny contains msg if {
	some workload in workloads
	some container in workload.containers
	not container.resources.requests.memory
	msg := sprintf("%s/%s container %s missing memory requests", [workload.kind, workload.name, container.name])
}

deny contains msg if {
	some workload in workloads
	some container in workload.containers
	not container.readinessProbe
	msg := sprintf("%s/%s container %s missing readinessProbe", [workload.kind, workload.name, container.name])
}

deny contains msg if {
	some workload in workloads
	some container in workload.containers
	not container.livenessProbe
	workload.name != "postgres"
	workload.name != "redis"
	msg := sprintf("%s/%s container %s missing livenessProbe", [workload.kind, workload.name, container.name])
}

deny contains msg if {
	some workload in workloads
	some container in workload.containers
	container.readinessProbe.httpGet.path
	container.livenessProbe.httpGet.path
	container.readinessProbe.httpGet.path == container.livenessProbe.httpGet.path
	workload.name != "grafana-alloy"
	msg := sprintf("%s/%s readiness and liveness paths must differ", [workload.kind, workload.name])
}

deny contains msg if {
	some workload in workloads
	some container in workload.containers
	endswith(container.image, ":latest")
	msg := sprintf("%s/%s uses :latest tag", [workload.kind, workload.name])
}

deny contains msg if {
	some workload in workloads
	some container in workload.containers
	contains(container.image, "IMAGE_PREFIX")
	msg := sprintf("%s/%s still has IMAGE_PREFIX placeholder", [workload.kind, workload.name])
}

deny contains msg if {
	some workload in app_workloads
	not workload.podSecurity.runAsNonRoot
	msg := sprintf("%s/%s missing pod runAsNonRoot", [workload.kind, workload.name])
}

deny contains msg if {
	some workload in app_workloads
	some container in workload.containers
	object.get(container, "securityContext", {}).allowPrivilegeEscalation != false
	msg := sprintf("%s/%s container allows privilege escalation", [workload.kind, workload.name])
}

deny contains msg if {
	some workload in app_workloads
	some container in workload.containers
	object.get(container, "securityContext", {}).privileged == true
	msg := sprintf("%s/%s container is privileged", [workload.kind, workload.name])
}

workloads contains w if {
	input.kind == "Deployment"
	w := {
		"kind": input.kind,
		"name": input.metadata.name,
		"containers": input.spec.template.spec.containers,
		"podSecurity": object.get(input.spec.template.spec, "securityContext", {}),
	}
}

workloads contains w if {
	input.kind == "StatefulSet"
	w := {
		"kind": input.kind,
		"name": input.metadata.name,
		"containers": input.spec.template.spec.containers,
		"podSecurity": object.get(input.spec.template.spec, "securityContext", {}),
	}
}

workloads contains w if {
	input.kind == "Rollout"
	w := {
		"kind": input.kind,
		"name": input.metadata.name,
		"containers": input.spec.template.spec.containers,
		"podSecurity": object.get(input.spec.template.spec, "securityContext", {}),
	}
}

app_workloads contains w if {
	some w in workloads
	w.name != "postgres"
	w.name != "redis"
}
