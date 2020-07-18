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

// deployment-manager resource spec
#GCPResourceSpec: {
	name:       string
	type:       string
	properties: _
}

DesignPattern: close({
	// input parameters
	parameters: [string]: _

	// resource declaration
	resources: {
		kubernetes: [string]: #KubernetesSpec
		gcp: [string]:        #GCPResourceSpec
	}

	// Tekton tasks: 3 stages for now
	tasks: {
		build: [string]:  tekton.#PipelineTask
		deploy: [string]: tekton.#PipelineTask
		check: [string]:  tekton.#PipelineTask
	}
})

// global parameters
#Globals: {
	appName:    string
	repository: string
	revision:   string
	designpattern: {
		repository: string
		revision:   string
	}
	gcp: {
		projectID: string
		region:    string
	}
}

Composite: {
	input: [...DesignPattern]
	output: DesignPattern
	for _, c in input {
		output: resources: c.resources
		output: tasks:     c.tasks
	}
}

toTektonTask: {
	tasks:  _ | *[]
	before: _ | *[]
	out: [
		for _, t in tasks {
			t & {
				runAfter: [ for _, b in before {b.name}]
			}
		},
	]
}

GenTektonPipeline: {
	input: DesignPattern
	output: {
		apiVersion: "tekton.dev/v1beta1"
		kind:       "Pipeline"
		metadata: name: "deploy-with-designpattern"
	}

	// assuming we have at least one build task and one deploy task
	_buildtasks: (toTektonTask & {
		tasks: input.tasks.build
	}).out

	_deploytasks: (toTektonTask & {
		tasks:  input.tasks.deploy
		before: _buildtasks
	}).out

	_checktasks: (toTektonTask & {
		tasks:  input.tasks.check
		before: _deploytasks
	}).out

	output: spec: tasks: _buildtasks + _deploytasks + _checktasks
}

GenKubernetesManifests: {
	input: DesignPattern
	output: {
		apiVersion: "v1"
		kind:       "List"
	}
	output: items: [ for _, m in input.resources.kubernetes {m}]
}

GenGCPManifests: {
	input: DesignPattern
	output: resources: [ for _, m in input.resources.gcp {m}]
}
