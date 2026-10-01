package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type SBOMEntry struct {
	Project string `json:"project"`
	Repo    string `json:"repo"`
	Version string `json:"version"`
	Path    string `json:"path"`
}

type SubprojectSBOMEntry struct {
	Owner   string `json:"owner"`
	Repo    string `json:"repo"`
	Version string `json:"version"`
	Path    string `json:"path"`
	// ParentProject is the landscape name of the owning CNCF project, empty if unknown.
	ParentProject string `json:"parent_project"`
	// ParentSlug is the parent folder in the subproject bucket; it equals the
	// project's folder in the project bucket whenever ParentProject is known.
	ParentSlug string `json:"parent_slug"`
}

type ProjectEntry struct {
	Name   string `json:"name"`
	Slug   string `json:"slug"`
	Owner  string `json:"owner"`
	Repo   string `json:"repo"`
	Status string `json:"status,omitempty"`
}

type Index struct {
	GeneratedAt     string                `json:"generated_at"`
	Projects        []ProjectEntry        `json:"projects"`
	SBOMs           []SBOMEntry           `json:"sboms"`
	SubprojectSBOMs []SubprojectSBOMEntry `json:"subproject_sboms"`
}

type repository struct {
	Owner         string `yaml:"owner"`
	Repo          string `yaml:"repo"`
	Name          string `yaml:"name"`
	ProjectStatus string `yaml:"project_status"`
	DiscoveredBy  string `yaml:"discovered_by"`
	ParentProject string `yaml:"parent_project"`
	ParentRepo    string `yaml:"parent_repo"`
}

type repositoryFile struct {
	Repositories []repository `yaml:"repositories"`
}

// slugify mirrors sbom_slugify in util/sbom-lib.sh: ASCII lowercase, spaces
// become '-', every other byte outside [a-z0-9-] is dropped.
func slugify(name string) string {
	var b strings.Builder
	for i := 0; i < len(name); i++ {
		c := name[i]
		switch {
		case c >= 'A' && c <= 'Z':
			b.WriteByte(c + 'a' - 'A')
		case c == ' ':
			b.WriteByte('-')
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '-':
			b.WriteByte(c)
		}
	}
	return b.String()
}

// discoveredByRepo returns "owner/repo" from "org-scan from owner/repo".
func discoveredByRepo(discoveredBy string) string {
	fields := strings.Fields(discoveredBy)
	for i := 0; i+1 < len(fields); i++ {
		if fields[i] == "from" && strings.Count(fields[i+1], "/") == 1 {
			return fields[i+1]
		}
	}
	return ""
}

func repoKey(owner, repo string) string {
	return strings.ToLower(owner + "/" + repo)
}

// hierarchy resolves projects and subproject parents from util/data.
type hierarchy struct {
	projects   []ProjectEntry
	byRepo     map[string]string // owner/repo (lowercase) -> CNCF project name
	discovered map[string]repository
}

func readRepositories(path string) ([]repository, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var f repositoryFile
	if err := yaml.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return f.Repositories, nil
}

func loadHierarchy(dataDir string) (*hierarchy, error) {
	cncf, err := readRepositories(filepath.Join(dataDir, "cncf-projects.yaml"))
	if err != nil {
		return nil, err
	}
	manual, err := readRepositories(filepath.Join(dataDir, "repositories.yaml"))
	if err != nil {
		return nil, err
	}
	discovered, err := readRepositories(filepath.Join(dataDir, "discovered-repos.yaml"))
	if err != nil {
		return nil, err
	}

	h := &hierarchy{byRepo: map[string]string{}, discovered: map[string]repository{}}
	seen := map[string]bool{}
	// CNCF entries take precedence over manual ones, as in util/prepare-project-matrix.sh.
	for _, list := range [][]repository{cncf, manual} {
		for _, r := range list {
			key := repoKey(r.Owner, r.Repo)
			if r.Name == "" || seen[key] {
				continue
			}
			seen[key] = true
			h.projects = append(h.projects, ProjectEntry{
				Name: r.Name, Slug: slugify(r.Name), Owner: r.Owner, Repo: r.Repo, Status: r.ProjectStatus,
			})
		}
	}
	for _, r := range cncf {
		if _, ok := h.byRepo[repoKey(r.Owner, r.Repo)]; !ok {
			h.byRepo[repoKey(r.Owner, r.Repo)] = r.Name
		}
	}
	for _, r := range discovered {
		h.discovered[repoKey(r.Owner, r.Repo)] = r
	}
	sort.Slice(h.projects, func(i, j int) bool {
		if h.projects[i].Slug != h.projects[j].Slug {
			return h.projects[i].Slug < h.projects[j].Slug
		}
		return repoKey(h.projects[i].Owner, h.projects[i].Repo) < repoKey(h.projects[j].Owner, h.projects[j].Repo)
	})
	return h, nil
}

