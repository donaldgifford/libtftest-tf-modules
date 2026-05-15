//go:build integration

package test

import (
	"os"
	"testing"

	"github.com/donaldgifford/libtftest/harness"
	"github.com/donaldgifford/libtftest/localstack"
)

// externalContainer points at an externally-managed LocalStack when
// LIBTFTEST_CONTAINER_URL is set. libtftest v0.2.0 documents this env
// var in localstack/doc.go but does not implement it in harness.Run;
// we honor it here so the cluster module's tests can reuse the user's
// LocalStack Pro container, which behaves correctly under AWS provider
// 6.x signing. The bundled libtftest default (localstack/localstack:4.4
// Community) returns 403 InvalidClientTokenId on every GetCallerIdentity
// the provider sends.
var externalContainer *localstack.Container

func TestMain(m *testing.M) {
	if url := os.Getenv("LIBTFTEST_CONTAINER_URL"); url != "" {
		externalContainer = &localstack.Container{
			ID:      "external",
			EdgeURL: url,
			Edition: localstack.EditionPro,
		}
		os.Exit(m.Run())
	}

	harness.Run(m, harness.Config{
		Edition:  localstack.EditionAuto,
		Services: []string{"s3", "sts", "iam", "kms", "logs", "ec2", "eks"},
	})
}
