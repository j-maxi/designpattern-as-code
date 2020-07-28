package api

import (
	"encoding/json"

	corev1 "k8s.io/api/core/v1"
	networkingv1beta1 "k8s.io/api/networking/v1beta1"

	"github.com/j-maxi/designpattern-as-code/base:resource"
)

#exposePort: 5000

#Service: {
	corev1.#Service

	apiVersion: "v1"
	kind:       "Service"
}

#Ingress: {
	networkingv1beta1.#Ingress

	apiVersion: "networking.k8s.io/v1beta1"
	kind:       "Ingress"
}

// schema validation
DesignPattern: resource.DesignPattern

DesignPattern: {
	parameters: {
		appName:                 string
		repository:              string
		revision:                string
		designpatternRepository: string
		designpatternRevision:   string
		port:                    int
		globalIpName:            string
		domainName:              string
		gcpProjectID:            string
	}

	// Service, Ingress, Backendconfig definition for the app
	resources: kubernetes: {
		service: #Service
		ingress: #Ingress
	}

	// assign service metadata
	resources: kubernetes: service: metadata: {
		name: parameters.appName
		annotations: {
			_ingress: {ingress: true}
			"cloud.google.com/neg": json.Marshal(_ingress)
		}
	}

	// assign service spec
	resources: kubernetes: service: spec: {
		type: corev1.#ServiceTypeNodePort
		ports: [
			{
				name:       "app-port"
				protocol:   corev1.#ProtocolTCP
				port:       #exposePort
				targetPort: parameters.port
			},
		]
		selector: app: parameters.appName
	}

	// assign deployment metadata
	resources: kubernetes: deployment: metadata: labels: app: parameters.appName

	// assign deployment a port spec to point from the service
	resources: kubernetes: deployment: spec: template: spec: containers: [
		{
			ports: [
				{
					containerPort: parameters.port
				},
			]
		},
	]

	// assign ingress metadata
	resources: kubernetes: ingress: metadata: {
		name: parameters.appName
		annotations: {
			"kubernetes.io/ingress.allow-http":            "true"
			"kubernetes.io/ingress.global-static-ip-name": parameters.globalIpName
		}
	}
	// assign ingress spec
	resources: kubernetes: ingress: spec: {
		backend: {
			serviceName: parameters.appName
			servicePort: #exposePort
		}
	}

	resources: gcp: uptimecheck: {
		displayName: parameters.appName
		monitoredResource: {
			type: "uptime_url"
			labels: {
				host: parameters.domainName
			}
		}
		httpCheck: {
			path: "/"
			port: 80
		}
		timeout: "10s"
		period:  "60s"
	}

	tasks: check: uptime: {
		name: "check-api"
		params: [
			{
				name:  "repository"
				value: parameters.repository
			},
			{
				name:  "revision"
				value: parameters.revision
			},
			{
				name:  "designpatternRepository"
				value: parameters.designpatternRepository
			},
			{
				name:  "designpatternRevision"
				value: parameters.designpatternRevision
			},
			{
				name:  "uptimecheckName"
				value: parameters.appName
			},
			{
				name:  "domainName"
				value: parameters.domainName
			},
			{
				name:  "checkTimeout"
				value: "600"
			},
			{
				name:  "gcpProjectID"
				value: parameters.gcpProjectID
			},
		]
		taskSpec: UptimeTaskSpec
	}
}

UptimeTaskSpec: {
	params: [
		{
			name: "repository"
		},
		{
			name: "revision"
		},
		{
			name: "designpatternRepository"
		},
		{
			name: "designpatternRevision"
		},
		{
			name: "uptimecheckName"
		},
		{
			name: "domainName"
		},
		{
			name: "checkTimeout"
		},
		{
			name: "gcpProjectID"
		},
	]
	steps: [
		{
			name:  "git-pull"
			image: "docker:git"
			command: ["/usr/bin/git"]
			args: [
				"clone",
				"$(params.repository)",
				"application",
			]
		},
		{
			name:  "git-checkout"
			image: "docker:git"
			command: ["/usr/bin/git"]
			args: [
				"checkout",
				"$(params.revision)",
			]
			workingDir: "/workspace/application"
		},
		{
			name:  "git-pull-designpattern"
			image: "docker:git"
			command: ["/usr/bin/git"]
			args: [
				"clone",
				"$(params.designpatternRepository)",
				"designpatterns",
			]
		},
		{
			name:  "git-checkout-designpattern"
			image: "docker:git"
			command: ["/usr/bin/git"]
			args: [
				"checkout",
				"$(params.designpatternRevision)",
			]
			workingDir: "/workspace/designpatterns"
		},
		{
			name:  "compile"
			image: "cuelang/cue:0.2.1"
			args: [
				"export",
				"/workspace/application/build/app.cue",
				"--expression=uptimecheckConfig",
				"--out=json",
				"--outfile=/workspace/check.json",
			]
			workingDir: "/workspace/designpatterns"
		},
		{
			name:  "get-gcp-access-token"
			image: "google/cloud-sdk:278.0.0"
			command: ["/bin/sh", "-c"]
			args: [
				"gcloud auth application-default print-access-token > /workspace/.access-token",
			]
			env: [
				{
					name:  "GOOGLE_APPLICATION_CREDENTIALS"
					value: "/secret/account.json"
				},
			]
			volumeMounts: [
				{
					name:      "gcp-secret"
					mountPath: "/secret"
					readOnly:  true
				},
			]
		},
		{
			name:  "check-existing-uptimecheck"
			image: "cimg/base:2020.07-18.04"
			command: ["/bin/bash", "-c"]
			args: [
				"curl -H \"Authorization: Bearer $(cat /workspace/.access-token)\" https://monitoring.googleapis.com/v3/projects/$(params.gcpProjectID)/uptimeCheckConfigs | jq -r '.uptimeCheckConfigs[] | select(.displayName == \"$(params.uptimecheckName)\") | .name' > /workspace/uptimechecks.txt",
			]
		},
		{
			name:  "remove-uptimechecks"
			image: "curlimages/curl:7.71.1"
			command: ["/bin/sh", "-c"]
			args: [
				"while read config; do curl -H \"Authorization: Bearer $(cat /workspace/.access-token)\" https://monitoring.googleapis.com/v3/projects/$(params.gcpProjectID)/uptimeCheckConfigs/${config} -X DELETE; done < /workspace/uptimechecks.txt",
			]
		},
		{
			name:  "create-uptimecheck"
			image: "curlimages/curl:7.71.1"
			command: ["/bin/sh", "-c"]
			args: [
				"curl -H \"Content-Type: application/json\" -H \"Authorization: Bearer $(cat /workspace/.access-token)\" https://monitoring.googleapis.com/v3/projects/$(params.gcpProjectID)/uptimeCheckConfigs -X POST -d @check.json",
			]
		},
		{
			name:  "wait-api"
			image: "curlimages/curl:7.71.1"
			command: ["timeout"]
			args: [
				"$(params.checkTimeout)",
				"/bin/sh",
				"-c",
				"while [[ \"$(curl -s -o /dev/null -w ''%{http_code}'' http://$(params.domainName))\" != \"200\" ]]; do sleep 10; done",
			]
		},
	]
	volumes: [
		{
			name: "gcp-secret"
			secret: {
				secretName: "serviceaccount"
				items: [
					{
						key:  "serviceaccount"
						path: "account.json"
					},
				]
			}
		},
	]
}
