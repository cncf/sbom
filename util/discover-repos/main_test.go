package main

import (
	"testing"

	"gopkg.in/yaml.v3"
)

var testProjects = []Repository{
	{Owner: "argoproj", Repo: "argo-cd", Name: "Argo", ProjectStatus: "graduated"},
	{Owner: "aeraki-mesh", Repo: "aeraki", Name: "Aeraki Mesh", ProjectStatus: "sandbox"},
	{Owner: "spiffe", Repo: "spiffe", Name: "SPIFFE", ProjectStatus: "graduated"},
	{Owner: "spiffe", Repo: "spire", Name: "SPIRE", ProjectStatus: "graduated"},
	{Owner: "higress-group", Repo: "higress", Name: "Higress", ProjectStatus: "sandbox"},
}

func TestParseDiscoveredBy(t *testing.T) {
	cases := map[string]string{
		"org-scan from argoproj/argo-cd":   "argoproj/argo-cd",
		"org-scan from aeraki-mesh/aeraki": "aeraki-mesh/aeraki",
		"manual":                           "",
		"":                                 "",
		"org-scan from argoproj":           "",
	}
	for in, want := range cases {
		if got := parseDiscoveredBy(in); got != want {
			t.Errorf("parseDiscoveredBy(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDiscoveredRepositoryRecordsParent(t *testing.T) {
	got := discoveredRepository("argoproj", "argo-workflows", testProjects[0])
	if got.ParentProject != "Argo" || got.ParentRepo != "argoproj/argo-cd" {
		t.Fatalf("parent = %q / %q, want Argo / argoproj/argo-cd", got.ParentProject, got.ParentRepo)
	}
	if got.DiscoveredBy != "org-scan from argoproj/argo-cd" {
		t.Fatalf("discovered_by = %q, provenance must be kept", got.DiscoveredBy)
	}
	if got.ProjectStatus != "graduated" || got.Name != "argo-workflows" {
		t.Fatalf("unexpected entry: %+v", got)
	}
}

func TestResolveParents(t *testing.T) {
	in := []Repository{
		{Owner: "argoproj", Repo: "argo-workflows", DiscoveredBy: "org-scan from argoproj/argo-cd"},
		{Owner: "aeraki-mesh", Repo: "meta-protocol-proxy", DiscoveredBy: "org-scan from Aeraki-Mesh/Aeraki"},
		// Parent repository no longer in the landscape: no guessing from the owner.
		{Owner: "higress-group", Repo: "plugin", DiscoveredBy: "org-scan from higress-group/old-name"},
		{Owner: "spiffe", Repo: "tool", DiscoveredBy: "org-scan from spiffe/gone"},
		// Parent left the landscape: a previously recorded parent is kept.
		{Owner: "alibaba", Repo: "x", DiscoveredBy: "org-scan from alibaba/higress", ParentProject: "Higress"},
		{Owner: "alibaba", Repo: "y", DiscoveredBy: "org-scan from alibaba/higress"},
		// Explicit parent_repo wins over discovered_by.
		{Owner: "spiffe", Repo: "go-spiffe", DiscoveredBy: "org-scan from spiffe/spire", ParentRepo: "spiffe/spiffe"},
	}
	want := []struct{ project, repo string }{
		{"Argo", "argoproj/argo-cd"},
		{"Aeraki Mesh", "Aeraki-Mesh/Aeraki"},
		{"", "higress-group/old-name"},
		{"", "spiffe/gone"},
		{"Higress", "alibaba/higress"},
		{"", "alibaba/higress"},
		{"SPIFFE", "spiffe/spiffe"},
	}
	got := resolveParents(in, testProjects)
	for i, w := range want {
		if got[i].ParentProject != w.project || got[i].ParentRepo != w.repo {
			t.Errorf("%s/%s: parent = %q / %q, want %q / %q", in[i].Owner, in[i].Repo,
				got[i].ParentProject, got[i].ParentRepo, w.project, w.repo)
		}
		if got[i].DiscoveredBy != in[i].DiscoveredBy {
			t.Errorf("%s/%s: discovered_by changed", in[i].Owner, in[i].Repo)
		}
	}
	if in[0].ParentProject != "" {
		t.Error("resolveParents must not modify its input")
	}
}

func TestParentFieldsYAML(t *testing.T) {
	out, err := yaml.Marshal(discoveredRepository("aeraki-mesh", "meta-protocol-proxy", testProjects[1]))
	if err != nil {
		t.Fatal(err)
	}
	want := `owner: aeraki-mesh
repo: meta-protocol-proxy
name: meta-protocol-proxy
category: ""
project_status: sandbox
discovered_by: org-scan from aeraki-mesh/aeraki
parent_project: Aeraki Mesh
parent_repo: aeraki-mesh/aeraki
`
	if string(out) != want {
		t.Fatalf("YAML mismatch:\n%s\nwant:\n%s", out, want)
	}

	var back Repository
	if err := yaml.Unmarshal(out, &back); err != nil {
		t.Fatal(err)
	}
	if back.ParentProject != "Aeraki Mesh" || back.ParentRepo != "aeraki-mesh/aeraki" {
		t.Fatalf("round trip lost parent fields: %+v", back)
	}
}
