package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// The same cases are checked against sbom_slugify by util/tests/sbom-lib.sh.
func TestSlugifyMatchesSharedCases(t *testing.T) {
	f, err := os.Open(filepath.Join("..", "tests", "data", "slug-cases.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	n := 0
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		name, want, ok := strings.Cut(scanner.Text(), "\t")
		if !ok {
			continue
		}
		n++
		if got := slugify(name); got != want {
			t.Errorf("slugify(%q) = %q, want %q", name, got, want)
		}
	}
	if n == 0 {
		t.Fatal("no slug cases read")
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestBuildIndexPublishesHierarchy(t *testing.T) {
	base := t.TempDir()
	writeFile(t, filepath.Join(base, "util/data/cncf-projects.yaml"), `repositories:
  - {owner: argoproj, repo: argo-cd, name: Argo, project_status: graduated}
  - {owner: aeraki-mesh, repo: aeraki, name: Aeraki Mesh, project_status: sandbox}
`)
	writeFile(t, filepath.Join(base, "util/data/repositories.yaml"), `repositories:
  - {owner: OmniTrustILM, repo: core, name: OmniTrust ILM}
  - {owner: ARGOPROJ, repo: ARGO-CD, name: Manual Argo}
`)
	writeFile(t, filepath.Join(base, "util/data/discovered-repos.yaml"), `repositories:
  - owner: argoproj
    repo: argo-workflows
    discovered_by: org-scan from argoproj/argo-cd
    parent_project: Argo
    parent_repo: argoproj/argo-cd
  - owner: aeraki-mesh
    repo: meta-protocol-proxy
    discovered_by: org-scan from aeraki-mesh/aeraki
  - owner: alibaba
    repo: Alink
    discovered_by: org-scan from alibaba/higress
`)
	for _, p := range []string{
		"sbom/argo/argo-cd/3.3.14/argo_3_3_14_spdx.json",
		"sbom/aeraki-mesh/aeraki/1.4.1/aeraki-mesh_1_4_1_spdx.json",
		"sbom/subprojects/argoproj/argo-workflows/4.1.4/argo-workflows_4_1_4_spdx.json",
		"sbom/subprojects/aeraki-mesh/meta-protocol-proxy/0.4.0/meta-protocol-proxy_0_4_0_spdx.json",
		"sbom/subprojects/alibaba/Alink/1.6.2/Alink_1_6_2_spdx.json",
		"sbom/subprojects/unknown-org/tool/1.0.0/tool_1_0_0_spdx.json",
	} {
		writeFile(t, filepath.Join(base, p), "{}")
	}
	writeFile(t, filepath.Join(base, "sbom/index.json"), "{}")

	index, err := buildIndex(base, time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}

	wantProjects := []ProjectEntry{
		{Name: "Aeraki Mesh", Slug: "aeraki-mesh", Owner: "aeraki-mesh", Repo: "aeraki", Status: "sandbox"},
		{Name: "Argo", Slug: "argo", Owner: "argoproj", Repo: "argo-cd", Status: "graduated"},
		{Name: "OmniTrust ILM", Slug: "omnitrust-ilm", Owner: "OmniTrustILM", Repo: "core"},
	}
	if !reflect.DeepEqual(index.Projects, wantProjects) {
		t.Errorf("projects = %+v\nwant %+v", index.Projects, wantProjects)
	}

	parents := map[string][2]string{}
	for _, s := range index.SubprojectSBOMs {
		parents[s.Owner+"/"+s.Repo] = [2]string{s.ParentProject, s.ParentSlug}
	}
	wantParents := map[string][2]string{
		"argoproj/argo-workflows":         {"Argo", "argo"},               // explicit parent_project
		"aeraki-mesh/meta-protocol-proxy": {"Aeraki Mesh", "aeraki-mesh"}, // resolved from discovered_by
		"alibaba/Alink":                   {"", "higress"},                // parent left the landscape: legacy slug
		"unknown-org/tool":                {"", "unknown-org"},            // not discovered: owner
	}
	if !reflect.DeepEqual(parents, wantParents) {
		t.Errorf("parents = %v\nwant %v", parents, wantParents)
	}

	// Every subproject whose parent is known shares the folder of its project's SBOMs.
	projectFolders := map[string]bool{}
	for _, s := range index.SBOMs {
		projectFolders[s.Project] = true
	}
	for _, s := range index.SubprojectSBOMs {
		if s.ParentProject != "" && !projectFolders[s.ParentSlug] {
			t.Errorf("%s/%s: parent slug %q has no project SBOM folder", s.Owner, s.Repo, s.ParentSlug)
		}
	}

	if len(index.SBOMs) != 2 || index.SBOMs[0].Project != "aeraki-mesh" || index.SBOMs[1].Project != "argo" {
		t.Errorf("sboms = %+v", index.SBOMs)
	}

	out, err := json.Marshal(index)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"projects":`, `"parent_project":"Argo"`, `"parent_slug":"argo"`, `"parent_project":""`} {
		if !strings.Contains(string(out), field) {
			t.Errorf("index JSON lacks %s", field)
		}
	}
}

func TestBuildIndexWithoutData(t *testing.T) {
	base := t.TempDir()
	writeFile(t, filepath.Join(base, "sbom/subprojects/argoproj/pkg/0.7.0/pkg_0_7_0_spdx.json"), "{}")
	index, err := buildIndex(base, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if len(index.Projects) != 0 || len(index.SubprojectSBOMs) != 1 || index.SubprojectSBOMs[0].ParentSlug != "argoproj" {
		t.Fatalf("unexpected index: %+v", index)
	}
}
