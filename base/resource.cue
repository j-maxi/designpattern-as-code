package resource

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	tekton "github.com/tektoncd/pipeline/pkg/apis/pipeline/v1beta1"
)

#KubernetesSpec: {
	apiVersion: string
	kind:       string
	metadata:   metav1.#ObjectMeta

	// any resource specific configuration
	{[string]: _}
}

DesignPattern: close({
	// input parameters
	parameters: [string]: _

	// enumerates design pattern
	composites: [...DesignPattern]

	// resource declaration
	resources: {
		kubernetes: [string]: #KubernetesSpec
	}

  // Tekton tasks: 3 stages for now
  tasks: {
    build: [string]: tekton.#PipelineTask
    deploy: [string]: tekton.#PipelineTask
    check: [string]: tekton.#PipelineTask
  }
})
