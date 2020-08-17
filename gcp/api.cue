package api

import (
	"encoding/json"

	corev1 "k8s.io/api/core/v1"
	networkingv1beta1 "k8s.io/api/networking/v1beta1"

	"github.com/j-maxi/designpattern-as-code/base:resource"
)

// for Service port
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

// TODO: valdiate UptimeCheckConfig with
// google.golang.org/genproto/googleapis/monitoring/v3
#UptimeCheckDeploymentConfig: {
	name: "uptimecheck"
	type: "gcp-types/monitoring-v3:projects.uptimeCheckConfigs"
	properties: {
		displayName: string
		monitoredResource: {
			type: string
			labels: {[string]: string}
		}
		httpCheck: {
			path: string
			port: int
		}
		period:  string
		timeout: string
	}
}

// schema validation
DesignPattern: resource.DesignPattern

DesignPattern: {
	parameters: {
		globals:      resource.#Globals
		port:         int
		globalIpName: string
		domainName:   string
	}

	// Service, Ingress config definition for the app
	resources: kubernetes: {
		service: #Service
		ingress: #Ingress
	}

	// assign service metadata
	resources: kubernetes: service: metadata: {
		name: parameters.globals.appName
		annotations: {
			_ingress: {ingress: true}
			// use Netowrk Endpoint Group (NEG) to expose API
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
		selector: app: parameters.globals.appName
	}

	// assign deployment a port spec to point from the service
	resources: kubernetes: deployment: spec: template: spec: containers: [
		{
			ports: [
				{
					containerPort: parameters.port
				},
			]
		},
		// keep the list open to enable adding a sidecar container in different Design Patterns
		...,
	]

	// assign ingress metadata
	resources: kubernetes: ingress: metadata: {
		name: parameters.globals.appName
		annotations: {
			"kubernetes.io/ingress.allow-http": "true"
			// specify resource name of Google Cloud Public IP address statically reserved
			"kubernetes.io/ingress.global-static-ip-name": parameters.globalIpName
		}
	}
	// assign ingress spec
	resources: kubernetes: ingress: spec: {
		backend: {
			serviceName: parameters.globals.appName
			servicePort: #exposePort
		}
	}

	resources: gcp: uptimecheck: #UptimeCheckDeploymentConfig
	resources: gcp: uptimecheck: properties: {
		displayName: parameters.globals.appName
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
		period:  "60s"
		timeout: "10s"
	}

	// a task in "check" phase to enable UptimeCheck for Google Cloud Monitoring
	tasks: check: uptime: {
		name: "check-api"
		params: [
			{
				name:  "repository"
				value: parameters.globals.repository
			},
			{
				name:  "revision"
				value: parameters.globals.revision
			},
			{
				name:  "designpatternRepository"
				value: parameters.globals.designpattern.repository
			},
			{
				name:  "designpatternRevision"
				value: parameters.globals.designpattern.revision
			},
			{
				name:  "appName"
				value: parameters.globals.appName
			},
			{
				name:  "domainName"
				value: parameters.domainName
			},
			// Cloud LB could take more than 10 minutes to converge
			{
				name:  "checkTimeout"
				value: "900"
			},
			{
				name:  "gcpProjectID"
				value: parameters.globals.gcp.projectID
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
			name: "appName"
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
			name:  "gcloud-login"
			image: "google/cloud-sdk:278.0.0"
			command: ["gcloud"]
			args: [
				"auth",
				"activate-service-account",
				"--key-file=/secret/account.json",
			]
			volumeMounts: [
				{
					name:      "gcp-secret"
					mountPath: "/secret"
					readOnly:  true
				},
			]
		},
		// compile Design Pattern to generate GCP Manifest
		{
			name:  "compile"
			image: "cuelang/cue:0.2.1"
			args: [
				"export",
				"/workspace/application/build/app.cue",
				"--expression=gcpManifests",
				"--out=yaml",
				"--outfile=/workspace/gcpManifests.yaml",
			]
			workingDir: "/workspace/designpatterns"
		},
		{
			name:  "confirm-manifest"
			image: "busybox:1.31.1"
			command: ["cat"]
			args: [
				"gcpManifests.yaml",
			]
		},
		// prerequisite: deployment "$(params.appName)" should be created before running this step
		{
			name:  "deploy-to-gcp"
			image: "google/cloud-sdk:278.0.0"
			command: ["gcloud"]
			args: [
				"deployment-manager",
				"deployments",
				"update",
				"$(params.appName)",
				"--config=gcpManifests.yaml",
				"--project=$(params.gcpProjectID)",
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
