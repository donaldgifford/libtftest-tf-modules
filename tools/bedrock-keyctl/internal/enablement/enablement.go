// Package enablement dispatches per-provider Bedrock model-access
// enablement: Anthropic's one-time use-case form (Path A), Amazon's
// no-op (Path B), and third-party Marketplace subscribe (Path C,
// Phase 17). The provider routing and result shape are shared here; the
// per-path mechanics live in anthropic.go / amazon.go / marketplace.go.
// See DESIGN-0009 §3.
package enablement

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"text/tabwriter"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
)

// Outcome is the high-level result of enabling one model.
type Outcome string

const (
	// OutcomeEnabled means the tool took an action that enabled access.
	OutcomeEnabled Outcome = "enabled"
	// OutcomeNoActionNeeded means access was already in place or the
	// provider requires no enablement step.
	OutcomeNoActionNeeded Outcome = "no-action-needed"
	// OutcomeFailed means the enablement step errored.
	OutcomeFailed Outcome = "failed"
)

// ModelSpec is one provider-qualified model to enable.
type ModelSpec struct {
	Provider string
	ModelID  string
}

// Result is the per-model enablement outcome, rendered into the result
// table the subcommand prints.
type Result struct {
	Model    string
	Provider string
	Action   string
	Outcome  Outcome
	// Err is the underlying failure when Outcome == OutcomeFailed.
	Err error
}

// providerPath classifies a provider into its enablement path. Only
// providers present in providerPaths have a path; unmapped providers are
// caught by the comma-ok lookup before the switch.
type providerPath int

const (
	pathAnthropic providerPath = iota
	pathAmazon
	pathMarketplace
)

// providerPaths maps each of the eight Bedrock providers (the module's
// validated set) to its enablement path.
var providerPaths = map[string]providerPath{
	"anthropic": pathAnthropic,
	"amazon":    pathAmazon,
	"meta":      pathMarketplace,
	"mistral":   pathMarketplace,
	"cohere":    pathMarketplace,
	"ai21":      pathMarketplace,
	"stability": pathMarketplace,
	"openai":    pathMarketplace,
}

// Enabler dispatches model enablement to the right per-provider path.
type Enabler struct {
	bedrock awsapi.BedrockClient
}

// NewEnabler builds an Enabler over the given Bedrock client.
func NewEnabler(bedrock awsapi.BedrockClient) *Enabler {
	return &Enabler{bedrock: bedrock}
}

// Enable routes one model to its provider's enablement path. An unknown
// provider yields a failed result rather than a panic.
func (e *Enabler) Enable(ctx context.Context, m ModelSpec) Result {
	path, ok := providerPaths[m.Provider]
	if !ok {
		return Result{
			Model:    m.ModelID,
			Provider: m.Provider,
			Action:   "none",
			Outcome:  OutcomeFailed,
			Err:      fmt.Errorf("unknown provider %q (want one of anthropic, amazon, meta, mistral, cohere, ai21, stability, openai)", m.Provider),
		}
	}

	switch path {
	case pathAnthropic:
		return EnableAnthropic(ctx, e.bedrock, m.ModelID)
	case pathAmazon:
		return EnableAmazon(ctx, m.ModelID)
	case pathMarketplace:
		// Path C (third-party Marketplace) lands in Phase 17.
		return Result{
			Model:    m.ModelID,
			Provider: m.Provider,
			Action:   "marketplace-subscribe",
			Outcome:  OutcomeFailed,
			Err:      errors.New("third-party Marketplace enablement lands in Phase 17"),
		}
	default:
		return Result{
			Model:    m.ModelID,
			Provider: m.Provider,
			Action:   "none",
			Outcome:  OutcomeFailed,
			Err:      fmt.Errorf("unhandled provider path for %q", m.Provider),
		}
	}
}

// EnableAll dispatches every model and returns the per-model results in
// input order.
func (e *Enabler) EnableAll(ctx context.Context, models []ModelSpec) []Result {
	results := make([]Result, 0, len(models))
	for i := range models {
		results = append(results, e.Enable(ctx, models[i]))
	}
	return results
}

// FirstFailure returns a non-nil error if any result failed, so the
// caller can exit non-zero after printing the table.
func FirstFailure(results []Result) error {
	for i := range results {
		if results[i].Outcome == OutcomeFailed {
			return fmt.Errorf("enable %s (%s): %w", results[i].Model, results[i].Provider, results[i].Err)
		}
	}
	return nil
}

// PrintResults writes the per-model results as a tab-aligned table:
// MODEL | PROVIDER | ACTION | OUTCOME.
func PrintResults(w io.Writer, results []Result) error {
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	if _, err := fmt.Fprintln(tw, "MODEL\tPROVIDER\tACTION\tOUTCOME"); err != nil {
		return err
	}
	for i := range results {
		r := results[i]
		outcome := string(r.Outcome)
		if r.Err != nil {
			outcome = fmt.Sprintf("%s (%v)", r.Outcome, r.Err)
		}
		if _, err := fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", r.Model, r.Provider, r.Action, outcome); err != nil {
			return err
		}
	}
	return tw.Flush()
}

// ParseModelsCSV parses a comma-separated list of <provider>.<model_id>
// pairs (the provider is the segment before the first dot).
func ParseModelsCSV(raw string) ([]ModelSpec, error) {
	parts := strings.Split(raw, ",")
	specs := make([]ModelSpec, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		provider, modelID, ok := strings.Cut(p, ".")
		if !ok || provider == "" || modelID == "" {
			return nil, fmt.Errorf("invalid model %q: want <provider>.<model_id>", p)
		}
		specs = append(specs, ModelSpec{Provider: provider, ModelID: modelID})
	}
	if len(specs) == 0 {
		return nil, errors.New("no models given")
	}
	return specs, nil
}

// ParseModelsJSON parses a JSON array of {provider, model_id} objects —
// the @file.json form of --models.
func ParseModelsJSON(data []byte) ([]ModelSpec, error) {
	var raw []struct {
		Provider string `json:"provider"`
		ModelID  string `json:"model_id"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("parse models JSON: %w", err)
	}

	specs := make([]ModelSpec, 0, len(raw))
	for i := range raw {
		if raw[i].Provider == "" || raw[i].ModelID == "" {
			return nil, fmt.Errorf("models[%d]: both provider and model_id are required", i)
		}
		specs = append(specs, ModelSpec{Provider: raw[i].Provider, ModelID: raw[i].ModelID})
	}
	if len(specs) == 0 {
		return nil, errors.New("no models in JSON array")
	}
	return specs, nil
}
