package main

import future.keywords.if
import future.keywords.contains
import future.keywords.in

deny contains msg if {
	some name in app_names
	not name in hpa_names
	msg := sprintf("missing HorizontalPodAutoscaler for %s", [name])
}

deny contains msg if {
	some name in app_names
	not name in pdb_names
	msg := sprintf("missing PodDisruptionBudget for %s", [name])
}

app_names contains name if {
	some doc in input
	doc.kind == "Rollout"
	name := doc.metadata.name
}

app_names contains name if {
	some doc in input
	doc.kind == "Deployment"
	name := doc.metadata.name
	name != "grafana-alloy"
}

hpa_names contains name if {
	some doc in input
	doc.kind == "HorizontalPodAutoscaler"
	name := doc.metadata.name
}

pdb_names contains name if {
	some doc in input
	doc.kind == "PodDisruptionBudget"
	name := doc.metadata.name
}
