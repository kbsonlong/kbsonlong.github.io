package main

import (
	"bufio"
	"context"
	"fmt"
	"io/ioutil"
	"os"
	"strings"

	"github.com/spf13/cobra"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

var (
	filename      string
	labelSelector string
)

func main() {
	// Create a new root command
	var rootCmd = &cobra.Command{
		Use:   "pod-annotator",
		Short: "Annotates specific Pods on nodes with a given label selector",
		Run: func(cmd *cobra.Command, args []string) {
			annotatePods()
		},
	}

	// Define flags
	rootCmd.Flags().StringVarP(&filename, "file", "f", "", "Filename containing the node list (required)")
	rootCmd.Flags().StringVarP(&labelSelector, "label", "l", "", "Label selector for filtering Pods (required)")

	// Mark flags as required
	rootCmd.MarkFlagRequired("file")
	rootCmd.MarkFlagRequired("label")

	// Execute the root command
	if err := rootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

func annotatePods() {
	// Load kubeconfig
	config, err := clientcmd.BuildConfigFromFlags("", os.Getenv("KUBECONFIG"))
	if err != nil {
		config, err = rest.InClusterConfig()
		if err != nil {
			panic(err.Error())
		}
	}

	// Create clientset
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err.Error())
	}

	// Read node list from file
	nodeList, err := readNodesFromFile(filename)
	if err != nil {
		panic(err)
	}

	// Process each node
	for _, nodeName := range nodeList {
		// Get pods on the node with the specified label
		pods, err := getPodsOnNodeWithLabel(clientset, nodeName, labelSelector)
		if err != nil {
			fmt.Printf("Error getting pods for node %s: %v\n", nodeName, err)
			continue
		}

		// Process each pod
		for _, pod := range pods {
			// Check owner references and add annotation if needed
			if isOwnedByCloneSet(&pod) {
				addAnnotation(clientset, pod.Namespace, pod.Name)
			}
		}
	}
}

// Read nodes from file
func readNodesFromFile(filename string) ([]string, error) {
	data, err := ioutil.ReadFile(filename)
	if err != nil {
		return nil, err
	}

	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	var nodes []string

	for scanner.Scan() {
		line := scanner.Text()
		nodes = append(nodes, line)
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return nodes, nil
}

// Get pods on a node with the specified label
func getPodsOnNodeWithLabel(clientset *kubernetes.Clientset, nodeName, labelSelector string) ([]v1.Pod, error) {
	pods, err := clientset.CoreV1().Pods("").List(context.TODO(), metav1.ListOptions{
		FieldSelector: fmt.Sprintf("spec.nodeName=%s", nodeName),
		LabelSelector: labelSelector,
	})
	if err != nil {
		return nil, err
	}

	return pods.Items, nil
}

// Check if a pod is owned by a CloneSet
func isOwnedByCloneSet(pod *v1.Pod) bool {
	for _, ref := range pod.OwnerReferences {
		if ref.Kind == "CloneSet" {
			return true
		}
	}
	return false
}

// Add an annotation to a pod
func addAnnotation(clientset *kubernetes.Clientset, namespace, name string) {
	annotationKey := "example.com/annotation-key"
	annotationValue := "annotation-value"

	// Patch the pod with the updated annotations
	patch := fmt.Sprintf(`{"metadata":{"annotations":{"%s":"%s"}}}`, annotationKey, annotationValue)
	_, err := clientset.CoreV1().Pods(namespace).Patch(context.TODO(), name, types.StrategicMergePatchType, []byte(patch), metav1.PatchOptions{})
	if err != nil {
		fmt.Printf("Error patching pod %s/%s: %v\n", namespace, name, err)
		return
	}

	fmt.Printf("Pod %s/%s successfully patched with annotation %s=%s\n", namespace, name, annotationKey, annotationValue)
}