// parent mirrors sbom_resolve_parent_project/sbom_parent_slug in util/sbom-lib.sh.
func (h *hierarchy) parent(owner, repo string) (project, slug string) {
	d := h.discovered[repoKey(owner, repo)]
	project = strings.TrimSpace(d.ParentProject)
	parentRepo := d.ParentRepo
	if parentRepo == "" {
		parentRepo = discoveredByRepo(d.DiscoveredBy)
	}
	if project == "" && parentRepo != "" {
		project = h.byRepo[strings.ToLower(parentRepo)]
	}
	if project != "" {
		return project, slugify(project)
	}
	// Legacy fallback: the parent's repository name, else the owner.
	if parentRepo != "" {
		return "", slugify(parentRepo[strings.Index(parentRepo, "/")+1:])
	}
	return "", slugify(owner)
}

func buildIndex(baseDir string, now time.Time) (*Index, error) {
	sbomDir := filepath.Join(baseDir, "sbom")
	h, err := loadHierarchy(filepath.Join(baseDir, "util", "data"))
	if err != nil {
		return nil, err
	}

	sboms := []SBOMEntry{}
	subprojectSBOMs := []SubprojectSBOMEntry{}

	err = filepath.Walk(sbomDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		if !strings.HasSuffix(path, ".json") || strings.HasSuffix(path, "index.json") {
			return nil
		}

		relPath, err := filepath.Rel(sbomDir, path)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		parts := strings.Split(relPath, "/")

		if parts[0] == "subprojects" && len(parts) >= 5 {
			// subprojects/owner/repo/version/file.json
			project, slug := h.parent(parts[1], parts[2])
			subprojectSBOMs = append(subprojectSBOMs, SubprojectSBOMEntry{
				Owner:         parts[1],
				Repo:          parts[2],
				Version:       parts[3],
				Path:          relPath,
				ParentProject: project,
				ParentSlug:    slug,
			})
		} else if len(parts) >= 4 {
			// project/repo/version/file.json
			sboms = append(sboms, SBOMEntry{
				Project: parts[0],
				Repo:    parts[1],
				Version: parts[2],
				Path:    relPath,
			})
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("walking %s: %w", sbomDir, err)
	}

	sort.Slice(sboms, func(i, j int) bool {
		if sboms[i].Project != sboms[j].Project {
			return sboms[i].Project < sboms[j].Project
		}
		if sboms[i].Repo != sboms[j].Repo {
			return sboms[i].Repo < sboms[j].Repo
		}
		return sboms[i].Version > sboms[j].Version // Newest first
	})

	sort.Slice(subprojectSBOMs, func(i, j int) bool {
		if subprojectSBOMs[i].Owner != subprojectSBOMs[j].Owner {
			return subprojectSBOMs[i].Owner < subprojectSBOMs[j].Owner
		}
		if subprojectSBOMs[i].Repo != subprojectSBOMs[j].Repo {
			return subprojectSBOMs[i].Repo < subprojectSBOMs[j].Repo
		}
		return subprojectSBOMs[i].Version > subprojectSBOMs[j].Version // Newest first
	})

	projects := h.projects
	if projects == nil {
		projects = []ProjectEntry{}
	}
	return &Index{
		GeneratedAt:     now.UTC().Format(time.RFC3339),
		Projects:        projects,
		SBOMs:           sboms,
		SubprojectSBOMs: subprojectSBOMs,
	}, nil
}

func main() {
	baseDir := "."
	if len(os.Args) > 1 {
		baseDir = os.Args[1]
	}
	indexFile := filepath.Join(baseDir, "sbom", "index.json")

	index, err := buildIndex(baseDir, time.Now())
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error building index: %v\n", err)
		os.Exit(1)
	}

	file, err := os.Create(indexFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating index file: %v\n", err)
		os.Exit(1)
	}
	defer file.Close()

	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(index); err != nil {
		fmt.Fprintf(os.Stderr, "Error encoding index: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Generated index with %d projects, %d SBOMs and %d subproject SBOMs\n",
		len(index.Projects), len(index.SBOMs), len(index.SubprojectSBOMs))
	fmt.Printf("Output: %s\n", indexFile)
}
