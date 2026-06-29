// Package targeting resolves the enable-models --target-accounts mode
// into a list of accounts to run the per-provider dispatch against. The
// three modes (current, org-management, <account-id-list>) come from
// DESIGN-0009 §3's cross-account matrix; only the account-id-list mode
// performs AssumeRole hops.
package targeting

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl/internal/awsapi"
)

// Mode names for --target-accounts. Anything else is parsed as a
// comma-separated account-id list.
const (
	ModeCurrent       = "current"
	ModeOrgManagement = "org-management"
)

// accountID matches a 12-digit AWS account ID.
var accountID = regexp.MustCompile(`^\d{12}$`)

// Target is one account the dispatch runs against.
type Target struct {
	// AccountID is the target account (for display and the role ARN).
	AccountID string
	// Credentials are the AssumeRole credentials for this target; nil
	// means use the ambient credentials (current / org-management).
	Credentials *awsapi.AssumedCredentials
	// CascadeOnlyAnthropic is set for org-management mode: Anthropic
	// enablement cascades to member accounts but other providers do not,
	// so the dispatch warns instead of running them.
	CascadeOnlyAnthropic bool
}

// ResolveTargets turns a --target-accounts mode into the accounts to act
// on. current and org-management resolve to the ambient account with no
// AssumeRole; an account-id list AssumeRoles into each account using the
// role named assumeRoleName.
func ResolveTargets(ctx context.Context, sts awsapi.STSClient, mode, assumeRoleName, sessionName string) ([]Target, error) {
	switch mode {
	case ModeCurrent:
		acct, err := sts.CallerAccountID(ctx)
		if err != nil {
			return nil, err
		}
		return []Target{{AccountID: acct}}, nil

	case ModeOrgManagement:
		acct, err := sts.CallerAccountID(ctx)
		if err != nil {
			return nil, err
		}
		return []Target{{AccountID: acct, CascadeOnlyAnthropic: true}}, nil

	default:
		return resolveAccountList(ctx, sts, mode, assumeRoleName, sessionName)
	}
}

// resolveAccountList parses a comma-separated account-id list and
// AssumeRoles into each account in turn.
func resolveAccountList(ctx context.Context, sts awsapi.STSClient, list, assumeRoleName, sessionName string) ([]Target, error) {
	ids, err := parseAccountIDs(list)
	if err != nil {
		return nil, err
	}

	targets := make([]Target, 0, len(ids))
	for _, id := range ids {
		arn := fmt.Sprintf("arn:aws:iam::%s:role/%s", id, assumeRoleName)
		creds, err := sts.AssumeRole(ctx, arn, sessionName)
		if err != nil {
			return nil, fmt.Errorf("assume role in account %s: %w", id, err)
		}
		targets = append(targets, Target{AccountID: id, Credentials: &creds})
	}
	return targets, nil
}

// parseAccountIDs validates a comma-separated list of 12-digit account
// IDs, rejecting unknown modes with a helpful message.
func parseAccountIDs(list string) ([]string, error) {
	parts := strings.Split(list, ",")
	ids := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if !accountID.MatchString(p) {
			return nil, fmt.Errorf(
				"invalid --target-accounts %q: want %q, %q, or a comma-separated list of 12-digit account IDs",
				list, ModeCurrent, ModeOrgManagement)
		}
		ids = append(ids, p)
	}
	if len(ids) == 0 {
		return nil, errors.New("no account IDs given in --target-accounts")
	}
	return ids, nil
}
