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
		appName: string
    namespace: string
		image:   string
    repository: string
    revision: string
    designpatternRepository: string
    designpatternRevision: string
    gcpProjectID: string
    gcpRegion: string
    clusterName: string
	}

  resources: kubernetes: namespace: #Namespace

  resources: kubernetes: namespace: metadata: name: parameters.namespace

	resources: kubernetes: deployment: #Deployment

  resources: kubernetes: deployment: metadata: {
    name: parameters.appName
    namespace: parameters.namespace
  }

	// basic spec
	resources: kubernetes: deployment: spec: {
		replicas: 3
		selector: matchLabels: app: parameters.appName
		template: {
			metadata: labels: app: parameters.appName
			spec: containers: [
				{
					name:  parameters.appName
					image: "\(parameters.image):\(parameters.revision)"
				},
			]
		}
	}

  tasks: build: image: {
    name: "build-image"
    params: [
      {
        name: "repository"
        value: parameters.repository
      },
      {
        name: "revision"
        value: parameters.revision
      },
      {
        name: "imageRegistry"
        value: parameters.image
      },
    ]
    taskSpec: BuildkitBuildSpec
  }

  tasks: deploy: kubernetes: {
    name: "deploy-kubernetes"
    params: [
      {
        name: "repository"
        value: parameters.repository
      },
      {
        name: "revision"
        value: parameters.revision
      },
      {
        name: "designpatternRepository"
        value: parameters.designpatternRepository
      },
      {
        name: "designpatternRevision"
        value: parameters.designpatternRevision
      },
      {
        name: "gcpProjectID"
        value: parameters.gcpProjectID
      },
      {
        name: "gcpRegion"
        value: parameters.gcpRegion
      },
      {
        name: "clusterName"
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
      name: "git-pull"
      image: "docker:git"
      command: ["/usr/bin/git"]
      args: [
        "clone",
        "$(params.repository)",
        "application",
      ]
    },
    {
      name: "git-checkout"
      image: "docker:git"
      command: ["/usr/bin/git"]
      args: [
        "checkout",
        "$(params.revision)",
      ]
      workingDir: "/workspace/application"
    },
    {
      name: "gcloud-get-registory-credential"
      image: "google/cloud-sdk:278.0.0-alpine"
      command: ["/bin/sh", "-c"]
      args: [
        "gcloud auth activate-service-account --key-file=$(GOOGLE_APPLICATION_CREDENTIALS) && gcloud auth print-access-token > /workspace/.gcr-cred.txt"
      ]
      env: [
        {
          name: "GOOGLE_APPLICATION_CREDENTIALS"
          value: "/secret/account.json"
        },
      ]
      volumeMounts: [
        {
          name: "gcp-secret"
          mountPath: "/secret"
          readOnly: true
        },
      ]
    },
    {
      name: "docker-login"
      image: "docker"
      command: ["/bin/sh", "-c"]
      args: [
        "docker login -u oauth2accesstoken -p \"$(cat /workspace/.gcr-cred.txt)\" https://gcr.io"
      ]
    },
    {
      name: "make-cache-directory"
      image: "busybox:1.31.1"
      command: ["mkdir"]
      args: [
        "-p",
        "/cache/$(params.imageRegistry)",
      ]
      volumeMounts: [
        {
          name: "buildkit-cache"
          mountPath: "/cache"
        }
      ]
    },
    {
      name: "build-and-push"
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
        "--import-cache", "type=local,src=/cache/$(params.imageRegistry)"
      ]
      workingDir: "/workspace/application"
      env: [
        {
          name: "DOCKER_CONFIG"
          value: "/tekton/home/.docker"
        }
      ]
      resources: {
        requests: {
          memory: "128Mi"
          cpu: "100m"
        }
      }
      volumeMounts: [
        {
          name: "buildkit-cache"
          mountPath: "/cache"
        }
      ]
    },
  ]
  volumes: [
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
            key: "serviceaccount"
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
      name: "git-pull"
      image: "docker:git"
      command: ["/usr/bin/git"]
      args: [
        "clone",
        "$(params.repository)",
        "application",
      ]
    },
    {
      name: "git-checkout"
      image: "docker:git"
      command: ["/usr/bin/git"]
      args: [
        "checkout",
        "$(params.revision)",
      ]
      workingDir: "/workspace/application"
    },
    {
      name: "git-pull-designpattern"
      image: "docker:git"
      command: ["/usr/bin/git"]
      args: [
        "clone",
        "$(params.designpatternRepository)",
        "designpatterns",
      ]
    },
    {
      name: "git-checkout-designpattern"
      image: "docker:git"
      command: ["/usr/bin/git"]
      args: [
        "checkout",
        "$(params.designpatternRevision)",
      ]
      workingDir: "/workspace/designpatterns"
    },
    {
      name: "gcloud-login"
      image: "google/cloud-sdk:278.0.0"
      command: ["gcloud"]
      args: [
        "auth",
        "activate-service-account",
        "--key-file=/secret/account.json",
      ]
      volumeMounts: [
        {
          name: "gcp-secret"
          mountPath: "/secret"
          readOnly: true
        },
      ]
    },
    {
      name: "get-cluster-credential"
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
      volumeMounts: [
        {
          name: "gcp-secret"
          mountPath: "/secret"
          readOnly: true
        },
      ]
    },
    {
      name: "compile"
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
      name: "deploy"
      image: "google/cloud-sdk:278.0.0"
      command: ["kubectl"]
      args: [
        "apply",
        "-f",
        "kubernetesManifests.yaml",
      ]
      volumeMounts: [
        {
          name: "gcp-secret"
          mountPath: "/secret"
          readOnly: true
        },
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
            key: "serviceaccount"
            path: "account.json"
          },
        ]
      }
    },
  ]
}
