package base

import (
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"

	"github.com/j-maxi/designpattern-as-code/base:resource"
)

#Namespace: {
	corev1.#Namespace

	apiVersion: "v1"
	kind:       "Namespace"
}

#Deployment: {
	appsv1.#Deployment

	apiVersion: "apps/v1"
	kind:       "Deployment"
}

// schema validation
DesignPattern: resource.DesignPattern

DesignPattern: {
	parameters: {
		globals:     resource.#Globals
		namespace:   string
		image:       string
		clusterName: string
	}

	// Namespace to host all resources for this app
	resources: kubernetes: namespace: #Namespace
	resources: kubernetes: namespace: metadata: name: parameters.namespace

	// Deployment to run this app
	resources: kubernetes: deployment: #Deployment
	resources: kubernetes: deployment: metadata: {
		name:      parameters.globals.appName
		namespace: parameters.namespace
	}
	resources: kubernetes: deployment: spec: {
		replicas: 3
		selector: matchLabels: app: parameters.globals.appName
		template: {
			metadata: labels: app: parameters.globals.appName
			spec: containers: [
				{
					name: parameters.globals.appName
					// image would be tagged with app repository's revision ID in the task defined below
					image: "\(parameters.image):\(parameters.globals.revision)"
				},
				// keep the list open to enable adding a sidecar container in different Design Patterns
				...,
			]
		}
	}

	// a task in "build" phase to create a Docker image for this app using buildkit
	tasks: build: image: {
		name: "build-image"
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
				name:  "imageRegistry"
				value: parameters.image
			},
		]
		taskSpec: BuildkitBuildSpec
	}

	// a task in "deploy" phase to deploy the container image to Kubernetes
	tasks: deploy: kubernetes: {
		name: "deploy-kubernetes"
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
				name:  "gcpProjectID"
				value: parameters.globals.gcp.projectID
			},
			{
				name:  "gcpRegion"
				value: parameters.globals.gcp.region
			},
			{
				name:  "clusterName"
				value: parameters.clusterName
			},
		]
		taskSpec: DeploySpec
	}
}

BuildkitBuildSpec: {
	params: [
		{
			name: "repository"
		},
		{
			name: "revision"
		},
		{
			name: "imageRegistry"
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
			name:  "gcloud-get-registory-credential"
			image: "google/cloud-sdk:278.0.0-alpine"
			command: ["/bin/sh", "-c"]
			args: [
				"gcloud auth activate-service-account --key-file=$(GOOGLE_APPLICATION_CREDENTIALS) && gcloud auth print-access-token > /workspace/.gcr-cred.txt",
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
			name:  "docker-login"
			image: "docker"
			command: ["/bin/sh", "-c"]
			args: [
				"docker login -u oauth2accesstoken -p \"$(cat /workspace/.gcr-cred.txt)\" https://gcr.io",
			]
		},
		{
			name:  "make-cache-directory"
			image: "busybox:1.31.1"
			command: ["mkdir"]
			args: [
				"-p",
				"/cache/$(params.imageRegistry)",
			]
			volumeMounts: [
				{
					name:      "buildkit-cache"
					mountPath: "/cache"
				},
			]
		},
		// build a container image and tag with revision ID
		{
			name:  "build-and-push"
			image: "moby/buildkit:v0.7.0"
			securityContext: privileged: true
			command: [
				"buildctl-daemonless.sh",
				"--debug",
				"build",
				"--progress=plain",
				"--frontend=dockerfile.v0",
				"--opt", "filename=build/Dockerfile",
				"--local", "context=/workspace/application/.",
				"--local", "dockerfile=.",
				"--output", "type=image,name=$(params.imageRegistry):$(params.revision),push=true",
				"--export-cache", "type=local,mode=max,dest=/cache/$(params.imageRegistry)",
				"--import-cache", "type=local,src=/cache/$(params.imageRegistry)",
			]
			workingDir: "/workspace/application"
			env: [
				{
					name:  "DOCKER_CONFIG"
					value: "/tekton/home/.docker"
				},
			]
			resources: {
				requests: {
					memory: "128Mi"
					cpu:    "100m"
				}
			}
			volumeMounts: [
				{
					name:      "buildkit-cache"
					mountPath: "/cache"
				},
			]
		},
	]
	volumes: [
		// prerequiste: PVC "buildkit-cache" should be created before running this task
		{
			name: "buildkit-cache"
			persistentVolumeClaim: claimName: "buildkit-cache"
		},
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

DeploySpec: {
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
			name: "gcpProjectID"
		},
		{
			name: "gcpRegion"
		},
		{
			name: "clusterName"
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
		{
			name:  "get-cluster-credential"
			image: "google/cloud-sdk:278.0.0"
			command: ["gcloud"]
			args: [
				"container",
				"clusters",
				"get-credentials",
				"$(params.clusterName)",
				"--project=$(params.gcpProjectID)",
				"--region=$(params.gcpRegion)",
			]
		},
		// compile Design Pattern to generate Kubernetes Manifest with a param of revision ID
		{
			name:  "compile"
			image: "cuelang/cue:0.2.1"
			args: [
				"export",
				"/workspace/application/build/app.cue",
				"--inject=revision=$(params.revision)",
				"--expression=kubernetesManifests",
				"--out=yaml",
				"--outfile=/workspace/kubernetesManifests.yaml",
			]
			workingDir: "/workspace/designpatterns"
		},
		{
			name:  "confirm-manifest"
			image: "busybox:1.31.1"
			command: ["cat"]
			args: [
				"kubernetesManifests.yaml",
			]
		},
		{
			name:  "deploy"
			image: "google/cloud-sdk:278.0.0"
			command: ["kubectl"]
			args: [
				"apply",
				"-f",
				"kubernetesManifests.yaml",
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
